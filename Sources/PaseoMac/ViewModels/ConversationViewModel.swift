import Foundation
import Observation

/// Per-agent conversation state: renders a scrollable list of message rows,
/// streams new items from `agent_stream` events, and sends outbound messages.
///
/// Streaming model: when `turn_started` arrives we flip `isAgentWorking` on and
/// clear the "completed" flag; each subsequent `timeline` event carries one
/// full `TimelineItem` which we append as its own row. `turn_completed` /
/// `turn_failed` / `turn_canceled` flip us back to idle. No delta merging
/// needed — the daemon hands us finalized rows.
@MainActor
@Observable
final class ConversationViewModel {

    struct Row: Identifiable, Hashable {
        let id: String
        let kind: String          // "user", "assistant", "reasoning", "tool", "todo", "error", "other"
        let text: String
        let timestamp: String?
        /// Populated only when `kind == "tool"`. Carries the structured name,
        /// target, status, and an optional long-form detail that the tool row
        /// in the UI can expand on click.
        let tool: ToolInfo?

        init(id: String, kind: String, text: String, timestamp: String?, tool: ToolInfo? = nil) {
            self.id = id
            self.kind = kind
            self.text = text
            self.timestamp = timestamp
            self.tool = tool
        }
    }

    /// Shape of a tool's expanded detail. Drives the picker in ToolRow so
    /// each tool type can use the most readable rendering: plain monospace,
    /// colored +/- unified-diff lines, or a before/after split for edits.
    enum DetailKind: Hashable {
        case none
        case plain(text: String, monospaced: Bool)
        case beforeAfter(before: String, after: String)
        case unifiedDiff(text: String)
    }

    /// UI-facing tool summary built from `ToolDetail`. Keeps presentation logic
    /// (icon pick, target formatting, detail body) in one place.
    struct ToolInfo: Hashable {
        let name: String             // "Edit", "Bash", "WebSearch", ...
        let target: String?          // file path, command, query — one-line summary
        let status: String           // "running" | "completed" | "failed" | "canceled"
        let iconName: String         // SF Symbol
        let detailKind: DetailKind

        /// Plain single-string version of the detail for tools that need it
        /// (e.g. to drop into a truncated preview). Returns "" for .none.
        var detailPlain: String {
            switch detailKind {
            case .none: return ""
            case .plain(let t, _): return t
            case .beforeAfter(let b, let a): return "── before ──\n\(b)\n\n── after ──\n\(a)"
            case .unifiedDiff(let t): return t
            }
        }

        var hasDetail: Bool {
            switch detailKind {
            case .none: return false
            case .plain(let t, _): return !t.isEmpty
            case .beforeAfter(let b, let a): return !b.isEmpty || !a.isEmpty
            case .unifiedDiff(let t): return !t.isEmpty
            }
        }

