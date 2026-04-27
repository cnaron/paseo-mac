import Foundation

/// Relay pairing offer (v2) as emitted by `paseo-server`'s `connection-offer.ts`.
///
/// Wire shape (JSON, then base64url in the URL fragment):
/// ```json
/// { "v": 2, "serverId": "srv_xxx", "daemonPublicKeyB64": "...",
///   "relay": { "endpoint": "relay.example.com:443" } }
/// ```
struct ConnectionOffer: Sendable, Hashable {
    let serverId: String
    let daemonPublicKeyB64: String
    let relayEndpoint: String   // e.g. "relay.example.com:443"

    /// Parses `https://app.paseo.sh/#offer=<base64>`, a `paseo://` link, or the raw
    /// base64 payload. Also accepts plain JSON for testing.
    static func parse(_ raw: String) throws -> ConnectionOffer {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) Try as URL with `offer=<b64>` in fragment or query.
        if let url = URL(string: trimmed), let offerParam = extractOfferParam(from: url) {
            return try fromBase64Json(offerParam)
        }

        // 2) Raw base64 of the JSON.
        if let decoded = decodeBase64(trimmed),
           let json = String(data: decoded, encoding: .utf8),
           json.contains("serverId") {
            return try fromJson(json)
        }

        // 3) Plain JSON.
        if trimmed.hasPrefix("{") {
            return try fromJson(trimmed)
        }

        throw ConnectionOfferError.unrecognizedInput
    }

    private static func extractOfferParam(from url: URL) -> String? {
        if let fragment = url.fragment, let v = queryValue(from: fragment, key: "offer") {
            return v
        }
        if let q = url.query, let v = queryValue(from: q, key: "offer") {
            return v
        }
        return nil
    }

    private static func queryValue(from query: String, key: String) -> String? {
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, parts[0] == Substring(key) else { continue }
            return String(parts[1]).removingPercentEncoding ?? String(parts[1])
        }
        return nil
    }

    private static func fromBase64Json(_ base64: String) throws -> ConnectionOffer {
        guard let data = decodeBase64(base64) else {
            throw ConnectionOfferError.invalidBase64
        }
        guard let json = String(data: data, encoding: .utf8) else {
            throw ConnectionOfferError.invalidBase64
        }
        return try fromJson(json)
    }

    private static func fromJson(_ json: String) throws -> ConnectionOffer {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        let wire = try decoder.decode(Wire.self, from: data)
        guard wire.v == 2 else { throw ConnectionOfferError.unsupportedVersion(wire.v) }
        return ConnectionOffer(
            serverId: wire.serverId,
            daemonPublicKeyB64: wire.daemonPublicKeyB64,
            relayEndpoint: wire.relay.endpoint
        )
    }

    private static func decodeBase64(_ s: String) -> Data? {
        // Try standard base64 and base64url, with / without padding.
        let normalized = s
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded: String = {
            let rem = normalized.count % 4
            return rem == 0 ? normalized : normalized + String(repeating: "=", count: 4 - rem)
        }()
        return Data(base64Encoded: padded)
    }

    private struct Wire: Decodable {
        let v: Int
        let serverId: String
        let daemonPublicKeyB64: String
        let relay: Relay
        struct Relay: Decodable { let endpoint: String }
    }
}

enum ConnectionOfferError: Error, LocalizedError {
    case unrecognizedInput
    case invalidBase64
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .unrecognizedInput: "Could not parse offer (expected paseo://..., https://app.paseo.sh/#offer=..., base64, or JSON)"
        case .invalidBase64: "Offer is not valid base64"
        case .unsupportedVersion(let v): "Unsupported offer version \(v) (expected 2)"
        }
    }
}

extension ConnectionOffer {
    /// Relay WS URL that the mobile/desktop client should connect to.
    /// Matches `buildRelayWebSocketUrl` in packages/server's daemon-endpoints.ts.
    func relayWebSocketURL() throws -> URL {
        let (host, port, isIPv6) = try parseHostPort(relayEndpoint)
        let scheme = port == 443 ? "wss" : "ws"
        let hostPart = isIPv6 ? "[\(host)]" : host
        guard var comps = URLComponents(string: "\(scheme)://\(hostPart):\(port)/ws") else {
            throw ConnectionOfferError.unrecognizedInput
        }
        comps.queryItems = [
            URLQueryItem(name: "serverId", value: serverId),
            URLQueryItem(name: "role", value: "client"),
            URLQueryItem(name: "v", value: "2")
        ]
        guard let url = comps.url else { throw ConnectionOfferError.unrecognizedInput }
        return url
    }

    private func parseHostPort(_ endpoint: String) throws -> (host: String, port: Int, isIPv6: Bool) {
        // Handles: host:port, [ipv6]:port, bare ipv6 (no port), host-only (default 443)
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
            guard let close = trimmed.firstIndex(of: "]") else { throw ConnectionOfferError.unrecognizedInput }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let afterBracket = trimmed.index(after: close)
            let port: Int
            if afterBracket < trimmed.endIndex, trimmed[afterBracket] == ":" {
                port = Int(trimmed[trimmed.index(after: afterBracket)...]) ?? 443
            } else {
                port = 443
            }
            return (host, port, true)
        }
        if let colon = trimmed.lastIndex(of: ":"), trimmed.filter({ $0 == ":" }).count == 1 {
            let host = String(trimmed[..<colon])
            let port = Int(trimmed[trimmed.index(after: colon)...]) ?? 443
            return (host, port, false)
        }
        return (trimmed, 443, trimmed.contains(":"))
    }
}
