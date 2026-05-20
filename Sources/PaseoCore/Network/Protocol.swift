import Foundation

// MARK: - WebSocket protocol constants

public enum WSProtocol {
    public static let version = 1
}

// MARK: - Outbound (Mac → daemon)

public struct HelloMessage: Encodable, Sendable {
    public let type = "hello"
    public let clientId: String
    public let clientType: ClientType
    public let protocolVersion: Int
    public let appVersion: String?
    public let capabilities: Capabilities?

    public enum ClientType: String, Encodable, Sendable {
        case mobile, browser, cli, mcp
    }

    public struct Capabilities: Encodable, Sendable {
        public var voice: Bool?
        public var pushNotifications: Bool?
        public init(voice: Bool? = nil, pushNotifications: Bool? = nil) {
            self.voice = voice
            self.pushNotifications = pushNotifications
        }
    }

    public init(clientId: String, clientType: ClientType, protocolVersion: Int, appVersion: String?, capabilities: Capabilities?) {
        self.clientId = clientId
        self.clientType = clientType
        self.protocolVersion = protocolVersion
        self.appVersion = appVersion
        self.capabilities = capabilities
    }
}

public struct PongMessage: Encodable, Sendable {
    public let type = "pong"
    public init() {}
}

/// Application-level keepalive. Sent every ~15s while connected so the
/// relay (and daemon) sees fresh app traffic on the wire — WebSocket
/// control-frame PINGs aren't always preserved across relays/CDNs.
/// Daemon replies with a bare `{"type":"pong"}`.
public struct PingMessage: Encodable, Sendable {
    public let type = "ping"
    public let requestId: String
    public let clientSentAt: Int64    // ms since epoch
    public init(requestId: String, clientSentAt: Int64) {
        self.requestId = requestId
        self.clientSentAt = clientSentAt
    }
}

/// Session-level request wrapped in `{type:"session", message:<inner>}`.
public enum SessionRequest: Encodable, Sendable {
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
    case agentPermissionResponse(AgentPermissionResponseRequest)
    case fetchWorkspaces(FetchWorkspacesRequest)

    public func encode(to encoder: Encoder) throws {
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
        case .agentPermissionResponse(let r): try c.encode(r)
        case .fetchWorkspaces(let r): try c.encode(r)
        }
    }
}

// MARK: - Permission request / response

/// Decoded payload of a `permission_requested` event's `request` field.
/// `kind == "question"` (or `name == "AskUserQuestion"`) means the agent is
/// asking the user to pick from structured options, not just allow/deny a
/// tool call. `askUserQuestion` is non-nil exactly in that case.
public struct PermissionRequestPayload: Decodable, Hashable, Sendable {
    public let id: String
    public let name: String          // tool name, e.g. "AskUserQuestion", "Bash"
    public let kind: String          // "tool" | "plan" | "question" | "mode" | "other"
    public let title: String?
    public let description: String?
    public let askUserQuestion: AskUserQuestion?

