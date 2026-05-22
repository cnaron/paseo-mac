import Foundation

// MARK: - WebSocket protocol constants

enum WSProtocol {
    static let version = 1
}

// MARK: - JSON helper

/// Tiny dynamic JSON value used when the wire format is loose. Lets us peek
/// at structured error payloads and extract sensible text without modelling
/// every variant. Mirrors what upstream's TS callers do with `unknown`.
indirect enum JSONValue: Decodable, Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    /// Walk common JSON-RPC and ACP error shapes to find a human-readable
    /// string. Returns nil if no recognizable field is present, in which
    /// case the caller should fall back to `compactJSON()`.
    func errorReason() -> String? {
        if case .string(let s) = self { return s }
        guard case .object(let o) = self else { return nil }
        // Standard JSON-RPC: { code, message, data? }
        if case .string(let s)? = o["message"] {
            if case .object(let data)? = o["data"], case .string(let extra)? = data["message"], !extra.isEmpty {
                return "\(s) — \(extra)"
            }
            return s
        }
        // ACP-style: { error: { message } } or { reason }
        if case .object(let err)? = o["error"], case .string(let s)? = err["message"] { return s }
        if case .string(let s)? = o["error"] { return s }
        if case .string(let s)? = o["reason"] { return s }
        return nil
    }

    /// Compact JSON representation. Used as the last fallback so the user
    /// at least sees structure rather than "[object Object]".
    func compactJSON() -> String? {
        guard let data = try? JSONEncoder().encode(self) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

extension JSONValue: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Outbound (Mac → daemon)

struct HelloMessage: Encodable {
    let type = "hello"
    let clientId: String
    let clientType: ClientType
    let protocolVersion: Int
    let appVersion: String?
    let capabilities: Capabilities?

    enum ClientType: String, Encodable {
        case mobile, browser, cli, mcp
    }

    struct Capabilities: Encodable {
        var voice: Bool?
        var pushNotifications: Bool?
    }
}

struct PongMessage: Encodable { let type = "pong" }

/// Application-level keepalive. Sent every ~15s while connected so the
/// relay (and daemon) sees fresh app traffic on the wire — WebSocket
/// control-frame PINGs aren't always preserved across relays/CDNs.
/// Daemon replies with a bare `{"type":"pong"}`.
struct PingMessage: Encodable {
    let type = "ping"
    let requestId: String
    let clientSentAt: Int64    // ms since epoch
}

/// Session-level request wrapped in `{type:"session", message:<inner>}`.
enum SessionRequest: Encodable {
    case fetchAgents(FetchAgentsRequest)
    case fetchAgentTimeline(FetchAgentTimelineRequest)
    case sendAgentMessage(SendAgentMessageRequest)
    case setAgentMode(SetAgentModeRequest)
    case setAgentModel(SetAgentModelRequest)
    case setAgentThinking(SetAgentThinkingRequest)
    case getProvidersSnapshot(GetProvidersSnapshotRequest)
    case cancelAgent(CancelAgentRequest)
    case createAgent(CreateAgentRequest)
    case archiveAgent(ArchiveAgentRequest)
    case updateAgent(UpdateAgentRequest)
    case agentPermissionResponse(AgentPermissionResponseRequest)
    case fetchWorkspaces(FetchWorkspacesRequest)
    case daemonConfigSet(DaemonConfigSetRequest)
    case fetchRecentProviderSessions(FetchRecentProviderSessionsRequest)
    case importAgent(ImportAgentRequest)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .fetchAgents(let r): try c.encode(r)
        case .fetchAgentTimeline(let r): try c.encode(r)
        case .sendAgentMessage(let r): try c.encode(r)
        case .setAgentMode(let r): try c.encode(r)
        case .setAgentModel(let r): try c.encode(r)
        case .setAgentThinking(let r): try c.encode(r)
        case .getProvidersSnapshot(let r): try c.encode(r)
        case .cancelAgent(let r): try c.encode(r)
        case .createAgent(let r): try c.encode(r)
        case .archiveAgent(let r): try c.encode(r)
        case .updateAgent(let r): try c.encode(r)
        case .agentPermissionResponse(let r): try c.encode(r)
        case .fetchWorkspaces(let r): try c.encode(r)
        case .daemonConfigSet(let r): try c.encode(r)
        case .fetchRecentProviderSessions(let r): try c.encode(r)
        case .importAgent(let r): try c.encode(r)
        }
    }
}

// MARK: - Permission request / response

/// Decoded payload of a `permission_requested` event's `request` field.
/// `kind == "question"` (or `name == "AskUserQuestion"`) means the agent is
/// asking the user to pick from structured options, not just allow/deny a
/// tool call. `askUserQuestion` is non-nil exactly in that case.
struct PermissionRequestPayload: Decodable, Hashable, Sendable {
    let id: String
    let name: String          // tool name, e.g. "AskUserQuestion", "Bash"
    let kind: String          // "tool" | "plan" | "question" | "mode" | "other"
    let title: String?
    let description: String?
    let askUserQuestion: AskUserQuestion?

