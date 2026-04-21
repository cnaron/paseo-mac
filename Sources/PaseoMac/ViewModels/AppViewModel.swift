import Foundation
import Observation

/// Root observable state: owns the (optional) daemon connection, the list of
/// agents, the user's current selection, and the per-agent conversation VMs.
/// Created once at `@main` time, passed down via environment.
@MainActor
@Observable
final class AppViewModel {

    enum ConnectionState: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    /// A live-derived status for one agent, layered on top of the most recent
    /// `AgentSnapshot` from `fetch_agents`. Updated from `agent_stream` events
    /// so the sidebar dot reacts within milliseconds of a turn starting.
    struct LiveStatus: Equatable {
        var status: String              // "running" | "idle" | ...
        var requiresAttention: Bool
        var attentionReason: String?
    }

    // MARK: Persisted offer

    private let storedOfferKey = "paseomac.connectionOfferRaw"

    var connectionState: ConnectionState = .disconnected
    var agents: [AgentSnapshot] = []
    var selectedAgentId: String? = nil
    var savedOfferRaw: String? {
        get { UserDefaults.standard.string(forKey: storedOfferKey) }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: storedOfferKey)
            } else {
                UserDefaults.standard.removeObject(forKey: storedOfferKey)
            }
        }
    }

    /// Live status overlays keyed by agentId. Views fall back to the
    /// snapshot's `status` if no entry here.
    var liveStatus: [String: LiveStatus] = [:]

    /// Provider / model / mode catalog — populated on connect.
    var providers: [ProviderSnapshot] = []

    // MARK: Internals

    private var client: DaemonClient?
    private var eventTask: Task<Void, Never>?
    private var conversations: [String: ConversationViewModel] = [:]

    // MARK: - Lifecycle

    /// Kick off an attempt to connect with whatever offer we have stored.
    func autoConnectIfPossible() {
        guard case .disconnected = connectionState else { return }
        guard let raw = savedOfferRaw, !raw.isEmpty else { return }
        Task { await connect(withOfferRaw: raw) }
    }

    func connect(withOfferRaw raw: String) async {
        connectionState = .connecting
        do {
            let offer = try ConnectionOffer.parse(raw)
            let endpoint = DaemonEndpoint.relay(
                offer: offer,
                clientId: "cid_paseomac_\(Int(Date().timeIntervalSince1970))"
            )
            let client = DaemonClient(endpoint: endpoint)
            try await client.connect()
            self.client = client
            self.savedOfferRaw = raw
            self.connectionState = .connected

            // Start listening for agent_stream events.
            let events = client.events
            self.eventTask = Task { [weak self] in
                for await session in events {
                    await self?.ingest(session: session)
                }
            }

            try await refreshAgents()

            // Pull model/mode catalog in the background — used by composer pickers.
            Task { [weak self] in
                if let list = try? await self?.client?.getProvidersSnapshot() {
                    self?.providers = list
                }
            }
        } catch {
            self.connectionState = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        if let c = client { await c.disconnect() }
        client = nil
        conversations.removeAll()
        agents = []
        selectedAgentId = nil
        liveStatus.removeAll()
        providers = []
        connectionState = .disconnected
    }

    // MARK: - Data access

    func refreshAgents() async throws {
        guard let client else { return }
        let list = try await client.listAgents(limit: 100)
        self.agents = list
        if selectedAgentId == nil, let first = list.first {
            selectedAgentId = first.id
        }
    }

    /// Returns (and lazily creates) the ConversationViewModel for a given agent.
    func conversation(for agentId: String) -> ConversationViewModel {
        if let existing = conversations[agentId] { return existing }
        let vm = ConversationViewModel(agentId: agentId) { [weak self] in self?.client }
        conversations[agentId] = vm
        Task { await vm.loadInitial() }
        return vm
    }

    /// Best-available current status/attention for an agent — merges live overlay
    /// onto the most recent snapshot.
    func effectiveStatus(for agentId: String) -> (status: String, attention: Bool) {
        let base = agents.first(where: { $0.id == agentId })
        if let live = liveStatus[agentId] {
            return (live.status, live.requiresAttention)
        }
        return (base?.status ?? "unknown", base?.requiresAttention ?? false)
    }

    func currentAgent() -> AgentSnapshot? {
        guard let id = selectedAgentId else { return nil }
        return agents.first { $0.id == id }
    }

    // MARK: - Model / mode / thinking dispatch

    func setAgentMode(agentId: String, modeId: String) async {
        guard let client else { return }
        do {
            _ = try await client.setAgentMode(agentId: agentId, modeId: modeId)
            patchAgent(id: agentId) { $0.withMode(modeId) }
        } catch {
            // Surface later; for now stay silent — live status picks up on next fetch.
        }
    }

    func setAgentModel(agentId: String, modelId: String?) async {
        guard let client else { return }
        do {
            _ = try await client.setAgentModel(agentId: agentId, modelId: modelId)
            patchAgent(id: agentId) { $0.withModel(modelId) }
        } catch { }
    }

    func setAgentThinking(agentId: String, thinkingOptionId: String?) async {
        guard let client else { return }
        do {
            _ = try await client.setAgentThinking(agentId: agentId, thinkingOptionId: thinkingOptionId)
            patchAgent(id: agentId) { $0.withThinking(thinkingOptionId) }
        } catch { }
    }

    private func patchAgent(id: String, _ body: (AgentSnapshot) -> AgentSnapshot) {
        if let idx = agents.firstIndex(where: { $0.id == id }) {
            agents[idx] = body(agents[idx])
        }
    }

    // MARK: - Inbound events

    private func ingest(session: SessionInbound) async {
        switch session {
        case .agentStream(let msg):
            let agentId = msg.payload.agentId
            applyLiveStatus(agentId: agentId, event: msg.payload.event)
            let vm = conversation(for: agentId)
            vm.apply(streamEvent: msg.payload.event, seq: msg.payload.seq, timestamp: msg.payload.timestamp)
        case .agentStatus(let msg):
            // Daemon-pushed snapshot update — apply directly.
            if let snap = msg.payload.info,
               let idx = agents.firstIndex(where: { $0.id == snap.id }) {
                agents[idx] = snap
            }
            liveStatus[msg.payload.agentId] = LiveStatus(
                status: msg.payload.status,
                requiresAttention: msg.payload.info?.requiresAttention ?? false,
                attentionReason: msg.payload.info?.attentionReason
            )
        case .serverInfo, .status, .fetchAgentsResponse, .fetchAgentTimelineResponse,
             .sendAgentMessageResponse, .setAgentModeResponse, .setAgentModelResponse,
             .setAgentThinkingResponse, .getProvidersSnapshotResponse, .unknown:
            break
        }
    }

    private func applyLiveStatus(agentId: String, event: AgentStreamEvent) {
        var live = liveStatus[agentId] ?? LiveStatus(
            status: agents.first(where: { $0.id == agentId })?.status ?? "idle",
            requiresAttention: false,
            attentionReason: nil
        )
        switch event {
        case .turnStarted:
            live.status = "running"
            live.requiresAttention = false
        case .turnCompleted:
            live.status = "idle"
        case .turnFailed, .turnCanceled:
            live.status = "idle"
            live.requiresAttention = true
        case .attentionRequired(let reason):
            live.requiresAttention = true
            live.attentionReason = reason
        case .permissionRequested:
            live.requiresAttention = true
            live.attentionReason = "permission"
        case .permissionResolved, .threadStarted, .timelineUpdated, .other:
            break
        }
        liveStatus[agentId] = live
    }
}