        static func from(name: String, status: String, detail: ToolDetail) -> ToolInfo {
            switch detail {
            case .shell(let cmd, _, let output, let exit):
                let target = cmd.split(separator: "\n").first.map(String.init) ?? cmd
                var body = output ?? ""
                if let exit = exit { body = "exit \(exit)\n\n" + body }
                return ToolInfo(
                    name: displayName(rawName: name, fallback: "Shell"),
                    target: target,
                    status: status, iconName: "terminal",
                    detailKind: body.isEmpty ? .none : .plain(text: body, monospaced: true)
                )
            case .read(let path, let content, let offset, let limit):
                var hint = ""
                if let o = offset, let l = limit { hint = "  (lines \(o)-\(o + l))" }
                return ToolInfo(
                    name: displayName(rawName: name, fallback: "Read"),
                    target: path + hint,
                    status: status, iconName: "doc.text",
                    detailKind: content.flatMap { $0.isEmpty ? nil : .plain(text: $0, monospaced: true) } ?? .none
                )
            case .edit(let path, let diff, let oldStr, let newStr):
                // Prefer the semantic before/after split (cleaner reading);
                // fall back to the raw unified diff when that's all we have.
                let kind: DetailKind
                if let o = oldStr, let n = newStr, !(o.isEmpty && n.isEmpty) {
                    kind = .beforeAfter(before: o, after: n)
                } else if let d = diff, !d.isEmpty {
                    kind = .unifiedDiff(text: d)
                } else {
                    kind = .none
                }
                return ToolInfo(
                    name: displayName(rawName: name, fallback: "Edit"),
                    target: path,
                    status: status, iconName: "pencil",
                    detailKind: kind
                )
            case .write(let path, let content):
                return ToolInfo(
                    name: displayName(rawName: name, fallback: "Write"),
                    target: path,
                    status: status, iconName: "square.and.pencil",
                    detailKind: content.flatMap { $0.isEmpty ? nil : .plain(text: $0, monospaced: true) } ?? .none
                )
            case .search(let query, let toolName, let filePaths, let webResults, let numMatches, let content):
                var lines: [String] = []
                if let files = filePaths, !files.isEmpty {
                    lines.append(contentsOf: files)
                }
                if let web = webResults, !web.isEmpty {
                    for r in web { lines.append("• \(r.title)\n  \(r.url)") }
                }
                if let c = content, !c.isEmpty {
                    lines.append(c)
                }
                let hits: String? = numMatches.map { "(\($0) match\( $0 == 1 ? "" : "es"))" }
                let target = [query, hits].compactMap { $0 }.joined(separator: " ")
                let body = lines.joined(separator: "\n")
                return ToolInfo(
                    name: displayName(rawName: toolName ?? name, fallback: "Search"),
                    target: target,
                    status: status, iconName: "magnifyingglass",
                    detailKind: body.isEmpty ? .none : .plain(text: body, monospaced: false)
                )
            case .fetch(let url, let prompt, let result, let code):
                var header = ""
                if let c = code { header = "HTTP \(c)\n\n" }
                if let p = prompt, !p.isEmpty { header += "prompt: \(p)\n\n" }
                let body = header + (result ?? "")
                return ToolInfo(
                    name: displayName(rawName: name, fallback: "Fetch"),
                    target: url,
                    status: status, iconName: "arrow.down.circle",
                    detailKind: body.isEmpty ? .none : .plain(text: body, monospaced: false)
                )
            case .subAgent(let subType, let description, let log):
                let target = [subType, description].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
                return ToolInfo(
                    name: displayName(rawName: name, fallback: "SubAgent"),
                    target: target.isEmpty ? nil : target,
                    status: status, iconName: "person.2",
                    detailKind: log.isEmpty ? .none : .plain(text: log, monospaced: true)
                )
            case .plainText(let label, let text, let icon):
                return ToolInfo(
                    name: displayName(rawName: label ?? name, fallback: name.isEmpty ? "Tool" : name),
                    target: nil,
                    status: status,
                    iconName: icon ?? "hammer",
                    detailKind: text.flatMap { $0.isEmpty ? nil : .plain(text: $0, monospaced: false) } ?? .none
                )
            case .plan(let text):
                return ToolInfo(
                    name: "Plan",
                    target: text.split(separator: "\n").first.map(String.init),
                    status: status, iconName: "list.bullet.rectangle",
                    detailKind: text.isEmpty ? .none : .plain(text: text, monospaced: false)
                )
            case .other:
                return ToolInfo(
                    name: name.isEmpty ? "tool" : name,
                    target: nil,
                    status: status, iconName: "hammer",
                    detailKind: .none
                )
            }
        }

        /// Upstream tool names like "Bash" / "WebSearch" / "Edit" are already
        /// capitalized; we keep them verbatim. Fallback is used when the raw
        /// name is empty.
        private static func displayName(rawName: String, fallback: String) -> String {
            rawName.isEmpty ? fallback : rawName
        }
    }

    let agentId: String

    var rows: [Row] = []
    var isLoading: Bool = false
    var isAgentWorking: Bool = false
    var lastError: String? = nil
    var composerText: String = ""
    var pendingImages: [PendingImageAttachment] = []
    var pendingTextFiles: [PendingTextFile] = []

    private let getClient: () -> DaemonClient?
    private var streamRowCounter: Int = 0

    init(agentId: String, getClient: @escaping () -> DaemonClient?) {
        self.agentId = agentId
        self.getClient = getClient
    }

    // MARK: - Loading

    func loadInitial() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let client = getClient() else { return }
            let payload = try await client.fetchTimeline(agentId: agentId)
            self.rows = payload.entries.map(rowFromEntry)
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    // MARK: - Send

    func sendComposer() async {
        let baseText = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        let textFiles = pendingTextFiles

        guard !baseText.isEmpty || !images.isEmpty || !textFiles.isEmpty else { return }
        guard let client = getClient() else {
            self.lastError = "Not connected"
            return
        }
        composerText = ""
        pendingImages = []
        pendingTextFiles = []

        // Inline attached text files as markdown-fenced blocks at the top of
        // the message body. The daemon protocol has no first-class file
        // attachment slot, but this matches how Claude Code renders a pasted
        // file and keeps the content searchable in the conversation timeline.
        let finalText = composeOutgoingText(baseText: baseText, files: textFiles)

        let messageId = UUID().uuidString
        let optimisticText = finalText.isEmpty
            ? "[\(images.count) image\(images.count == 1 ? "" : "s")]"
            : finalText
        appendLocalUserRow(text: optimisticText, messageId: messageId)

        do {
            let wireImages = images.map {
                SendAgentMessageRequest.ImageAttachment(
                    data: $0.pngData.base64EncodedString(),
                    mimeType: $0.mimeType
                )
            }
            _ = try await client.sendMessage(
                agentId: agentId,
                text: finalText,
                messageId: messageId,
                images: wireImages.isEmpty ? nil : wireImages
            )
            self.lastError = nil
        } catch {
            self.lastError = "Send failed: \(error.localizedDescription)"
        }
    }

