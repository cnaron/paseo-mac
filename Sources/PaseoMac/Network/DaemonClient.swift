import Foundation

// MARK: - Endpoint configuration

/// Where the daemon lives and how to reach it.
///
/// - `direct`: a plain WebSocket to the daemon (typically localhost, optionally through an SSH tunnel).
/// - `relay`: traverse a Paseo relay server with E2EE via `ConnectionOffer`.
enum DaemonEndpoint: Sendable, Hashable {
    case direct(host: String, port: Int, clientId: String)
    case relay(offer: ConnectionOffer, clientId: String)

    var clientId: String {
        switch self {
        case .direct(_, _, let id): id
        case .relay(_, let id): id
        }
    }

    /// Label used in error messages and logs.
    var displayName: String {
        switch self {
        case .direct(let host, let port, _): "\(host):\(port)"
        case .relay(let offer, _): "relay \(offer.relayEndpoint)/\(offer.serverId)"
        }
    }

    static func directLocalhost() -> DaemonEndpoint {
        .direct(host: "localhost", port: 6767, clientId: "cid_paseomac_\(UUID().uuidString.prefix(16))")
    }
}

// MARK: - Errors

enum DaemonError: Error, LocalizedError {
    case notConnected
    case protocolError(String)
    case rpcFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Daemon is not connected."
        case .protocolError(let m): "Protocol error: \(m)"
        case .rpcFailed(let m): "RPC failed: \(m)"
        }
    }
}

// MARK: - DaemonClient