    var isQuestion: Bool { kind == "question" || askUserQuestion != nil }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, title, description, input
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(String.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.kind = try c.decode(String.self, forKey: .kind)
        self.title = try? c.decode(String.self, forKey: .title)
        self.description = try? c.decode(String.self, forKey: .description)
        if name == "AskUserQuestion" {
            self.askUserQuestion = try? c.decode(AskUserQuestion.self, forKey: .input)
        } else {
            self.askUserQuestion = nil
        }
    }
}

/// Typed view into `AskUserQuestion`'s tool input.
struct AskUserQuestion: Codable, Hashable, Sendable {
    let questions: [Question]

    struct Question: Codable, Hashable, Sendable, Identifiable {
        let header: String
        let question: String
        let multiSelect: Bool?
        let options: [Option]

        var id: String { header }

        struct Option: Codable, Hashable, Sendable, Identifiable {
            let label: String
            let description: String?

            var id: String { label }
        }
    }
}

/// Builds `agent_permission_response` payload. For an AskUserQuestion this
/// echoes the original questions back alongside the user's answers (keyed
/// by question header — daemon normalizes to whatever the tool expects).
struct AgentPermissionResponseRequest: Encodable {
    let type = "agent_permission_response"
    let agentId: String
    let requestId: String
    let response: Response

    enum Response: Encodable {
        case allow(updatedInput: AskUserQuestionAnswers?)
        case deny(message: String?)

        private enum Keys: String, CodingKey { case behavior, updatedInput, message }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .allow(let input):
                try c.encode("allow", forKey: .behavior)
                if let input { try c.encode(input, forKey: .updatedInput) }
            case .deny(let msg):
                try c.encode("deny", forKey: .behavior)
                try c.encodeIfPresent(msg, forKey: .message)
            }
        }
    }
}

/// Shape of `updatedInput` when answering AskUserQuestion. Carries the
/// original questions back verbatim so the daemon-side normalizer can
/// re-key answers to whatever the underlying tool wants.
struct AskUserQuestionAnswers: Encodable {
    let questions: [AskUserQuestion.Question]
    let answers: [String: String]
}

struct CreateAgentRequest: Encodable {
    let type = "create_agent_request"
    let requestId: String
    let config: Config
    var initialPrompt: String? = nil
    /// When true, daemon archives the agent — and prunes its worktree if
    /// one was created — as soon as it reaches a terminal lifecycle state.
    /// Requires daemon ≥ 0.1.79. Older daemons ignore the field, which is
    /// fine: the agent just stays around like any other.
    var autoArchive: Bool? = nil
    /// Optional worktree target. When set, daemon ≥ 0.1.79 creates a fresh
    /// worktree off the configured base before launching the agent. See
    /// `CreateAgentWorktreeTarget` upstream for the full shape.
    var worktree: WorktreeTarget? = nil

    private enum CodingKeys: String, CodingKey {
        case type, requestId, config, initialPrompt, autoArchive, worktree
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(config, forKey: .config)
        try c.encodeIfPresent(initialPrompt, forKey: .initialPrompt)
        try c.encodeIfPresent(autoArchive, forKey: .autoArchive)
        try c.encodeIfPresent(worktree, forKey: .worktree)
    }

    struct Config: Encodable {
        let provider: String
        let cwd: String
        let model: String?
        let modeId: String?
        /// Set in the createAgent payload itself so the daemon initializes
        /// the agent at the chosen thinking level. Sending it later via
        /// set_agent_thinking_request while turn 1 is starting up trips a
        /// daemon-side race that fails the turn with
        /// "Cannot read properties of null (reading 'push')".
        let thinkingOptionId: String?

        private enum CodingKeys: String, CodingKey {
            case provider, cwd, model, modeId, thinkingOptionId
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(provider, forKey: .provider)
            try c.encode(cwd, forKey: .cwd)
            try c.encodeIfPresent(model, forKey: .model)
            try c.encodeIfPresent(modeId, forKey: .modeId)
            try c.encodeIfPresent(thinkingOptionId, forKey: .thinkingOptionId)
        }
    }

    /// Discriminated union matching upstream's `CreateAgentWorktreeTargetSchema`.
    /// We only support the most common case (`branch-off`) for now; new variants
    /// can be added when we ship UI for them.
    enum WorktreeTarget: Encodable {
        case branchOff(baseBranch: String?)

        private enum Keys: String, CodingKey { case type, baseBranch }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .branchOff(let baseBranch):
                try c.encode("branch-off", forKey: .type)
                try c.encodeIfPresent(baseBranch, forKey: .baseBranch)
            }
        }
    }
}

struct CancelAgentRequest: Encodable {
    let type = "cancel_agent_request"
    let requestId: String
    let agentId: String
}

