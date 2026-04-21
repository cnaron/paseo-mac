import Foundation

// MARK: - WebSocket protocol constants

enum WSProtocol {
    static let version = 1
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

/// Session-level request wrapped in `{type:"session", message:<inner>}`.
enum SessionRequest: Encodable {
    case fetchAgents(FetchAgentsRequest)
    case fetchAgentTimeline(FetchAgentTimelineRequest)
    case sendAgentMessage(SendAgentMessageRequest)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .fetchAgents(let r): try c.encode(r)
        case .fetchAgentTimeline(let r): try c.encode(r)
        case .sendAgentMessage(let r): try c.encode(r)
        }
    }
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
    case session(SessionRequest)

    private enum Keys: String, CodingKey { case type, message }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .hello(let m): try m.encode(to: encoder)
        case .pong(let m): try m.encode(to: encoder)
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
    case session(SessionInbound)
    case unknown(type: String, raw: Data)

    private enum Keys: String, CodingKey { case type, message }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "ping":
            self = .ping
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

// MARK: - Timeline

/// One item in the agent timeline. We decode the text-bearing shapes and keep
/// everything else as `.other` (with the raw type name) so future additions
/// don't break the client.
enum TimelineItem: Decodable, Hashable, Sendable {
    case userMessage(text: String, messageId: String?)
    case assistantMessage(text: String)
    case reasoning(text: String)
    case toolCall(name: String, status: String, callId: String)
    case todo(items: [TodoItem])
    case error(message: String)
    case other(type: String)

    struct TodoItem: Decodable, Hashable, Sendable {
        let text: String
        let completed: Bool
    }

    private enum Keys: String, CodingKey { case type, text, messageId, name, status, callId, items, message }

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
            self = .toolCall(
                name: (try? c.decode(String.self, forKey: .name)) ?? "",
                status: (try? c.decode(String.self, forKey: .status)) ?? "",
                callId: (try? c.decode(String.self, forKey: .callId)) ?? ""
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

    var displayKind: String {
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

    var displayText: String {
        switch self {
        case .userMessage(let t, _): t
        case .assistantMessage(let t): t
        case .reasoning(let t): t
        case .toolCall(let name, let status, _): "\(name) · \(status)"
        case .todo(let items):
            items.map { ($0.completed ? "[x] " : "[ ] ") + $0.text }.joined(separator: "\n")
        case .error(let m): m
        case .other(let t): "[\(t)]"
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
    case permissionRequested(requestId: String?)
    case permissionResolved(requestId: String)
    case attentionRequired(reason: String)
    case other(type: String)

    private enum Keys: String, CodingKey {
        case type, sessionId, error, reason, item, request, requestId
    }
    private enum RequestKeys: String, CodingKey { case requestId }

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
            let inner = try? c.nestedContainer(keyedBy: RequestKeys.self, forKey: .request)
            self = .permissionRequested(requestId: try? inner?.decode(String.self, forKey: .requestId))
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

struct AgentSnapshot: Decodable, Sendable, Identifiable, Hashable {
    let id: String
    let cwd: String
    let status: String
    let title: String?
    let createdAt: String
    let updatedAt: String
    let lastUserMessageAt: String?
    let model: String?
    let archivedAt: String?
    let requiresAttention: Bool?
    let attentionReason: String?

    var displayName: String {
        if let t = title, !t.isEmpty { return t }
        return String(id.prefix(8))
    }
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