    public var isQuestion: Bool { kind == "question" || askUserQuestion != nil }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, title, description, input
    }

    public init(from decoder: Decoder) throws {
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
public struct AskUserQuestion: Codable, Hashable, Sendable {
    public let questions: [Question]

    public struct Question: Codable, Hashable, Sendable, Identifiable {
        public let header: String
        public let question: String
        public let multiSelect: Bool?
        public let options: [Option]

        public var id: String { header }

        public struct Option: Codable, Hashable, Sendable, Identifiable {
            public let label: String
            public let description: String?

            public var id: String { label }
        }
    }
}

/// Builds `agent_permission_response` payload. For an AskUserQuestion this
/// echoes the original questions back alongside the user's answers (keyed
/// by question header — daemon normalizes to whatever the tool expects).
public struct AgentPermissionResponseRequest: Encodable, Sendable {
    public let type = "agent_permission_response"
    public let agentId: String
    public let requestId: String
    public let response: Response

    public init(agentId: String, requestId: String, response: Response) {
        self.agentId = agentId
        self.requestId = requestId
        self.response = response
    }

    public enum Response: Encodable, Sendable {
        case allow(updatedInput: AskUserQuestionAnswers?)
        case deny(message: String?)

        private enum Keys: String, CodingKey { case behavior, updatedInput, message }

        public func encode(to encoder: Encoder) throws {
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
public struct AskUserQuestionAnswers: Encodable, Sendable {
    public let questions: [AskUserQuestion.Question]
    public let answers: [String: String]
    public init(questions: [AskUserQuestion.Question], answers: [String: String]) {
        self.questions = questions
        self.answers = answers
    }
}

public struct CreateAgentRequest: Encodable, Sendable {
    public let type = "create_agent_request"
    public let requestId: String
    public let config: Config
    public var initialPrompt: String? = nil

    private enum CodingKeys: String, CodingKey {
        case type, requestId, config, initialPrompt
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(requestId, forKey: .requestId)
        try c.encode(config, forKey: .config)
        try c.encodeIfPresent(initialPrompt, forKey: .initialPrompt)
    }

    public init(requestId: String, config: Config) {
        self.requestId = requestId
        self.config = config
    }

    public struct Config: Encodable, Sendable {
        public let provider: String
        public let cwd: String
        public let model: String?
        public let modeId: String?
        /// Set in the createAgent payload itself so the daemon initializes
        /// the agent at the chosen thinking level. Sending it later via
        /// set_agent_thinking_request while turn 1 is starting up trips a
        /// daemon-side race that fails the turn with
        /// "Cannot read properties of null (reading 'push')".
        public let thinkingOptionId: String?

        private enum CodingKeys: String, CodingKey {
            case provider, cwd, model, modeId, thinkingOptionId
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(provider, forKey: .provider)
            try c.encode(cwd, forKey: .cwd)
            try c.encodeIfPresent(model, forKey: .model)
            try c.encodeIfPresent(modeId, forKey: .modeId)
            try c.encodeIfPresent(thinkingOptionId, forKey: .thinkingOptionId)
        }

        public init(provider: String, cwd: String, model: String?, modeId: String?, thinkingOptionId: String?) {
            self.provider = provider
            self.cwd = cwd
            self.model = model
            self.modeId = modeId
            self.thinkingOptionId = thinkingOptionId
        }
    }
}

public struct CancelAgentRequest: Encodable, Sendable {
    public let type = "cancel_agent_request"
    public let requestId: String
    public let agentId: String
    public init(requestId: String, agentId: String) {
        self.requestId = requestId
        self.agentId = agentId
    }
}

public struct ArchiveAgentRequest: Encodable, Sendable {
    public let type = "archive_agent_request"
    public let requestId: String
    public let agentId: String
    public init(requestId: String, agentId: String) {
        self.requestId = requestId
        self.agentId = agentId
    }
}

public struct SetAgentModeRequest: Encodable, Sendable {
    public let type = "set_agent_mode_request"
    public let requestId: String
    public let agentId: String
    public let modeId: String
    public init(requestId: String, agentId: String, modeId: String) {
        self.requestId = requestId
        self.agentId = agentId
        self.modeId = modeId
    }
}

public struct SetAgentModelRequest: Encodable, Sendable {
    public let type = "set_agent_model_request"
    public let requestId: String
    public let agentId: String
    public let modelId: String?   // null clears the override
    public init(requestId: String, agentId: String, modelId: String?) {
        self.requestId = requestId
        self.agentId = agentId
        self.modelId = modelId
    }
}

public struct SetAgentThinkingRequest: Encodable, Sendable {
    public let type = "set_agent_thinking_request"
    public let requestId: String
    public let agentId: String
    public let thinkingOptionId: String?
    public init(requestId: String, agentId: String, thinkingOptionId: String?) {
        self.requestId = requestId
        self.agentId = agentId
        self.thinkingOptionId = thinkingOptionId
    }
}

public struct GetProvidersSnapshotRequest: Encodable, Sendable {
    public let type = "get_providers_snapshot_request"
    public let requestId: String
    public var cwd: String?
    public init(requestId: String, cwd: String? = nil) {
        self.requestId = requestId
        self.cwd = cwd
    }
}

public struct FetchAgentsRequest: Encodable, Sendable {
    public let type = "fetch_agents_request"
    public let requestId: String
    public var filter: AgentFilter?
    public var sort: [AgentSort]?
    public var page: AgentPage?
    public var subscribe: AgentSubscribe?

    public init(requestId: String, filter: AgentFilter? = nil, sort: [AgentSort]? = nil, page: AgentPage? = nil, subscribe: AgentSubscribe? = nil) {
        self.requestId = requestId
        self.filter = filter
        self.sort = sort
        self.page = page
        self.subscribe = subscribe
    }

    public struct AgentFilter: Encodable, Sendable {
        public var includeArchived: Bool?
        public var statuses: [String]?
        public var requiresAttention: Bool?
        public init(includeArchived: Bool? = nil, statuses: [String]? = nil, requiresAttention: Bool? = nil) {
            self.includeArchived = includeArchived
            self.statuses = statuses
            self.requiresAttention = requiresAttention
        }
    }
    public struct AgentSort: Encodable, Sendable {
        public let key: String
        public let direction: String
        public init(key: String, direction: String) {
            self.key = key
            self.direction = direction
        }
    }
    public struct AgentPage: Encodable, Sendable {
        public let limit: Int
        public var cursor: String?
        public init(limit: Int, cursor: String? = nil) {
            self.limit = limit
            self.cursor = cursor
        }
    }
    public struct AgentSubscribe: Encodable, Sendable {
        public var subscriptionId: String?
        public init(subscriptionId: String? = nil) {
            self.subscriptionId = subscriptionId
        }
    }
}

public struct FetchAgentTimelineRequest: Encodable, Sendable {
    public let type = "fetch_agent_timeline_request"
    public let requestId: String
    public let agentId: String
    /// "tail" (default, most recent), "before", or "after".
    public var direction: String?
    public var cursor: AgentTimelineCursor?
    /// 0 = all. Omit to let the daemon pick a default.
    public var limit: Int?
    /// "projected" (recommended for UI) or "canonical" (raw event log).
    public var projection: String?

    public init(requestId: String, agentId: String, direction: String? = nil, cursor: AgentTimelineCursor? = nil, limit: Int? = nil, projection: String? = nil) {
        self.requestId = requestId
        self.agentId = agentId
        self.direction = direction
        self.cursor = cursor
        self.limit = limit
        self.projection = projection
    }
}

public struct AgentTimelineCursor: Codable, Hashable, Sendable {
    public let epoch: String
    public let seq: Int
    public init(epoch: String, seq: Int) {
        self.epoch = epoch
        self.seq = seq
    }
}

public struct SendAgentMessageRequest: Encodable, Sendable {
    public let type = "send_agent_message_request"
    public let requestId: String
    public let agentId: String
    public let text: String
    public var messageId: String?
    public var images: [ImageAttachment]?
    public var attachments: [AgentAttachment]?

    public init(requestId: String, agentId: String, text: String, messageId: String? = nil, images: [ImageAttachment]? = nil, attachments: [AgentAttachment]? = nil) {
        self.requestId = requestId
        self.agentId = agentId
        self.text = text
        self.messageId = messageId
        self.images = images
        self.attachments = attachments
    }

    public struct ImageAttachment: Encodable, Sendable {
        public let data: String      // base64
        public let mimeType: String
        public init(data: String, mimeType: String) {
            self.data = data
            self.mimeType = mimeType
        }
    }

    /// Upstream `AgentAttachmentsSchema` is a flexible union (GitHub PR/issue etc.).
    /// We keep a minimal shape for MVP and extend as needed.
    public struct AgentAttachment: Encodable, Sendable {
        public let kind: String
        public let name: String?
        public let mimeType: String?
        public let data: String?
        public let url: String?
        public init(kind: String, name: String? = nil, mimeType: String? = nil, data: String? = nil, url: String? = nil) {
            self.kind = kind
            self.name = name
            self.mimeType = mimeType
            self.data = data
            self.url = url
        }
    }
}

public enum WSOutbound: Encodable, Sendable {
    case hello(HelloMessage)
    case pong(PongMessage)
    case ping(PingMessage)
    case session(SessionRequest)

    private enum Keys: String, CodingKey { case type, message }

    public func encode(to encoder: Encoder) throws {
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
public enum SessionInbound: Decodable, @unchecked Sendable {
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
    case unknown(type: String, raw: Data)

    private enum Keys: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
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

public enum WSInbound: Decodable {
    case ping
    case pong
    case session(SessionInbound)
    case unknown(type: String, raw: Data)

    private enum Keys: String, CodingKey { case type, message }

    public init(from decoder: Decoder) throws {
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

public struct ServerInfoPayload: Decodable, Sendable {
    public let type: String
    public let status: String
    public let serverId: String?
    public let hostname: String?
    public let version: String?
}

/// `{type:"status", payload:{status:"server_info", ...}}` wrapper.
public struct StatusPayload: Decodable, Sendable {
    public let type: String
    public let payload: Inner
    public struct Inner: Decodable, Sendable {
        public let status: String
        public let serverId: String?
        public let hostname: String?
        public let version: String?
        public let agentId: String?    // present when status == "agent_created"
        public let requestId: String?  // present when status == "agent_created"
    }
}

public struct FetchAgentsResponse: Decodable, Sendable {
    public let type: String
    public let payload: Payload
    public struct Payload: Decodable, Sendable {
        public let requestId: String
        public let entries: [Entry]
        public let pageInfo: PageInfo?
        public struct Entry: Decodable, Sendable { public let agent: AgentSnapshot }
        public struct PageInfo: Decodable, Sendable {
            public let nextCursor: String?
            public let prevCursor: String?
            public let hasMore: Bool?
        }
        public var agents: [AgentSnapshot] { entries.map(\.agent) }
    }
}

public struct SendAgentMessageResponse: Decodable, Sendable {
    public let type: String
    public let payload: Payload
    public struct Payload: Decodable, Sendable {
        public let requestId: String
        public let agentId: String?
        public let accepted: Bool?
        public let error: String?
    }
}

public struct AckResponsePayload: Decodable, Sendable {
    public let requestId: String
    public let agentId: String?
    public let accepted: Bool?
    public let error: String?
}

public struct SetAgentModeResponse: Decodable, Sendable {
    public let type: String
    public let payload: AckResponsePayload
}

public struct SetAgentModelResponse: Decodable, Sendable {
    public let type: String
    public let payload: AckResponsePayload
}

public struct SetAgentThinkingResponse: Decodable, Sendable {
    public let type: String
    public let payload: AckResponsePayload
}

/// Lazily pushed status updates for a single agent. Handy for keeping the
/// sidebar's little status dot in sync without a full `fetch_agents`.
public struct AgentStatusMessage: Decodable, Sendable {
    public let type: String     // "agent_status"
    public let payload: Payload
    public struct Payload: Decodable, Sendable {
        public let agentId: String
        public let status: String
        public let info: AgentSnapshot?
    }
}

public struct CancelAgentResponse: Decodable, Sendable {
    public let type: String
    public let payload: Payload
    public struct Payload: Decodable, Sendable {
        public let requestId: String
        public let agentId: String
    }
}

public struct GetProvidersSnapshotResponse: Decodable, Sendable {
    public let type: String    // "get_providers_snapshot_response"
    public let payload: Payload
    public struct Payload: Decodable, Sendable {
        public let entries: [ProviderSnapshot]
        public let generatedAt: String
        public let requestId: String
    }
}

public struct ProvidersSnapshotUpdatePayload: Decodable, Sendable {
    public let type: String
    public let payload: Payload
    public struct Payload: Decodable, Sendable {
        public let entries: [ProviderSnapshot]
        public let generatedAt: String?
        public let cwd: String?
    }
}

/// One provider's model + mode catalog, as returned by
/// `get_providers_snapshot_response`. Fields we don't consume are dropped.
public struct ProviderSnapshot: Decodable, Sendable, Hashable, Identifiable {
    public let provider: String              // "claude" | "codex" | ...
    public let status: String                // "ready" | "loading" | "error" | "unavailable"
    public let error: String?
    public let models: [ModelDefinition]?
    public let modes: [AgentMode]?
    public let label: String?
    public let defaultModeId: String?

    public var id: String { provider }
}

public struct ModelDefinition: Decodable, Sendable, Hashable, Identifiable {
    public let provider: String
    public let id: String
    public let label: String
    public let description: String?
    public let isDefault: Bool?
    public let thinkingOptions: [SelectOption]?
    public let defaultThinkingOptionId: String?
}

public struct AgentMode: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let description: String?
    public let icon: String?
    public let colorTier: String?
}

public struct SelectOption: Decodable, Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let description: String?
    public let isDefault: Bool?
}

// MARK: - Timeline

/// One item in the agent timeline. We decode the text-bearing shapes and keep
/// everything else as `.other` (with the raw type name) so future additions
/// don't break the client.
public enum TimelineItem: Decodable, Hashable, Sendable {
    case userMessage(text: String, messageId: String?)
    case assistantMessage(text: String)
    case reasoning(text: String)
    case toolCall(name: String, status: String, callId: String, detail: ToolDetail)
    case todo(items: [TodoItem])
    case error(message: String)
    case other(type: String)

    public struct TodoItem: Decodable, Hashable, Sendable {
        public let text: String
        public let completed: Bool
    }

    private enum Keys: String, CodingKey { case type, text, messageId, name, status, callId, id, detail, items, message }

    public init(from decoder: Decoder) throws {
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
            self = .error(message: (try? c.decode(String.self, forKey: .message)) ?? "")
        default:
            self = .other(type: type)
        }
    }

    public var displayKind: String {
        switch self {
        case .userMessage: "user"
        case .assistantMessage: "assistant"
        case .reasoning: "reasoning"
        case .toolCall: "tool"
        case .todo: "todo"
        case .error: "error"
        case .other(let t): t
        }
    }

    public var displayText: String {
        switch self {
        case .userMessage(let t, _): return t
        case .assistantMessage(let t): return t
        case .reasoning(let t): return t
        case .toolCall(let name, let status, _, _): return "\(name) · \(status)"
        case .todo(let items):
            return items.map { ($0.completed ? "[x] " : "[ ] ") + $0.text }.joined(separator: "\n")
        case .error(let m):
            if m.contains("[object Object]") {
                return "Backend internal error (Quota limit or API failure)"
            }
            return m
        case .other(let t): return "[\(t)]"
        }
    }
}

/// Decoded detail payload for a `tool_call` timeline item. Mirrors
/// `ToolCallDetailPayloadSchema` in upstream messages.ts, trimmed to the
/// fields we actually render. Anything we don't explicitly model falls
/// through as `.other(type:)`.
public enum ToolDetail: Decodable, Hashable, Sendable {
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

    public struct WebResult: Decodable, Hashable, Sendable {
        public let title: String
        public let url: String
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

    public init(from decoder: Decoder) throws {
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

public struct TimelineEntry: Decodable, Hashable, Sendable, Identifiable {
    public let item: TimelineItem
    public let timestamp: String
    public let seqStart: Int
    public let seqEnd: Int

    /// Stable identity based on the canonical seq range so SwiftUI lists
    /// don't re-create rows on incremental stream updates.
    public var id: String { "\(seqStart)-\(seqEnd)" }
}

public struct FetchAgentTimelineResponse: Decodable, Sendable {
    public let type: String
    public let payload: Payload
    public struct Payload: Decodable, Sendable {
        public let requestId: String
        public let agentId: String
        public let epoch: String
        public let entries: [TimelineEntry]
        public let hasOlder: Bool
        public let hasNewer: Bool
        public let startCursor: AgentTimelineCursor?
        public let endCursor: AgentTimelineCursor?
        public let error: String?
    }
}

// MARK: - Agent stream events

public struct AgentStreamMessage: Decodable, Sendable {
    public let type: String   // "agent_stream"
    public let payload: Payload

    public struct Payload: Decodable, Sendable {
        public let agentId: String
        public let timestamp: String
        public let seq: Int?
        public let epoch: String?
        public let event: AgentStreamEvent
    }
}

public enum AgentStreamEvent: Decodable, Sendable {
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

    public init(from decoder: Decoder) throws {
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

public struct FetchWorkspacesRequest: Encodable, Sendable {
    public let type = "fetch_workspaces_request"
    public let requestId: String
    public init(requestId: String) {
        self.requestId = requestId
    }
}

public struct WorkspaceGitRuntime: Decodable, Sendable {
    public let currentBranch: String?
    public let remoteUrl: String?
}

public struct WorkspaceDescriptor: Decodable, Sendable {
    public let id: String
    public let workspaceDirectory: String?
    public let projectRootPath: String
    public let gitRuntime: WorkspaceGitRuntime?
}

public struct FetchWorkspacesResponse: Decodable, Sendable {
    public let type: String
    public let payload: Payload
    public struct Payload: Decodable, Sendable {
        public let requestId: String
        public let entries: [WorkspaceDescriptor]
    }
}

public struct AgentSnapshot: Decodable, Sendable, Identifiable, Hashable {
    public let id: String
    public let provider: String?
    public let cwd: String
    public let status: String
    public let title: String?
    public let createdAt: String
    public let updatedAt: String
    public let lastUserMessageAt: String?
    public let model: String?
    public let thinkingOptionId: String?
    public let effectiveThinkingOptionId: String?
    public let currentModeId: String?
    public let availableModes: [AgentMode]?
    public let lastUsage: AgentUsage?
    public let archivedAt: String?
    public let requiresAttention: Bool?
    public let attentionReason: String?

    public var displayName: String {
        if let t = title, !t.isEmpty { return t }
        return String(id.prefix(8))
    }
}

/// Rolling usage snapshot for an agent — tokens in/out, total cost, and
/// context-window occupancy. Mirrors `AgentUsageSchema` in upstream messages.ts.
public struct AgentUsage: Decodable, Sendable, Hashable {
    public let inputTokens: Int?
    public let cachedInputTokens: Int?
    public let outputTokens: Int?
    public let totalCostUsd: Double?
    public let contextWindowMaxTokens: Int?
    public let contextWindowUsedTokens: Int?
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

public enum RawJSON: Codable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RawJSON])
    case object([String: RawJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Double.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([RawJSON].self) { self = .array(v); return }
        if let v = try? c.decode([String: RawJSON].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON token")
    }

    public func encode(to encoder: Encoder) throws {
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