/// Update an agent's user-facing name (rename) and/or labels. Matches
/// upstream's `update_agent_request`. Daemon ≥ 0.1.79 honors this; older
/// daemons reject with an unknown-type error, surfaced to the user.
struct UpdateAgentRequest: Encodable {
    let type = "update_agent_request"
    let requestId: String
    let agentId: String
    var name: String? = nil
    var labels: [String: String]? = nil

    private enum CodingKeys: String, CodingKey {
        case type, requestId, agentId, name, labels
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(agentId, forKey: .agentId)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encodeIfPresent(labels, forKey: .labels)
    }
}

/// Ask the daemon for sessions started outside Paseo (Claude/Codex/
/// OpenCode/Pi CLI history files) that haven't been imported yet. Daemon
/// ≥ 0.1.79 honors this; older daemons silently drop the request.
struct FetchRecentProviderSessionsRequest: Encodable {
    let type = "fetch_recent_provider_sessions_request"
    let requestId: String
    var cwd: String? = nil
    var providers: [String]? = nil

    private enum CodingKeys: String, CodingKey { case type, requestId, cwd, providers }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(requestId, forKey: .requestId)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(providers, forKey: .providers)
    }
}

/// One session that can be imported — same shape as upstream's
/// `RecentProviderSessionDescriptorPayloadSchema`. `providerHandleId` is
/// the unique key we send back on `import_agent_request`.
struct ImportableSession: Decodable, Sendable, Hashable, Identifiable {
    let providerId: String
    let providerLabel: String
    let providerHandleId: String
    let cwd: String
    let title: String?
    let firstPromptPreview: String?
    let lastPromptPreview: String?
    let lastActivityAt: String

    var id: String { "\(providerId)/\(providerHandleId)" }
}

struct FetchRecentProviderSessionsResponse: Decodable, Sendable {
    let type: String
    let payload: Payload
    struct Payload: Decodable, Sendable {
        let requestId: String
        let entries: [ImportableSession]
        let filteredAlreadyImportedCount: Int?
    }
}

/// Import a previously discovered session into the daemon. Daemon picks
/// up where the CLI left off, materializes the timeline, and broadcasts
/// the agent so the rest of the app sees it via `agents_listed` /
/// `agent_update` events. Matches `import_agent_request`.
struct ImportAgentRequest: Encodable {
    let type = "import_agent_request"
    let requestId: String
    var providerId: String? = nil
    var providerHandleId: String? = nil
    var cwd: String? = nil
    var labels: [String: String]? = nil

    private enum CodingKeys: String, CodingKey {
        case type, requestId, providerId, providerHandleId, cwd, labels
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(requestId, forKey: .requestId)
        try c.encodeIfPresent(providerId, forKey: .providerId)
        try c.encodeIfPresent(providerHandleId, forKey: .providerHandleId)
        try c.encodeIfPresent(cwd, forKey: .cwd)
        try c.encodeIfPresent(labels, forKey: .labels)
    }
}

/// Patch a subset of the daemon-wide config. Currently only carries the
/// global `appendSystemPrompt` knob (the field newer daemons accept), but
/// the schema is intentionally permissive — anything we put in `config`
/// is forwarded as-is so future settings work without new RPC types.
struct DaemonConfigSetRequest: Encodable {
    let type = "set_daemon_config_request"
    let requestId: String
    let config: ConfigPatch

    struct ConfigPatch: Encodable {
        var appendSystemPrompt: String?
        var autoArchiveAfterMerge: Bool?

        private enum CodingKeys: String, CodingKey {
            case appendSystemPrompt, autoArchiveAfterMerge
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(appendSystemPrompt, forKey: .appendSystemPrompt)
            try c.encodeIfPresent(autoArchiveAfterMerge, forKey: .autoArchiveAfterMerge)
        }
    }
}

struct ArchiveAgentRequest: Encodable {
    let type = "archive_agent_request"
    let requestId: String
    let agentId: String
}

struct SetAgentModeRequest: Encodable {
    let type = "set_agent_mode_request"
    let requestId: String
    let agentId: String
    let modeId: String
}

struct SetAgentModelRequest: Encodable {
    let type = "set_agent_model_request"
    let requestId: String
    let agentId: String
    let modelId: String?   // null clears the override
}

struct SetAgentThinkingRequest: Encodable {
    let type = "set_agent_thinking_request"
    let requestId: String
    let agentId: String
    let thinkingOptionId: String?
}

struct GetProvidersSnapshotRequest: Encodable {
    let type = "get_providers_snapshot_request"
    let requestId: String
    var cwd: String?
}

struct FetchAgentsRequest: Encodable {
    let type = "fetch_agents_request"
    let requestId: String
    var filter: AgentFilter?
    var sort: [AgentSort]?
    var page: AgentPage?
    var subscribe: AgentSubscribe?

    struct AgentFilter: Encodable {
        var includeArchived: Bool?
        var statuses: [String]?
        var requiresAttention: Bool?
    }
    struct AgentSort: Encodable { let key: String; let direction: String }
    struct AgentPage: Encodable { let limit: Int; var cursor: String? }
    struct AgentSubscribe: Encodable { var subscriptionId: String? }
}