// MARK: - Snapshot mutation helpers

private extension AgentSnapshot {
    func withMode(_ modeId: String) -> AgentSnapshot {
        AgentSnapshot(
            id: id, provider: provider, cwd: cwd, status: status, title: title,
            createdAt: createdAt, updatedAt: updatedAt, lastUserMessageAt: lastUserMessageAt,
            model: model, thinkingOptionId: thinkingOptionId,
            effectiveThinkingOptionId: effectiveThinkingOptionId,
            currentModeId: modeId, availableModes: availableModes,
            archivedAt: archivedAt, requiresAttention: requiresAttention,
            attentionReason: attentionReason
        )
    }
    func withModel(_ modelId: String?) -> AgentSnapshot {
        AgentSnapshot(
            id: id, provider: provider, cwd: cwd, status: status, title: title,
            createdAt: createdAt, updatedAt: updatedAt, lastUserMessageAt: lastUserMessageAt,
            model: modelId, thinkingOptionId: thinkingOptionId,
            effectiveThinkingOptionId: effectiveThinkingOptionId,
            currentModeId: currentModeId, availableModes: availableModes,
            archivedAt: archivedAt, requiresAttention: requiresAttention,
            attentionReason: attentionReason
        )
    }
    func withThinking(_ optId: String?) -> AgentSnapshot {
        AgentSnapshot(
            id: id, provider: provider, cwd: cwd, status: status, title: title,
            createdAt: createdAt, updatedAt: updatedAt, lastUserMessageAt: lastUserMessageAt,
            model: model, thinkingOptionId: optId,
            effectiveThinkingOptionId: optId,
            currentModeId: currentModeId, availableModes: availableModes,
            archivedAt: archivedAt, requiresAttention: requiresAttention,
            attentionReason: attentionReason
        )
    }
}
