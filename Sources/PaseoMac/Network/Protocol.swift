import Foundation

// MARK: - WebSocket protocol constants

enum WSProtocol {
    static let version = 1
}

// MARK: - Outbound (Mac → daemon)

/// First message a client sends after opening the WebSocket.
/// Daemon validates `protocolVersion` and non-empty `clientId`, then accepts the connection.
struct HelloMessage: Encodable {
    let type = "hello"
    let clientId: String
    let clientType: ClientType
    let protocolVersion: Int
    let appVersion: String?
    let capabilities: Capabilities?

    enum ClientType: String, Encodable {
        case mobile
        case browser
        case cli
        case mcp
    }

    struct Capabilities: Encodable {
        var voice: Bool?
        var pushNotifications: Bool?
    }
}

/// Sent in response to server's `ping`.
struct PongMessage: Encodable {
    let type = "pong"
}

/// Session-level request wrapped in the WS envelope `{type: "session", message: <inner>}`.
/// We send these after the hello handshake completes.
enum SessionRequest: Encodable {
    case fetchAgents(FetchAgentsRequest)
    case sendAgentMessage(SendAgentMessageRequest)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .fetchAgents(let req): try c.encode(req)
        case .sendAgentMessage(let req): try c.encode(req)
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
    struct AgentSort: Encodable {
        let key: String   // status_priority|created_at|updated_at|title
        let direction: String // asc|desc
    }
    struct AgentPage: Encodable {
        let limit: Int
        var cursor: String?
    }
    struct AgentSubscribe: Encodable {
        var subscriptionId: String?
    }
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
        let mimeType: String  // "image/png" etc.
    }

    struct AgentAttachment: Encodable {
        // Flexible shape in upstream — we keep it minimal for MVP.
        let kind: String       // "file" | "image"
        let name: String?
        let mimeType: String?
        let data: String?      // base64 for inline
        let url: String?       // for file references
    }
}

/// Top-level WS frame we send.
/// Hello/pong are plain top-level messages; session requests are wrapped.
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

/// Every session inbound has a `type` discriminator; we decode only the ones we care about
/// and pass the rest through as `.unknown` with the raw JSON preserved for debugging.
enum SessionInbound: Decodable {
    case serverInfo(ServerInfoPayload)
    case fetchAgentsResponse(FetchAgentsResponse)
    case sendAgentMessageResponse(SendAgentMessageResponse)
    case assistantChunk(AssistantChunk)
    case unknown(type: String, raw: Data)

    private enum Keys: String, CodingKey { case type }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)

        // For unknown types, grab the raw JSON for logging/debugging.
        let raw = try Self.reencode(decoder)

        switch type {
        case "server_info":
            let payload = try JSONDecoder.paseo.decode(ServerInfoPayload.self, from: raw)
            self = .serverInfo(payload)
        case "fetch_agents_response":
            let payload = try JSONDecoder.paseo.decode(FetchAgentsResponse.self, from: raw)
            self = .fetchAgentsResponse(payload)
        case "send_agent_message_response":
            let payload = try JSONDecoder.paseo.decode(SendAgentMessageResponse.self, from: raw)
            self = .sendAgentMessageResponse(payload)
        case "assistant_chunk":
            let payload = try JSONDecoder.paseo.decode(AssistantChunk.self, from: raw)
            self = .assistantChunk(payload)
        default:
            self = .unknown(type: type, raw: raw)
        }
    }

    /// Re-serialize the current decoder container so payload-specific decoders can run
    /// without needing to know the envelope.
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
            let inner = try c.decode(SessionInbound.self, forKey: .message)
            self = .session(inner)
        default:
            // Preserve raw bytes for forward-compat logging.
            let raw = try {
                let s = try decoder.singleValueContainer()
                let j = try s.decode(RawJSON.self)
                return try JSONEncoder.paseo.encode(j)
            }()
            self = .unknown(type: type, raw: raw)
        }
    }
}

// MARK: - Session payloads

struct ServerInfoPayload: Decodable {
    let type: String   // "server_info"
    let status: String // "server_info"
    let serverId: String?
    let hostname: String?
    let version: String?
}

struct FetchAgentsResponse: Decodable {
    let type: String   // "fetch_agents_response"
    let payload: Payload

    struct Payload: Decodable {
        let requestId: String
        let entries: [Entry]
        let pageInfo: PageInfo?

        /// Each entry wraps an agent snapshot alongside its project context; PaseoMac
        /// only needs the agent for the list view.
        struct Entry: Decodable {
            let agent: AgentSnapshot
        }

        struct PageInfo: Decodable {
            let nextCursor: String?
            let prevCursor: String?
            let hasMore: Bool?
        }

        /// Convenience accessor: flatten entries down to the list of agents.
        var agents: [AgentSnapshot] { entries.map(\.agent) }
    }
}

struct SendAgentMessageResponse: Decodable {
    let type: String   // "send_agent_message_response"
    let payload: Payload

    struct Payload: Decodable {
        let requestId: String
        let accepted: Bool?
        let error: String?
    }
}

struct AssistantChunk: Decodable {
    let type: String   // "assistant_chunk"
    let payload: Payload

    struct Payload: Decodable {
        let agentId: String?
        let messageId: String?
        let chunk: String
        let timestamp: String?
    }
}

// MARK: - Agent snapshot (subset; we decode only what the list view needs)

struct AgentSnapshot: Decodable, Identifiable, Hashable {
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

    /// Human-readable label for a row: prefer title, fall back to short id.
    var displayName: String {
        if let t = title, !t.isEmpty { return t }
        return String(id.prefix(8))
    }
}

// MARK: - Shared helpers

/// Paseo uses camelCase throughout; Swift Codable matches that by default.
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

/// A structural JSON value we can decode then re-encode, letting us "pass through" unknown
/// message payloads without defining full schemas up front.
enum RawJSON: Codable {
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
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Unsupported JSON token"
        )
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