struct FetchAgentTimelineRequest: Encodable {
    let type = "fetch_agent_timeline_request"
    let requestId: String
    let agentId: String
    /// "tail" (default, most recent), "before", or "after".
    var direction: String?
    var cursor: AgentTimelineCursor?
    /// 0 = all. Omit to let the daemon pick a default.
    var limit: Int?
    /// "projected" (recommended for UI) or "canonical" (raw event log).
    var projection: String?
}

struct AgentTimelineCursor: Codable, Hashable, Sendable {
    let epoch: String
    let seq: Int
}

struct SendAgentMessageRequest: Encodable {
    let type = "send_agent_message_request"
    let requestId: String
    let agentId: String
    let text: String
    var messageId: String?
    var images: [ImageAttachment]?
    var attachments: [AgentAttachment]?

    struct ImageAttachment: Encodable {
        let data: String      // base64
        let mimeType: String
    }

    /// Upstream `AgentAttachmentsSchema` is a flexible union (GitHub PR/issue etc.).
    /// We keep a minimal shape for MVP and extend as needed.
    struct AgentAttachment: Encodable {
        let kind: String
        let name: String?
        let mimeType: String?
        let data: String?
        let url: String?
    }
}

enum WSOutbound: Encodable {
    case hello(HelloMessage)
    case pong(PongMessage)
    case ping(PingMessage)
    case session(SessionRequest)

    private enum Keys: String, CodingKey { case type, message }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .hello(let m): try m.encode(to: encoder)
        case .pong(let m): try m.encode(to: encoder)
        case .ping(let m): try m.encode(to: encoder)
        case .session(let inner):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode("session", forKey: .type)
            try c.encode(inner, forKey: .message)
        }
    }
}

// MARK: - Inbound (daemon → Mac)

/// Session-level inbound messages. Unknown types are preserved as `.unknown`
/// (with raw JSON) for logging without breaking decode.
enum SessionInbound: Decodable, @unchecked Sendable {
    case serverInfo(ServerInfoPayload)
    case status(StatusPayload)
    case fetchAgentsResponse(FetchAgentsResponse)
    case fetchAgentTimelineResponse(FetchAgentTimelineResponse)
    case sendAgentMessageResponse(SendAgentMessageResponse)
    case agentStream(AgentStreamMessage)
    case agentStatus(AgentStatusMessage)
    case setAgentModeResponse(SetAgentModeResponse)
    case setAgentModelResponse(SetAgentModelResponse)
    case setAgentThinkingResponse(SetAgentThinkingResponse)
    case getProvidersSnapshotResponse(GetProvidersSnapshotResponse)
    case providersSnapshotUpdate(ProvidersSnapshotUpdatePayload)
    case cancelAgentResponse(CancelAgentResponse)
    case fetchWorkspacesResponse(FetchWorkspacesResponse)
    case fetchRecentProviderSessionsResponse(FetchRecentProviderSessionsResponse)
    case unknown(type: String, raw: Data)

    private enum Keys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        let raw = try Self.reencode(decoder)

        switch type {
        case "server_info":
            self = .serverInfo(try JSONDecoder.paseo.decode(ServerInfoPayload.self, from: raw))
        case "status":
            self = .status(try JSONDecoder.paseo.decode(StatusPayload.self, from: raw))
        case "fetch_agents_response":
            self = .fetchAgentsResponse(try JSONDecoder.paseo.decode(FetchAgentsResponse.self, from: raw))
        case "fetch_agent_timeline_response":
            self = .fetchAgentTimelineResponse(try JSONDecoder.paseo.decode(FetchAgentTimelineResponse.self, from: raw))
        case "send_agent_message_response":
            self = .sendAgentMessageResponse(try JSONDecoder.paseo.decode(SendAgentMessageResponse.self, from: raw))
        case "agent_stream":
            self = .agentStream(try JSONDecoder.paseo.decode(AgentStreamMessage.self, from: raw))
        case "agent_status":
            self = .agentStatus(try JSONDecoder.paseo.decode(AgentStatusMessage.self, from: raw))
        case "set_agent_mode_response":
            self = .setAgentModeResponse(try JSONDecoder.paseo.decode(SetAgentModeResponse.self, from: raw))
        case "set_agent_model_response":
            self = .setAgentModelResponse(try JSONDecoder.paseo.decode(SetAgentModelResponse.self, from: raw))
        case "set_agent_thinking_response":
            self = .setAgentThinkingResponse(try JSONDecoder.paseo.decode(SetAgentThinkingResponse.self, from: raw))
        case "get_providers_snapshot_response":
            self = .getProvidersSnapshotResponse(try JSONDecoder.paseo.decode(GetProvidersSnapshotResponse.self, from: raw))
        case "providers_snapshot_update":
            self = .providersSnapshotUpdate(try JSONDecoder.paseo.decode(ProvidersSnapshotUpdatePayload.self, from: raw))
        case "cancel_agent_response":
            self = .cancelAgentResponse(try JSONDecoder.paseo.decode(CancelAgentResponse.self, from: raw))
        case "fetch_workspaces_response":
            self = .fetchWorkspacesResponse(try JSONDecoder.paseo.decode(FetchWorkspacesResponse.self, from: raw))
        case "fetch_recent_provider_sessions_response":
            self = .fetchRecentProviderSessionsResponse(try JSONDecoder.paseo.decode(FetchRecentProviderSessionsResponse.self, from: raw))
        default:
            self = .unknown(type: type, raw: raw)
        }
    }

    private static func reencode(_ decoder: Decoder) throws -> Data {
        let single = try decoder.singleValueContainer()
        let json = try single.decode(RawJSON.self)
        return try JSONEncoder.paseo.encode(json)
    }
}

