import Foundation

/// Window payload used by `openWindow(value:)` to spawn a workspace file
/// preview window focused on one file (optionally with a line hint).
struct WorkspaceFilePreviewRoute: Hashable, Codable {
    let nonce: UUID
    let cwd: String
    let path: String?
    let lineStart: Int?
    let lineEnd: Int?

    init(
        cwd: String,
        path: String? = nil,
        lineStart: Int? = nil,
        lineEnd: Int? = nil,
        nonce: UUID = UUID()
    ) {
        self.cwd = cwd
        self.path = path
        self.lineStart = lineStart
        self.lineEnd = lineEnd
        self.nonce = nonce
    }
}

/// Shared helpers for turning file references in assistant output into
/// internal deep links and workspace-scoped preview routes.
enum WorkspaceFilePreviewRouting {
    static let linkScheme = "paseofile"
    private static let linkHost = "open"

    static func makeLinkURL(rawLocation: String) -> URL? {
        var comps = URLComponents()
        comps.scheme = linkScheme
        comps.host = linkHost
        comps.queryItems = [URLQueryItem(name: "target", value: rawLocation)]
        return comps.url
    }

    static func parseRawLocation(from url: URL) -> String? {
        guard url.scheme?.lowercased() == linkScheme else { return nil }
        guard url.host?.lowercased() == linkHost else { return nil }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        return comps?.queryItems?.first(where: { $0.name == "target" })?.value
    }

    static func route(cwd: String, rawLocation: String) -> WorkspaceFilePreviewRoute? {
        let parsed = parseLocation(rawLocation)
        return route(cwd: cwd, path: parsed.path, lineStart: parsed.lineStart, lineEnd: parsed.lineEnd)
    }

    /// Best-effort route for in-window preview. Unlike `route(...)`, this
    /// never rejects paths outside workspace; callers can still show the
    /// preview pane and surface a read error instead of falling back to
    /// external app opening.
    static func forceRoute(cwd: String, rawLocation: String) -> WorkspaceFilePreviewRoute {
        let parsed = parseLocation(rawLocation)
        if let strict = route(
            cwd: cwd,
            path: parsed.path,
            lineStart: parsed.lineStart,
            lineEnd: parsed.lineEnd
        ) {
            return strict
        }
        let trimmed = parsed.path.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackPath = trimmed.isEmpty ? "." : trimmed
        return WorkspaceFilePreviewRoute(
            cwd: cwd,
            path: fallbackPath,
            lineStart: parsed.lineStart,
            lineEnd: parsed.lineEnd
        )
    }

    static func route(cwd: String, path: String, lineStart: Int?, lineEnd: Int?) -> WorkspaceFilePreviewRoute? {
        guard let relative = normalizePathForWorkspace(path, cwd: cwd) else { return nil }
        return WorkspaceFilePreviewRoute(
            cwd: cwd,
            path: relative,
            lineStart: lineStart,
            lineEnd: lineEnd
        )
    }

    /// Convert an absolute/relative candidate to workspace-relative path.
    /// Returns nil when the path is outside workspace root.
    ///
    /// Uses pure string operations (no filesystem calls) so VPS paths that
    /// don't exist locally are handled correctly regardless of how macOS
    /// resolves symlinks like /home on the client machine.
    static func normalizePathForWorkspace(_ rawPath: String, cwd: String) -> String? {
        let expandedCwd = NSString(string: cwd).expandingTildeInPath

        var candidate = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("file://") {
            candidate = String(candidate.dropFirst("file://".count))
        }
        guard !candidate.isEmpty else { return "." }

        let expandedCandidate = NSString(string: candidate).expandingTildeInPath
        if expandedCandidate.hasPrefix("/") {
            if expandedCandidate == expandedCwd { return "." }
            let prefix = expandedCwd.hasSuffix("/") ? expandedCwd : expandedCwd + "/"
            guard expandedCandidate.hasPrefix(prefix) else { return nil }
            let rel = String(expandedCandidate.dropFirst(prefix.count))
            return rel.isEmpty ? "." : rel
        }

        let cleaned = expandedCandidate.hasPrefix("./")
            ? String(expandedCandidate.dropFirst(2))
            : expandedCandidate
        return cleaned.isEmpty ? "." : cleaned
    }

    static func parseLocation(_ raw: String) -> (path: String, lineStart: Int?, lineEnd: Int?) {
        var stripped = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.hasPrefix("file://") {
            stripped = String(stripped.dropFirst("file://".count))
        }

        if let hash = stripped.range(of: "#L", options: [.caseInsensitive, .backwards]) {
            let pathPart = String(stripped[..<hash.lowerBound])
            let suffix = String(stripped[hash.upperBound...])
            if let dash = suffix.firstIndex(of: "-") {
                let startRaw = String(suffix[..<dash]).replacingOccurrences(of: "L", with: "", options: .caseInsensitive)
                let endRaw = String(suffix[suffix.index(after: dash)...]).replacingOccurrences(of: "L", with: "", options: .caseInsensitive)
                if let start = Int(startRaw), let end = Int(endRaw) {
                    return (path: pathPart, lineStart: start, lineEnd: max(start, end))
                }
            } else if let line = Int(suffix.replacingOccurrences(of: "C\\d+$", with: "", options: .regularExpression)) {
                return (path: pathPart, lineStart: line, lineEnd: nil)
            }
        }

        let parts = stripped.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        if parts.count >= 3,
           let col = Int(parts[parts.count - 1]), col >= 0,
           let line = Int(parts[parts.count - 2]), line > 0 {
            let path = parts.dropLast(2).joined(separator: ":")
            return (path: path, lineStart: line, lineEnd: nil)
        }

        guard let colon = stripped.lastIndex(of: ":"), colon > stripped.startIndex else {
            return (path: stripped, lineStart: nil, lineEnd: nil)
        }
        let suffix = stripped[stripped.index(after: colon)...]
        if let dash = suffix.firstIndex(of: "-"),
           let start = Int(suffix[..<dash]),
           let end = Int(suffix[suffix.index(after: dash)...]) {
            return (path: String(stripped[..<colon]), lineStart: start, lineEnd: max(start, end))
        }
        if let line = Int(suffix), line > 0 {
            return (path: String(stripped[..<colon]), lineStart: line, lineEnd: nil)
        }
        return (path: stripped, lineStart: nil, lineEnd: nil)
    }
}