/// Owns a live connection to a Paseo daemon. Handles the hello handshake,
/// automatic ping replies, and requestId correlation for session-level RPCs.
///
/// Two transports are supported: a direct WebSocket (for loopback / SSH-tunnel use),
/// and a relay-backed E2EE channel (`RelayChannel`) when connecting through a
/// Paseo relay server. Both behave identically from the caller's perspective.
actor DaemonClient {
    private let endpoint: DaemonEndpoint
    private let session: URLSession

    private enum Transport {
        case direct(URLSessionWebSocketTask)
        case relay(RelayChannel)
    }
    private var transport: Transport?

    private var pending: [String: CheckedContinuation<SessionInbound, Error>] = [:]
    private var receiveTask: Task<Void, Never>?

    /// Fires for every inbound session message we didn't match to a pending request.
    let events: AsyncStream<SessionInbound>
    private let eventContinuation: AsyncStream<SessionInbound>.Continuation

    init(endpoint: DaemonEndpoint, session: URLSession = .shared) {
        self.endpoint = endpoint
        self.session = session
        var cont: AsyncStream<SessionInbound>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.eventContinuation = cont
    }

    // MARK: - Lifecycle

    func connect() async throws {
        guard transport == nil else { return }

        switch endpoint {
        case .direct(let host, let port, _):
            try await connectDirect(host: host, port: port)
        case .relay(let offer, _):
            try await connectRelay(offer: offer)
        }

        let hello = HelloMessage(
            clientId: endpoint.clientId,
            clientType: .cli,
            protocolVersion: WSProtocol.version,
            appVersion: "PaseoMac/0.0.1",
            capabilities: nil
        )
        try await rawSend(.hello(hello))
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        switch transport {
        case .direct(let t)?:
            t.cancel(with: .normalClosure, reason: nil)
        case .relay(let c)?:
            Task { await c.close() }
        case .none:
            break
        }
        transport = nil
        for (_, cont) in pending {
            cont.resume(throwing: DaemonError.notConnected)
        }
        pending.removeAll()
        eventContinuation.finish()
    }

    private func connectDirect(host: String, port: Int) async throws {
        let scheme = port == 443 ? "wss" : "ws"
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.port = port
        comps.path = "/ws"
        guard let url = comps.url else {
            throw DaemonError.protocolError("Could not build WS URL for \(host):\(port)")
        }
        let ws = session.webSocketTask(with: url)
        ws.resume()
        self.transport = .direct(ws)

        self.receiveTask = Task { [weak self] in
            await self?.runDirectReceiveLoop(ws)
        }
    }

    private func connectRelay(offer: ConnectionOffer) async throws {
        let url = try offer.relayWebSocketURL()
        let channel = try RelayChannel(
            relayURL: url,
            daemonPublicKeyB64: offer.daemonPublicKeyB64,
            session: session
        )
        try await channel.start()
        self.transport = .relay(channel)

        self.receiveTask = Task { [weak self] in
            await self?.runRelayReceiveLoop(channel)
        }
    }

    // MARK: - Public RPCs

    func listAgents(limit: Int = 100) async throws -> [AgentSnapshot] {
        let requestId = UUID().uuidString
        let req = FetchAgentsRequest(
            requestId: requestId,
            filter: .init(includeArchived: false, statuses: nil, requiresAttention: nil),
            sort: [.init(key: "updated_at", direction: "desc")],
            page: .init(limit: limit, cursor: nil),
            subscribe: nil
        )
        debugLog("[listAgents] sending request requestId=\(requestId)")
        let reply = try await requestResponse(requestId: requestId, outbound: .session(.fetchAgents(req)))
        debugLog("[listAgents] got reply")
        guard case let .fetchAgentsResponse(resp) = reply else {
            throw DaemonError.protocolError("Expected fetch_agents_response, got \(reply)")
        }
        return resp.payload.agents
    }

    // MARK: - Private plumbing

    private func rawSend(_ msg: WSOutbound) async throws {
        guard let transport else { throw DaemonError.notConnected }
        let data = try JSONEncoder.paseo.encode(msg)
        debugLog("[ws-send] \(String(decoding: data, as: UTF8.self))")
        switch transport {
        case .direct(let task):
            let text = String(decoding: data, as: UTF8.self)
            try await task.send(.string(text))
        case .relay(let channel):
            try await channel.send(data)
        }
    }

    private func requestResponse(
        requestId: String,
        outbound: WSOutbound
    ) async throws -> SessionInbound {
        try await withCheckedThrowingContinuation { cont in
            self.pending[requestId] = cont
            Task { [weak self] in
                do {
                    try await self?.rawSend(outbound)
                } catch {
                    await self?.failPending(requestId: requestId, with: error)
                }
            }
        }
    }

    private func failPending(requestId: String, with error: Error) {
        if let c = pending.removeValue(forKey: requestId) {
            c.resume(throwing: error)
        }
    }

    private func runDirectReceiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                let data: Data
                switch msg {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: continue
                }
                try handle(rawFrame: data)
            } catch {
                failAllPending(with: error)
                return
            }
        }
    }

    private func runRelayReceiveLoop(_ channel: RelayChannel) async {
        let stream = await channel.incoming
        for await data in stream {
            if Task.isCancelled { return }
            do {
                try handle(rawFrame: data)
            } catch {
                debugLog("[relay-recv] handle failed: \(error)")
            }
        }
        // Stream ended — treat as disconnect.
        failAllPending(with: DaemonError.notConnected)
    }

    private func failAllPending(with error: Error) {
        debugLog("[recv-loop] terminating with error: \(error)")
        for (_, cont) in pending { cont.resume(throwing: error) }
        pending.removeAll()
        eventContinuation.finish()
    }

    private func handle(rawFrame data: Data) throws {
        debugLog("[ws-recv] \(String(decoding: data, as: UTF8.self))")
        let inbound = try JSONDecoder.paseo.decode(WSInbound.self, from: data)
        switch inbound {
        case .ping:
            Task { [weak self] in try? await self?.rawSend(.pong(PongMessage())) }
        case .session(let session):
            dispatch(session)
        case .unknown(let type, _):
            FileHandle.standardError.write(Data("[warn] unknown WS frame type=\(type)\n".utf8))
        }
    }

    private func dispatch(_ session: SessionInbound) {
        let requestId: String? = {
            switch session {
            case .fetchAgentsResponse(let r): return r.payload.requestId
            case .sendAgentMessageResponse(let r): return r.payload.requestId
            default: return nil
            }
        }()
        debugLog("[dispatch] session=\(session) requestId=\(requestId ?? "nil") pending=\(Array(pending.keys))")
        if let rid = requestId, let cont = pending.removeValue(forKey: rid) {
            cont.resume(returning: session)
            return
        }
        eventContinuation.yield(session)
    }

    private func debugLog(_ s: @autoclosure () -> String) {
        if ProcessInfo.processInfo.environment["PASEO_DEBUG_WS"] == "1" {
            fputs("\(s())\n", stderr)
        }
    }
}