enum WSInbound: Decodable {
    case ping
    case pong
    case session(SessionInbound)
    case unknown(type: String, raw: Data)

    private enum Keys: String, CodingKey { case type, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "ping":
            self = .ping
        case "pong":
            self = .pong
        case "session":
            self = .session(try c.decode(SessionInbound.self, forKey: .message))
        default:
            let raw = try {
                let s = try decoder.singleValueContainer()
                let j = try s.decode(RawJSON.self)
                return try JSONEncoder.paseo.encode(j)
            }()
            self = .unknown(type: type, raw: raw)
        }
    }
}

// MARK: - Simple session payloads

struct ServerInfoPayload: Decodable, Sendable {
    let type: String
    let status: String
    let serverId: String?
    let hostname: String?
    let version: String?
}

/// `{type:"status", payload:{status:"server_info", ...}}` wrapper.
struct StatusPayload: Decodable, Sendable {
    let type: String
    let payload: Inner
    struct Inner: Decodable, Sendable {
        let status: String
        let serverId: String?
        let hostname: String?
        let version: String?
        let agentId: String?    // present when status == "agent_created"
        let requestId: String?  // present when status == "agent_created"
    }
}

struct FetchAgentsResponse: Decodable, Sendable {
    let type: String
    let payload: Payload
    struct Payload: Decodable, Sendable {
        let requestId: String
        let entries: [Entry]
        let pageInfo: PageInfo?
        struct Entry: Decodable, Sendable { let agent: AgentSnapshot }
        struct PageInfo: Decodable, Sendable {
            let nextCursor: String?
            let prevCursor: String?
            let hasMore: Bool?
        }
        var agents: [AgentSnapshot] { entries.map(\.agent) }
    }
}

struct SendAgentMessageResponse: Decodable, Sendable {
    let type: String
    let payload: Payload
    struct Payload: Decodable, Sendable {
        let requestId: String
        let agentId: String?
        let accepted: Bool?
        let error: String?
    }
}

struct AckResponsePayload: Decodable, Sendable {
    let requestId: String
    let agentId: String?
    let accepted: Bool?
    let error: String?
}

struct SetAgentModeResponse: Decodable, Sendable {
    let type: String
    let payload: AckResponsePayload
}

struct SetAgentModelResponse: Decodable, Sendable {
    let type: String
    let payload: AckResponsePayload
}

struct SetAgentThinkingResponse: Decodable, Sendable {
    let type: String
    let payload: AckResponsePayload
}

/// Lazily pushed status updates for a single agent. Handy for keeping the
/// sidebar's little status dot in sync without a full `fetch_agents`.
struct AgentStatusMessage: Decodable, Sendable {
    let type: String     // "agent_status"
    let payload: Payload
    struct Payload: Decodable, Sendable {
        let agentId: String
        let status: String
        let info: AgentSnapshot?
    }
}

struct CancelAgentResponse: Decodable, Sendable {
    let type: String
    let payload: Payload
    struct Payload: Decodable, Sendable {
        let requestId: String
        let agentId: String
    }
}

struct GetProvidersSnapshotResponse: Decodable, Sendable {
    let type: String    // "get_providers_snapshot_response"
    let payload: Payload
    struct Payload: Decodable, Sendable {
        let entries: [ProviderSnapshot]
        let generatedAt: String
        let requestId: String
    }
}

struct ProvidersSnapshotUpdatePayload: Decodable, Sendable {
    let type: String
    let payload: Payload
    struct Payload: Decodable, Sendable {
        let entries: [ProviderSnapshot]
        let generatedAt: String?
        let cwd: String?
    }
}

/// One provider's model + mode catalog, as returned by
/// `get_providers_snapshot_response`. Fields we don't consume are dropped.
struct ProviderSnapshot: Decodable, Sendable, Hashable, Identifiable {
    let provider: String              // "claude" | "codex" | ...
    let status: String                // "ready" | "loading" | "error" | "unavailable"
    let error: String?
    let models: [ModelDefinition]?
    let modes: [AgentMode]?
    let label: String?
    let defaultModeId: String?

    var id: String { provider }
}

struct ModelDefinition: Decodable, Sendable, Hashable, Identifiable {
    let provider: String
    let id: String
    let label: String
    let description: String?
    let isDefault: Bool?
    let thinkingOptions: [SelectOption]?
    let defaultThinkingOptionId: String?
}

