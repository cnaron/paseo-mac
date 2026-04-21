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
            let events = await client.events
            self.eventTask = Task { [weak self] in
                for await session in events {
                    await self?.ingest(session: session)
                }
            }

            try await refreshAgents()
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

    // MARK: - Inbound events

    private func ingest(session: SessionInbound) async {
        switch session {
        case .agentStream(let msg):
            let agentId = msg.payload.agentId
            let vm = conversation(for: agentId)
            vm.apply(streamEvent: msg.payload.event, seq: msg.payload.seq, timestamp: msg.payload.timestamp)
        case .serverInfo, .status, .fetchAgentsResponse, .fetchAgentTimelineResponse,
             .sendAgentMessageResponse, .unknown:
            break
        }
    }
}