    private func composeOutgoingText(baseText: String, files: [PendingTextFile]) -> String {
        guard !files.isEmpty else { return baseText }
        var pieces: [String] = []
        for f in files {
            let lang = f.languageHint ?? ""
            pieces.append("**\(f.name)**\n```\(lang)\n\(f.content)\n```")
        }
        if !baseText.isEmpty { pieces.append(baseText) }
        return pieces.joined(separator: "\n\n")
    }

    // MARK: - Pending attachments

    func addImages(_ images: [PendingImageAttachment]) {
        pendingImages.append(contentsOf: images)
    }

    func removeImage(id: UUID) {
        pendingImages.removeAll { $0.id == id }
    }

    func addTextFile(_ file: PendingTextFile) {
        pendingTextFiles.append(file)
    }

    func removeTextFile(id: UUID) {
        pendingTextFiles.removeAll { $0.id == id }
    }

    // MARK: - Stream ingestion

    func apply(streamEvent: AgentStreamEvent, seq: Int?, timestamp: String) {
        switch streamEvent {
        case .turnStarted:
            isAgentWorking = true
        case .turnCompleted, .turnFailed, .turnCanceled:
            isAgentWorking = false
        case .threadStarted:
            break
        case .timelineUpdated(let item):
            appendStreamedRow(item: item, seq: seq, timestamp: timestamp)
        case .permissionRequested:
            appendSystemRow(text: "[permission requested]", timestamp: timestamp)
        case .permissionResolved:
            break
        case .attentionRequired:
            break
        case .other:
            break
        }
    }

    // MARK: - Row helpers

    private func rowFromEntry(_ entry: TimelineEntry) -> Row {
        Row(
            id: rowIdForItem(entry.item, defaultId: "entry-\(entry.id)"),
            kind: entry.item.displayKind,
            text: entry.item.displayText,
            timestamp: entry.timestamp,
            tool: toolInfo(from: entry.item)
        )
    }

    /// Stable per-item id. Tool calls use `tool-<callId>` so the same
    /// invocation keeps identity across its running → completed lifecycle
    /// (otherwise a single Edit appears as 4-6 separate rows).
    private func rowIdForItem(_ item: TimelineItem, defaultId: String) -> String {
        if case let .toolCall(_, _, callId, _) = item, !callId.isEmpty {
            return "tool-\(callId)"
        }
        return defaultId
    }

    private func appendStreamedRow(item: TimelineItem, seq: Int?, timestamp: String) {
        // Dedup optimistic user bubble: when our just-sent message echoes back
        // with the messageId we chose, replace the local placeholder instead
        // of appending a new row (which would show duplicated text once the
        // merge logic coalesces both into one bubble).
        if case let .userMessage(text, msgId) = item, let msgId {
            let localId = "msg-\(msgId)"
            if let idx = rows.firstIndex(where: { $0.id == localId }) {
                rows[idx] = Row(
                    id: localId,
                    kind: "user",
                    text: text,
                    timestamp: timestamp,
                    tool: nil
                )
                return
            }
        }

        streamRowCounter += 1
        let defaultId = seq.map { "seq-\($0)" } ?? "stream-\(streamRowCounter)"
        let id = rowIdForItem(item, defaultId: defaultId)
        let row = Row(
            id: id,
            kind: item.displayKind,
            text: item.displayText,
            timestamp: timestamp,
            tool: toolInfo(from: item)
        )
        // Coalesce: if we already have a row with this id (a tool_call
        // transitioning running → completed, or an assistant chunk arriving
        // twice), replace in place rather than appending.
        if let idx = rows.firstIndex(where: { $0.id == id }) {
            rows[idx] = row
        } else {
            rows.append(row)
        }
    }

    private func toolInfo(from item: TimelineItem) -> ToolInfo? {
        if case let .toolCall(name, status, _, detail) = item {
            return ToolInfo.from(name: name, status: status, detail: detail)
        }
        return nil
    }

    private func appendLocalUserRow(text: String, messageId: String) {
        // Id is derived from the messageId we sent so appendStreamedRow can
        // find and replace this row when the daemon echoes it back.
        let id = "msg-\(messageId)"
        rows.append(Row(
            id: id,
            kind: "user",
            text: text,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            tool: nil
        ))
    }

    private func appendSystemRow(text: String, timestamp: String) {
        streamRowCounter += 1
        rows.append(Row(
            id: "sys-\(streamRowCounter)",
            kind: "system",
            text: text,
            timestamp: timestamp,
            tool: nil
        ))
    }
}