struct AgentMode: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let label: String
    let description: String?
    let icon: String?
    let colorTier: String?
}

struct SelectOption: Decodable, Sendable, Hashable, Identifiable {
    let id: String
    let label: String
    let description: String?
    let isDefault: Bool?
}

// MARK: - Timeline

/// One item in the agent timeline. We decode the text-bearing shapes and keep
/// everything else as `.other` (with the raw type name) so future additions
/// don't break the client.
enum TimelineItem: Decodable, Hashable, Sendable {
    case userMessage(text: String, messageId: String?)
    case assistantMessage(text: String)
    case reasoning(text: String)
    case toolCall(name: String, status: String, callId: String, detail: ToolDetail)
    case todo(items: [TodoItem])
    case error(message: String)
    /// Codex' `/compact` (and auto-compaction) event. `status="loading"`
    /// shows up while the daemon is compacting; the same call ID flips
    /// to `status="completed"` when done. `trigger` is "auto" / "manual".
    /// `preTokens` is the context-window size before compaction.
    case compaction(status: String, trigger: String?, preTokens: Int?)
    case other(type: String)

    struct TodoItem: Decodable, Hashable, Sendable {
        let text: String
        let completed: Bool
    }

    private enum Keys: String, CodingKey {
        case type, text, messageId, name, status, callId, id, detail, items, message, trigger, preTokens
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "user_message":
            self = .userMessage(
                text: (try? c.decode(String.self, forKey: .text)) ?? "",
                messageId: try? c.decode(String.self, forKey: .messageId)
            )
        case "assistant_message":
            self = .assistantMessage(text: (try? c.decode(String.self, forKey: .text)) ?? "")
        case "reasoning":
            self = .reasoning(text: (try? c.decode(String.self, forKey: .text)) ?? "")
        case "tool_call":
            let detail = (try? c.decode(ToolDetail.self, forKey: .detail)) ?? .other(type: "")
            self = .toolCall(
                name: (try? c.decode(String.self, forKey: .name)) ?? "",
                status: (try? c.decode(String.self, forKey: .status)) ?? "",
                callId: (try? c.decode(String.self, forKey: .id)) ?? (try? c.decode(String.self, forKey: .callId)) ?? "",
                detail: detail
            )
        case "todo":
            let items = (try? c.decode([TodoItem].self, forKey: .items)) ?? []
            self = .todo(items: items)
        case "error":
            // Older daemons send a plain string; newer daemons (and ACP
            // providers) send a structured `{ code, message, data }` object.
            // String("[object Object]") is the JS-side failure mode for the
            // latter when callers used `String(err)` directly — we'd see
            // that text on the wire and now prefer the structured shape.
            self = .error(message: Self.decodeErrorMessage(container: c))
        case "compaction":
            self = .compaction(
                status: (try? c.decode(String.self, forKey: .status)) ?? "completed",
                trigger: try? c.decode(String.self, forKey: .trigger),
                preTokens: try? c.decode(Int.self, forKey: .preTokens)
            )
        default:
            self = .other(type: type)
        }
    }

    var displayKind: String {
        switch self {
        case .userMessage: "user"
        case .assistantMessage: "assistant"
        case .reasoning: "reasoning"
        case .toolCall: "tool"
        case .todo: "todo"
        case .error: "error"
        case .compaction: "compaction"
        case .other(let t): t
        }
    }

    /// Extract a user-facing error string from a `type: "error"` timeline
    /// item. Handles three on-the-wire shapes:
    ///   1. `{ "message": "boom" }` — plain string (older daemons).
    ///   2. `{ "message": { "message": "boom", "code": -32000 } }` — JSON-RPC
    ///      error nested under `message`, which is what ACP providers ship.
    ///   3. `{ "message": { ...arbitrary... } }` — fall back to JSON encoding
    ///      so the user sees structure instead of "[object Object]".
    private static func decodeErrorMessage(container c: KeyedDecodingContainer<Keys>) -> String {
        if let s = try? c.decode(String.self, forKey: .message), !s.isEmpty {
            return s
        }
        if let obj = try? c.decode(JSONValue.self, forKey: .message) {
            return obj.errorReason() ?? obj.compactJSON() ?? ""
        }
        return ""
    }

    var displayText: String {
        switch self {
        case .userMessage(let t, _): return t
        case .assistantMessage(let t): return t
        case .reasoning(let t): return t
        case .toolCall(let name, let status, _, _): return "\(name) · \(status)"
        case .todo(let items):
            return items.map { ($0.completed ? "[x] " : "[ ] ") + $0.text }.joined(separator: "\n")
        case .error(let m):
            // Pre-0.1.79 daemons can emit "[object Object]" when a JSON-RPC
            // error escaped without proper serialization. The structured
            // decoder above already recovers a usable string in many of
            // those cases; this is the last-resort fallback when even the
            // structured shape ended up stringified.
            if m.contains("[object Object]") {
                return "Backend internal error (the daemon couldn't serialize the upstream error)"
            }
            return m
        case .compaction(let status, let trigger, let preTokens):
            let action = (trigger == "manual") ? "Compacted" : "Auto-compacted"
            let suffix = preTokens.map { " · was \($0.formatted()) tokens" } ?? ""
            return status == "loading"
                ? "Compacting context…\(suffix)"
                : "\(action) context\(suffix)"
        case .other(let t): return "[\(t)]"
        }
    }
}

