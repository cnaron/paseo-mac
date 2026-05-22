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
    case rpcTimeout

    var errorDescription: String? {
        switch self {
        case .notConnected: "Daemon is not connected."
        case .protocolError(let m): "Protocol error: \(m)"
        case .rpcFailed(let m): "RPC failed: \(m)"
        case .rpcTimeout: "Request timed out."
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
    private var keepaliveTask: Task<Void, Never>?
    /// Send an app-level `{"type":"ping"}` every 15s. Mirrors the official
    /// Paseo CLI's keepalive interval. WebSocket control PINGs aren't always
    /// preserved by relays/CDNs, so app-level traffic is what keeps the
    /// connection from being declared idle.
    private static let pingInterval: TimeInterval = 15
    /// Per-RPC ceiling for `requestResponse`. Matches the upper bound used
    /// by the official Paseo client (writes 15s, reads 10s — we pick the
    /// write bound as a safe single value). A slow RPC fails individually
    /// via `failPending(requestId:with: .rpcTimeout)`; the socket is left
    /// open so other in-flight requests aren't dragged down with it.
    ///
    /// Note: there is no app-level "no inbound frame for N seconds → close"
    /// deadline. The official client doesn't have one either — it relies on
    /// transport-layer `onClose` / `onError` (i.e. URLSessionWebSocketTask's
    /// own death detection) to surface dead sockets. An app-level deadline
    /// is just a way to self-kill on a slow-but-alive RPC.
    private static let requestTimeout: TimeInterval = 15
    /// How many consecutive unanswered pings we tolerate before declaring the
    /// connection dead and forcing a reconnect. Mirrors upstream's
    /// `LIVENESS_FAILURE_RECONNECT_THRESHOLD = 3` from paseo daemon-client.
    /// With `pingInterval = 15s`, this means ~45s of silence before reconnect.
    /// Independent from `requestTimeout` — a slow but alive RPC won't trip the
    /// liveness check because pong arrives separately.
    private static let livenessThreshold = 3
    /// Number of pings sent without a matching pong response. Reset to 0 on
    /// any inbound pong. Checked at the top of each keepalive tick.
    private var unansweredPings: Int = 0
    private var connectedAt: Date?

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
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.48",
            capabilities: nil
        )
        try await rawSend(.hello(hello))
        connectedAt = Date()
        unansweredPings = 0
        startKeepalive()
    }

    /// How long this connection has been alive. Used by AppViewModel to
    /// stamp `secondsAlive` onto the disconnect log line.
    func aliveDuration() -> TimeInterval {
        guard let connectedAt else { return 0 }
        return Date().timeIntervalSince(connectedAt)
    }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(DaemonClient.pingInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.tickKeepalive()
            }
        }
    }

    /// One keepalive tick: send an app-level ping plus a WebSocket-level
    /// PING (on relay transports). If sending fails, the socket is dead —
    /// close it so the upper layer reconnects.
    ///
    /// Liveness: count unanswered pings. If `livenessThreshold` ticks pass
    /// without an inbound pong, treat the connection as dead and force-close
    /// — even if the socket itself reports no error. This catches stuck
    /// half-open sockets where TCP keepalive hasn't yet given up. The check
    /// is intentionally cheap and independent of RPC timing: a slow RPC can
    /// still complete because pongs travel on a separate code path.
    private func tickKeepalive() async {
        guard transport != nil else { return }
        if unansweredPings >= DaemonClient.livenessThreshold {
            debugLog("[keepalive] \(unansweredPings) pings unanswered (threshold \(DaemonClient.livenessThreshold)) — closing transport")
            await forceCloseDueToKeepalive(reason: "liveness threshold exceeded (\(unansweredPings) pongs missed)")
            return
        }
        let pingId = UUID().uuidString
        let now = Date()
        let ping = PingMessage(
            requestId: pingId,
            clientSentAt: Int64(now.timeIntervalSince1970 * 1000)
        )
        do {
            try await rawSend(.ping(ping))
            unansweredPings += 1
        } catch {
            debugLog("[keepalive] ping send failed: \(error) — closing transport")
            await forceCloseDueToKeepalive(reason: "ping send failed: \(error)")
            return
        }
        // Also send a WebSocket-level PING frame on relay transports so the
        // client→relay socket itself stays warm. The encrypted app-level ping
        // above keeps the daemon side happy, but the data socket between
        // paseo-mac and the Cloudflare relay needs control-frame traffic to
        // avoid being torn down by edge/NAT idle policies.
        if case .relay(let channel) = transport {
            let ok = await channel.sendKeepalivePing()
            if !ok {
                debugLog("[keepalive] WS ping failed — closing transport")
                await forceCloseDueToKeepalive(reason: "WS ping failed")
                return
            }
        }
    }

    /// Actively close the WS so the receive loop errors out and the upper
    /// layer (AppViewModel) sees the disconnect promptly. Without this, a
    /// half-open connection would only be detected when the OS finally
    /// surfaces a TCP error, which can take minutes.
    private func forceCloseDueToKeepalive(reason: String) async {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        switch transport {
        case .direct(let task):
            task.cancel(with: .goingAway, reason: Data(reason.utf8))
        case .relay(let channel):
            await channel.close(code: .goingAway, reason: reason)
        case .none:
            break
        }
        // The receive loop will catch the close via task.receive() error
        // and call failAllPending, which finishes eventContinuation.
    }

    func disconnect() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        connectedAt = nil
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
        // Default is 1MB. A single timeline event echoing 4 attached images
        // (each ~2MB raw + base64 inflation) easily blows past that, closing
        // the connection with "Message Too Big" the moment daemon sends the
        // user_message stream back.
        ws.maximumMessageSize = 64 * 1024 * 1024
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

    func listArchivedAgents(limit: Int = 200) async throws -> [AgentSnapshot] {
        let requestId = UUID().uuidString
        let req = FetchAgentsRequest(
            requestId: requestId,
            filter: .init(includeArchived: true, statuses: nil, requiresAttention: nil),
            sort: [.init(key: "updated_at", direction: "desc")],
            page: .init(limit: limit, cursor: nil),
            subscribe: nil
        )
        let reply = try await requestResponse(requestId: requestId, outbound: .session(.fetchAgents(req)))
        guard case let .fetchAgentsResponse(resp) = reply else {
            throw DaemonError.protocolError("Expected fetch_agents_response, got \(reply)")
        }
        return resp.payload.agents.filter { $0.archivedAt != nil }
    }

    func fetchTimeline(
        agentId: String,
        direction: String = "tail",
        cursor: AgentTimelineCursor? = nil,
        limit: Int = 200,
        projection: String = "projected"
    ) async throws -> FetchAgentTimelineResponse.Payload {
        let requestId = UUID().uuidString
        let req = FetchAgentTimelineRequest(
            requestId: requestId,
            agentId: agentId,
            direction: direction,
            cursor: cursor,
            limit: limit,
            projection: projection
        )
        let reply = try await requestResponse(
            requestId: requestId,
            outbound: .session(.fetchAgentTimeline(req))
        )
        guard case let .fetchAgentTimelineResponse(resp) = reply else {
            throw DaemonError.protocolError("Expected fetch_agent_timeline_response, got \(reply)")
        }
        if let err = resp.payload.error, !err.isEmpty {
            throw DaemonError.rpcFailed(err)
        }
        return resp.payload
    }

    @discardableResult
    func sendMessage(
        agentId: String,
        text: String,
        messageId: String? = nil,
        images: [SendAgentMessageRequest.ImageAttachment]? = nil
    ) async throws -> SendAgentMessageResponse.Payload {
        let requestId = UUID().uuidString
        let req = SendAgentMessageRequest(
            requestId: requestId,
            agentId: agentId,
            text: text,
            messageId: messageId,
            images: images,
            attachments: nil
        )
        let reply = try await requestResponse(
            requestId: requestId,
            outbound: .session(.sendAgentMessage(req))
        )
        guard case let .sendAgentMessageResponse(resp) = reply else {
            throw DaemonError.protocolError("Expected send_agent_message_response, got \(reply)")
        }
        if let err = resp.payload.error, !err.isEmpty {
            throw DaemonError.rpcFailed(err)
        }
        return resp.payload
    }

    @discardableResult
    func setAgentMode(agentId: String, modeId: String) async throws -> AckResponsePayload {
        let requestId = UUID().uuidString
        let req = SetAgentModeRequest(requestId: requestId, agentId: agentId, modeId: modeId)
        let reply = try await requestResponse(requestId: requestId, outbound: .session(.setAgentMode(req)))
        guard case let .setAgentModeResponse(resp) = reply else {
            throw DaemonError.protocolError("Expected set_agent_mode_response, got \(reply)")
        }
        if let err = resp.payload.error, !err.isEmpty { throw DaemonError.rpcFailed(err) }
        return resp.payload
    }

    @discardableResult
    func setAgentModel(agentId: String, modelId: String?) async throws -> AckResponsePayload {
        let requestId = UUID().uuidString
        let req = SetAgentModelRequest(requestId: requestId, agentId: agentId, modelId: modelId)
        let reply = try await requestResponse(requestId: requestId, outbound: .session(.setAgentModel(req)))
        guard case let .setAgentModelResponse(resp) = reply else {
            throw DaemonError.protocolError("Expected set_agent_model_response, got \(reply)")
        }
        if let err = resp.payload.error, !err.isEmpty { throw DaemonError.rpcFailed(err) }
        return resp.payload
    }

    @discardableResult
    func setAgentThinking(agentId: String, thinkingOptionId: String?) async throws -> AckResponsePayload {
        let requestId = UUID().uuidString
        let req = SetAgentThinkingRequest(
            requestId: requestId, agentId: agentId, thinkingOptionId: thinkingOptionId
        )
        let reply = try await requestResponse(requestId: requestId, outbound: .session(.setAgentThinking(req)))
        guard case let .setAgentThinkingResponse(resp) = reply else {
            throw DaemonError.protocolError("Expected set_agent_thinking_response, got \(reply)")
        }
        if let err = resp.payload.error, !err.isEmpty { throw DaemonError.rpcFailed(err) }
        return resp.payload
    }

    @discardableResult
    func cancelAgent(agentId: String) async throws -> CancelAgentResponse.Payload {
        let requestId = UUID().uuidString
        let req = CancelAgentRequest(requestId: requestId, agentId: agentId)
        let reply = try await requestResponse(requestId: requestId, outbound: .session(.cancelAgent(req)))
        guard case let .cancelAgentResponse(resp) = reply else {
            throw DaemonError.protocolError("Expected cancel_agent_response, got \(reply)")
        }
        return resp.payload
    }

    /// Send a user-driven rename for an agent. Daemon ≥ 0.1.79 echoes the
    /// new name back on the next `agent_update`; older daemons surface an
    /// unknown-type error which we let propagate so the caller can roll
    /// back the optimistic UI change.
    func updateAgent(agentId: String, name: String? = nil, labels: [String: String]? = nil) async throws {
        let requestId = UUID().uuidString
        let req = UpdateAgentRequest(requestId: requestId, agentId: agentId, name: name, labels: labels)
        try await rawSend(.session(.updateAgent(req)))
    }

    /// Ask the daemon for sessions started outside Paseo (Claude/Codex/
    /// OpenCode CLI history files) that haven't been imported yet. Daemon
    /// ≥ 0.1.79 returns the list synchronously; older daemons time out via
    /// `requestTimeout` and we return an empty list so the caller can
    /// surface "no sessions found" rather than spinning forever.
    func fetchImportableSessions(cwd: String? = nil, providers: [String]? = nil) async throws -> [ImportableSession] {
        let requestId = UUID().uuidString
        let req = FetchRecentProviderSessionsRequest(requestId: requestId, cwd: cwd, providers: providers)
        do {
            let reply = try await requestResponse(requestId: requestId, outbound: .session(.fetchRecentProviderSessions(req)))
            guard case let .fetchRecentProviderSessionsResponse(resp) = reply else {
                throw DaemonError.protocolError("Expected fetch_recent_provider_sessions_response, got \(reply)")
            }
            return resp.payload.entries
        } catch DaemonError.rpcTimeout {
            return []
        }
    }

    /// Import a discovered session. Fire-and-forget — the daemon emits an
    /// `agent_status` event when the import completes, which the live
    /// stream subscriber already routes into the agent list.
    func importAgent(providerId: String, providerHandleId: String, cwd: String? = nil) async throws {
        let requestId = UUID().uuidString
        let req = ImportAgentRequest(
            requestId: requestId,
            providerId: providerId,
            providerHandleId: providerHandleId,
            cwd: cwd
        )
        try await rawSend(.session(.importAgent(req)))
    }

    /// Patch the daemon's global config. Currently used for the
    /// "appendSystemPrompt" knob that gets injected into every new agent.
    /// Fire-and-forget — daemon broadcasts a `daemon_config_changed`
    /// status event that the UI subscribes to.
    func setDaemonConfig(appendSystemPrompt: String?) async throws {
        let requestId = UUID().uuidString
        let patch = DaemonConfigSetRequest.ConfigPatch(
            appendSystemPrompt: appendSystemPrompt,
            autoArchiveAfterMerge: nil
        )
        let req = DaemonConfigSetRequest(requestId: requestId, config: patch)
        try await rawSend(.session(.daemonConfigSet(req)))
    }

    func createAgent(
        cwd: String,
        provider: String,
        model: String? = nil,
        modeId: String? = nil,
        thinkingOptionId: String? = nil,
        initialPrompt: String? = nil,
        autoArchiveWorktree: Bool = false,
        worktreeBaseBranch: String? = nil
    ) async throws {
        let requestId = UUID().uuidString
        let config = CreateAgentRequest.Config(
            provider: provider,
            cwd: cwd,
            model: model,
            modeId: modeId,
            thinkingOptionId: thinkingOptionId
        )
        var req = CreateAgentRequest(requestId: requestId, config: config)
        req.initialPrompt = initialPrompt
        if autoArchiveWorktree {
            req.autoArchive = true
            req.worktree = .branchOff(baseBranch: worktreeBaseBranch)
        }
        try await rawSend(.session(.createAgent(req)))
    }

    /// Reply to a `permission_requested` event. For an AskUserQuestion, pass
    /// `.allow(updatedInput:)` carrying the questions + answers. For a tool
    /// permission, pass `.allow(updatedInput: nil)` to approve, or
    /// `.deny(message:)` to reject.
    func respondPermission(
        agentId: String,
        requestId: String,
        response: AgentPermissionResponseRequest.Response
    ) async throws {
        let req = AgentPermissionResponseRequest(
            agentId: agentId,
            requestId: requestId,
            response: response
        )
        try await rawSend(.session(.agentPermissionResponse(req)))
    }

    func archiveAgent(agentId: String) async throws {
        let requestId = UUID().uuidString
        let req = ArchiveAgentRequest(requestId: requestId, agentId: agentId)
        try await rawSend(.session(.archiveAgent(req)))
    }

    /// Returns the git remote URL for the workspace at `cwd`, or nil if not a git repo / no remote.
    func fetchWorkspaceGitRemote(cwd: String) async throws -> String? {
        let requestId = UUID().uuidString
        let req = FetchWorkspacesRequest(requestId: requestId)
        let reply = try await requestResponse(requestId: requestId, outbound: .session(.fetchWorkspaces(req)))
        guard case let .fetchWorkspacesResponse(resp) = reply else {
            throw DaemonError.protocolError("Expected fetch_workspaces_response, got \(reply)")
        }
        let match = resp.payload.entries.filter { ws in
            let dir = ws.workspaceDirectory ?? ws.projectRootPath
            return cwd == dir || cwd.hasPrefix(dir + "/") || cwd == ws.projectRootPath || cwd.hasPrefix(ws.projectRootPath + "/")
        }.max { a, b in
            let aLen = (a.workspaceDirectory ?? a.projectRootPath).count
            let bLen = (b.workspaceDirectory ?? b.projectRootPath).count
            return aLen < bLen
        }
        return match?.gitRuntime?.remoteUrl
    }

    func getProvidersSnapshot(cwd: String? = nil) async throws -> [ProviderSnapshot] {
        let requestId = UUID().uuidString
        let req = GetProvidersSnapshotRequest(requestId: requestId, cwd: cwd)
        let reply = try await requestResponse(requestId: requestId, outbound: .session(.getProvidersSnapshot(req)))
        guard case let .getProvidersSnapshotResponse(resp) = reply else {
            throw DaemonError.protocolError("Expected get_providers_snapshot_response, got \(reply)")
        }
        return resp.payload.entries
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
        // Schedule a timeout that fails *only* this pending request — it does
        // NOT close the socket. Mirrors the official client's `sendRequest`
        // (packages/server/src/client/daemon-client.ts), which fails the
        // waiter and leaves the WS alone so other in-flight RPCs survive.
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(DaemonClient.requestTimeout * 1_000_000_000))
            await self?.failPending(requestId: requestId, with: DaemonError.rpcTimeout)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { cont in
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
        // Any inbound frame proves the daemon is alive — reset the liveness
        // counter even before we route the frame. Pongs are the canonical
        // signal, but a session reply or status push works equally well and
        // avoids declaring death during a chatty RPC stream.
        unansweredPings = 0
        switch inbound {
        case .ping:
            Task { [weak self] in try? await self?.rawSend(.pong(PongMessage())) }
        case .pong:
            break
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
            case .fetchAgentTimelineResponse(let r): return r.payload.requestId
            case .sendAgentMessageResponse(let r): return r.payload.requestId
            case .setAgentModeResponse(let r): return r.payload.requestId
            case .setAgentModelResponse(let r): return r.payload.requestId
            case .setAgentThinkingResponse(let r): return r.payload.requestId
            case .getProvidersSnapshotResponse(let r): return r.payload.requestId
            case .cancelAgentResponse(let r): return r.payload.requestId
            case .fetchWorkspacesResponse(let r): return r.payload.requestId
            case .fetchRecentProviderSessionsResponse(let r): return r.payload.requestId
            case .status(let r): return r.payload.requestId  // agent_created response
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
