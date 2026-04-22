import Foundation
import Observation

@MainActor
@Observable
final class AppViewModel {

    enum ConnectionState: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    struct LiveStatus: Equatable {
        var status: String
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

    var liveStatus: [String: LiveStatus] = [:]
    var providers: [ProviderSnapshot] = []

    /// Claude subscription usage — fetched from VPS proxy after connect.
    var usageData: ClaudeUsageData? = nil

    // MARK: Internals

    private var client: DaemonClient?
    private var eventTask: Task<Void, Never>?
    private var conversations: [String: ConversationViewModel] = [:]

    // MARK: - Lifecycle

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

            let events = client.events
            self.eventTask = Task { [weak self] in
                for await session in events {
                    await self?.ingest(session: session)
                }
                guard let self, !Task.isCancelled else { return }
                await self.handleUnexpectedDisconnect()
            }

            try await refreshAgents()

            Task { [weak self] in
                if let list = try? await self?.client?.getProvidersSnapshot() {
                    self?.providers = list
                }
            }

            // Fetch usage quota from VPS proxy.
            Task { [weak self] in await self?.fetchUsage() }

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
        usageData = nil
        connectionState = .disconnected
    }

    private func handleUnexpectedDisconnect() async {
        guard let raw = savedOfferRaw, !raw.isEmpty else {
            connectionState = .disconnected
            return
        }
        client = nil
        connectionState = .connecting
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard !Task.isCancelled else { return }
        await connect(withOfferRaw: raw)
    }

    // MARK: - Agent creation

    func createAgent(cwd: String) async {
        guard let client else { return }
        let provider = currentAgent()?.provider ?? "anthropic"
        let before = Set(agents.map(\.id))
        do {
            try await client.createAgent(cwd: cwd, provider: provider)
        } catch { return }
        for _ in 0..<10 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            try? await refreshAgents()
            if let newId = agents.first(where: { !before.contains($0.id) })?.id {
                selectedAgentId = newId
                return
            }
        }
    }

    func archiveAgent(agentId: String) async {
        guard let client else { return }
        agents.removeAll { $0.id == agentId }
        liveStatus.removeValue(forKey: agentId)
        conversations.removeValue(forKey: agentId)
        if selectedAgentId == agentId {
            selectedAgentId = agents.first?.id
        }
        do {
            try await client.archiveAgent(agentId: agentId)
        } catch {
            try? await refreshAgents()
        }
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

    func conversation(for agentId: String) -> ConversationViewModel {
        if let existing = conversations[agentId] { return existing }
        let vm = ConversationViewModel(agentId: agentId) { [weak self] in self?.client }
        conversations[agentId] = vm
        Task { await vm.loadInitial() }
        return vm
    }

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
        } catch { }
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

    // MARK: - Usage quota

    func fetchUsage() async {
        let urlString = UserDefaults.standard.string(forKey: "paseomac.usageApiUrl") ?? ""
        let token     = UserDefaults.standard.string(forKey: "paseomac.usageApiToken") ?? ""
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return }

        var req = URLRequest(url: url)
        if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Usage-Token") }
        req.timeoutInterval = 15

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }

        struct Resp: Decodable {
            struct Period: Decodable {
                let utilization: Double?
                let resetsAt: String?
                enum CodingKeys: String, CodingKey {
                    case utilization; case resetsAt = "resets_at"
                }
            }
            let fiveHour: Period?
            let sevenDay: Period?
            let subscriptionType: String?
            enum CodingKeys: String, CodingKey {
                case fiveHour = "five_hour"; case sevenDay = "seven_day"
                case subscriptionType = "subscription_type"
            }
        }
        guard let parsed = try? JSONDecoder().decode(Resp.self, from: data) else { return }

        let isoFull: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        func parseISO(_ s: String) -> Date? { isoFull.date(from: s) ?? ISO8601DateFormatter().date(from: s) }
        func clamp(_ v: Double) -> Int { Int(max(0, min(100, v.rounded()))) }
        func planName(_ sub: String) -> String {
            let l = sub.lowercased()
            if l.contains("max") { return "Max" }
            if l.contains("pro") { return "Pro" }
            if l.contains("team") { return "Team" }
            return sub.isEmpty ? "Claude.ai" : sub.capitalized
        }

        usageData = ClaudeUsageData(
            planName: planName(parsed.subscriptionType ?? ""),
            fiveHour: parsed.fiveHour?.utilization.map { clamp($0) },
            sevenDay: parsed.sevenDay?.utilization.map { clamp($0) },
            fiveHourResetAt: parsed.fiveHour?.resetsAt.flatMap(parseISO),
            sevenDayResetAt: parsed.sevenDay?.resetsAt.flatMap(parseISO)
        )
    }

    // MARK: - Inbound events

    private func ingest(session: SessionInbound) async {
        switch session {
        case .agentStream(let msg):
            let agentId = msg.payload.agentId
            applyLiveStatus(agentId: agentId, event: msg.payload.event)
            let currentModel = agents.first(where: { $0.id == agentId })?.model
            let vm = conversation(for: agentId)
            vm.apply(
                streamEvent: msg.payload.event,
                seq: msg.payload.seq,
                timestamp: msg.payload.timestamp,
                currentModel: currentModel
            )
        case .agentStatus(let msg):
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
             .setAgentThinkingResponse, .getProvidersSnapshotResponse, .cancelAgentResponse,
             .unknown:
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
            lastUsage: lastUsage,
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
            lastUsage: lastUsage,
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
            lastUsage: lastUsage,
            archivedAt: archivedAt, requiresAttention: requiresAttention,
            attentionReason: attentionReason
        )
    }
}