/// Decoded detail payload for a `tool_call` timeline item. Mirrors
/// `ToolCallDetailPayloadSchema` in upstream messages.ts, trimmed to the
/// fields we actually render. Anything we don't explicitly model falls
/// through as `.other(type:)`.
enum ToolDetail: Decodable, Hashable, Sendable {
    case shell(command: String, cwd: String?, output: String?, exitCode: Int?)
    case read(filePath: String, content: String?, offset: Int?, limit: Int?)
    case edit(filePath: String, unifiedDiff: String?, oldString: String?, newString: String?)
    case write(filePath: String, content: String?)
    case search(query: String, toolName: String?, filePaths: [String]?, webResults: [WebResult]?, numMatches: Int?, content: String?)
    case fetch(url: String, prompt: String?, result: String?, code: Int?)
    case subAgent(subAgentType: String?, description: String?, log: String)
    case plainText(label: String?, text: String?, icon: String?)
    case plan(text: String)
    case other(type: String)

    struct WebResult: Decodable, Hashable, Sendable {
        let title: String
        let url: String
    }

    private enum Keys: String, CodingKey {
        case type, command, cwd, output, exitCode
        case filePath, content, offset, limit
        case unifiedDiff, oldString, newString
        case query, toolName, filePaths, webResults, numMatches
        case url, prompt, result, code
        case subAgentType, description, log
        case label, text, icon
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let t = (try? c.decode(String.self, forKey: .type)) ?? ""
        switch t {
        case "shell":
            self = .shell(
                command: (try? c.decode(String.self, forKey: .command)) ?? "",
                cwd: try? c.decode(String.self, forKey: .cwd),
                output: try? c.decode(String.self, forKey: .output),
                exitCode: try? c.decode(Int.self, forKey: .exitCode)
            )
        case "read":
            self = .read(
                filePath: (try? c.decode(String.self, forKey: .filePath)) ?? "",
                content: try? c.decode(String.self, forKey: .content),
                offset: try? c.decode(Int.self, forKey: .offset),
                limit: try? c.decode(Int.self, forKey: .limit)
            )
        case "edit":
            self = .edit(
                filePath: (try? c.decode(String.self, forKey: .filePath)) ?? "",
                unifiedDiff: try? c.decode(String.self, forKey: .unifiedDiff),
                oldString: try? c.decode(String.self, forKey: .oldString),
                newString: try? c.decode(String.self, forKey: .newString)
            )
        case "write":
            self = .write(
                filePath: (try? c.decode(String.self, forKey: .filePath)) ?? "",
                content: try? c.decode(String.self, forKey: .content)
            )
        case "search":
            self = .search(
                query: (try? c.decode(String.self, forKey: .query)) ?? "",
                toolName: try? c.decode(String.self, forKey: .toolName),
                filePaths: try? c.decode([String].self, forKey: .filePaths),
                webResults: try? c.decode([WebResult].self, forKey: .webResults),
                numMatches: try? c.decode(Int.self, forKey: .numMatches),
                content: try? c.decode(String.self, forKey: .content)
            )
        case "fetch":
            self = .fetch(
                url: (try? c.decode(String.self, forKey: .url)) ?? "",
                prompt: try? c.decode(String.self, forKey: .prompt),
                result: try? c.decode(String.self, forKey: .result),
                code: try? c.decode(Int.self, forKey: .code)
            )
        case "sub_agent":
            self = .subAgent(
                subAgentType: try? c.decode(String.self, forKey: .subAgentType),
                description: try? c.decode(String.self, forKey: .description),
                log: (try? c.decode(String.self, forKey: .log)) ?? ""
            )
        case "plain_text":
            self = .plainText(
                label: try? c.decode(String.self, forKey: .label),
                text: try? c.decode(String.self, forKey: .text),
                icon: try? c.decode(String.self, forKey: .icon)
            )
        case "plan":
            self = .plan(text: (try? c.decode(String.self, forKey: .text)) ?? "")
        default:
            self = .other(type: t)
        }
    }
}

struct TimelineEntry: Decodable, Hashable, Sendable, Identifiable {
    let item: TimelineItem
    let timestamp: String
    let seqStart: Int
    let seqEnd: Int

    /// Stable identity based on the canonical seq range so SwiftUI lists
    /// don't re-create rows on incremental stream updates.
    var id: String { "\(seqStart)-\(seqEnd)" }
}

