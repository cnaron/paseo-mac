import Foundation

// MARK: - Endpoint configuration

struct DaemonEndpoint: Sendable, Hashable {
    /// e.g. "localhost" / "127.0.0.1" / a remote host over SSH tunnel
    var host: String
    /// Defaults to 6767 (daemon local listen port)
    var port: Int
    /// Stable identifier this client reports to the daemon. Anything non-empty works;
    /// reusing the same value across launches lets the daemon resume session state.
    var clientId: String

    var websocketURL: URL {
        let scheme = port == 443 ? "wss" : "ws"
        var comps = URLComponents()
        comps.scheme = scheme
        comps.host = host
        comps.port = port
        comps.path = "/ws"
        return comps.url!
    }

    static let localhost = DaemonEndpoint(
        host: "localhost",
        port: 6767,
        clientId: "cid_paseomac_\(UUID().uuidString.prefix(16))"
    )
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

/// Owns a live WebSocket connection to a Paseo daemon. Handles the hello handshake,
/// automatic ping replies, and requestId correlation for session-level RPCs.
///
/// This MVP skips relay / E2EE entirely: it expects to talk to a reachable daemon directly
/// (typically via an SSH tunnel — `ssh -L 6767:localhost:6767 cc`). Relay support comes later.
actor DaemonClient {
    private let endpoint: DaemonEndpoint
    private let session: URLSession
    private var task: URLSessionWebSocketTask?

    private var pending: [String: CheckedContinuation<SessionInbound, Error>] = [:]
    private var receiveTask: Task<Void, Never>?

    /// Fires for every inbound session message we didn't match to a pending request.
    /// UI layer observes this to append streaming chunks etc.
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
        guard task == nil else { return }
        let ws = session.webSocketTask(with: endpoint.websocketURL)
        ws.resume()
        self.task = ws

        // Spawn the receive loop before sending hello so we don't miss server_info.
        self.receiveTask = Task { [weak self] in
            await self?.runReceiveLoop()
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
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        for (_, cont) in pending {
            cont.resume(throwing: DaemonError.notConnected)
        }
        pending.removeAll()
        eventContinuation.finish()
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
        if ProcessInfo.processInfo.environment["PASEO_DEBUG_WS"] == "1" { fputs("[listAgents] sending request requestId=\(requestId)\n", stderr) }
        let reply = try await requestResponse(requestId: requestId, outbound: .session(.fetchAgents(req)))
        if ProcessInfo.processInfo.environment["PASEO_DEBUG_WS"] == "1" { fputs("[listAgents] got reply\n", stderr) }
        guard case let .fetchAgentsResponse(resp) = reply else {
            throw DaemonError.protocolError("Expected fetch_agents_response, got \(reply)")
        }
        return resp.payload.agents
    }

    // MARK: - Private plumbing

    private func rawSend(_ msg: WSOutbound) async throws {
        guard let task else { throw DaemonError.notConnected }
        let data = try JSONEncoder.paseo.encode(msg)
        let text = String(decoding: data, as: UTF8.self)
        if ProcessInfo.processInfo.environment["PASEO_DEBUG_WS"] == "1" { fputs("[ws-send] \(text)\n", stderr) }
        try await task.send(.string(text))
    }

    /// Register a pending continuation for `requestId`, send the outbound frame, and wait
    /// for the correlated response. If sending fails, the pending entry is cleaned up.
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

    private func runReceiveLoop() async {
        while !Task.isCancelled, let task = self.task {
            do {
                let msg = try await task.receive()
                try handle(message: msg)
            } catch {
                if ProcessInfo.processInfo.environment["PASEO_DEBUG_WS"] == "1" {
                    fputs("[ws-loop-error] \(error)\n", stderr)
                }
                // Fail every pending continuation so callers do not hang.
                for (_, cont) in pending {
                    cont.resume(throwing: error)
                }
                pending.removeAll()
                eventContinuation.finish()
                return
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        if ProcessInfo.processInfo.environment["PASEO_DEBUG_WS"] == "1" { fputs("[ws-recv] \(String(decoding: data, as: UTF8.self))\n", stderr) }
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
        if ProcessInfo.processInfo.environment["PASEO_DEBUG_WS"] == "1" {
            fputs("[dispatch] session=\(session) requestId=\(requestId ?? "nil") pending=\(Array(pending.keys))\n", stderr)
        }
        if let rid = requestId, let cont = pending.removeValue(forKey: rid) {
            cont.resume(returning: session)
            return
        }
        eventContinuation.yield(session)
    }
}