struct FetchAgentTimelineResponse: Decodable, Sendable {
    let type: String
    let payload: Payload
    struct Payload: Decodable, Sendable {
        let requestId: String
        let agentId: String
        let epoch: String
        let entries: [TimelineEntry]
        let hasOlder: Bool
        let hasNewer: Bool
        let startCursor: AgentTimelineCursor?
        let endCursor: AgentTimelineCursor?
        let error: String?
    }
}

// MARK: - Agent stream events

struct AgentStreamMessage: Decodable, Sendable {
    let type: String   // "agent_stream"
    let payload: Payload

    struct Payload: Decodable, Sendable {
        let agentId: String
        let timestamp: String
        let seq: Int?
        let epoch: String?
        let event: AgentStreamEvent
    }
}

enum AgentStreamEvent: Decodable, Sendable {
    case threadStarted(sessionId: String)
    case turnStarted
    case turnCompleted
    case turnFailed(error: String)
    case turnCanceled(reason: String)
    case timelineUpdated(item: TimelineItem)
    case permissionRequested(request: PermissionRequestPayload?)
    case permissionResolved(requestId: String)
    case attentionRequired(reason: String)
    case other(type: String)

    private enum Keys: String, CodingKey {
        case type, sessionId, error, reason, item, request, requestId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "thread_started":
            self = .threadStarted(sessionId: (try? c.decode(String.self, forKey: .sessionId)) ?? "")
        case "turn_started":
            self = .turnStarted
        case "turn_completed":
            self = .turnCompleted
        case "turn_failed":
            self = .turnFailed(error: (try? c.decode(String.self, forKey: .error)) ?? "")
        case "turn_canceled":
            self = .turnCanceled(reason: (try? c.decode(String.self, forKey: .reason)) ?? "")
        case "timeline":
            let item = try c.decode(TimelineItem.self, forKey: .item)
            self = .timelineUpdated(item: item)
        case "permission_requested":
            let payload = try? c.decode(PermissionRequestPayload.self, forKey: .request)
            self = .permissionRequested(request: payload)
        case "permission_resolved":
            self = .permissionResolved(requestId: (try? c.decode(String.self, forKey: .requestId)) ?? "")
        case "attention_required":
            self = .attentionRequired(reason: (try? c.decode(String.self, forKey: .reason)) ?? "")
        default:
            self = .other(type: type)
        }
    }
}

// MARK: - Agent snapshot

// MARK: - Workspace git remote fetch

struct FetchWorkspacesRequest: Encodable {
    let type = "fetch_workspaces_request"
    let requestId: String
}

struct WorkspaceGitRuntime: Decodable, Sendable {
    let currentBranch: String?
    let remoteUrl: String?
}

struct WorkspaceDescriptor: Decodable, Sendable {
    let id: String
    let workspaceDirectory: String?
    let projectRootPath: String
    let gitRuntime: WorkspaceGitRuntime?
}

struct FetchWorkspacesResponse: Decodable, Sendable {
    let type: String
    let payload: Payload
    struct Payload: Decodable, Sendable {
        let requestId: String
        let entries: [WorkspaceDescriptor]
    }
}

struct AgentSnapshot: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let provider: String?
    let cwd: String
    let status: String
    let title: String?
    let createdAt: String
    let updatedAt: String
    let lastUserMessageAt: String?
    let model: String?
    let thinkingOptionId: String?
    let effectiveThinkingOptionId: String?
    let currentModeId: String?
    let availableModes: [AgentMode]?
    let lastUsage: AgentUsage?
    let archivedAt: String?
    let requiresAttention: Bool?
    let attentionReason: String?
    /// Free-form key/value labels the daemon attaches to an agent. Used by
    /// upstream to track subagent → parent relationships via the
    /// `parent-agent-id` key. The daemon may omit this entirely for older
    /// agents, so the field is optional and defaulted so the memberwise
    /// init that local `with*` helpers rely on stays argument-compatible.
    let labels: [String: String]? = nil

    var displayName: String {
        if let t = title, !t.isEmpty { return t }
        return String(id.prefix(8))
    }

    /// Agent ID of this agent's parent, if it was spawned as a subagent.
    /// `nil` for top-level agents (the common case).
    var parentAgentId: String? {
        labels?["parent-agent-id"] ?? labels?["paseo:parent-agent-id"]
    }
}

/// Rolling usage snapshot for an agent — tokens in/out, total cost, and
/// context-window occupancy. Mirrors `AgentUsageSchema` in upstream messages.ts.
struct AgentUsage: Decodable, Sendable, Hashable {
    let inputTokens: Int?
    let cachedInputTokens: Int?
    let outputTokens: Int?
    let totalCostUsd: Double?
    let contextWindowMaxTokens: Int?
    let contextWindowUsedTokens: Int?
}

// MARK: - Shared helpers

extension JSONEncoder {
    static let paseo: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
}

extension JSONDecoder {
    static let paseo: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()
}

enum RawJSON: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RawJSON])
    case object([String: RawJSON])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([RawJSON].self) { self = .array(v); return }
        if let v = try? c.decode([String: RawJSON].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON token")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
