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

    /// UI-facing tool summary built from `ToolDetail`. Keeps presentation logic
    /// (icon pick, target formatting, detail body) in one place.
    struct ToolInfo: Hashable {
        let name: String             // "Edit", "Bash", "WebSearch", ...
        let target: String?          // file path, command, query — one-line summary
        let status: String           // "running" | "completed" | "failed" | "canceled"
        let iconName: String         // SF Symbol
        let detail: String?          // full body to show when the row is expanded
        let detailIsMonospaced: Bool

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
                    detail: body.isEmpty ? nil : body,
                    detailIsMonospaced: true
                )
            case .read(let path, let content, let offset, let limit):
                var hint = ""
                if let o = offset, let l = limit { hint = "  (lines \(o)-\(o + l))" }
                return ToolInfo(
                    name: displayName(rawName: name, fallback: "Read"),
                    target: path + hint,
                    status: status, iconName: "doc.text",
                    detail: content,
                    detailIsMonospaced: true
                )
            case .edit(let path, let diff, let oldStr, let newStr):
                let body: String? = {
                    if let d = diff, !d.isEmpty { return d }
                    if let o = oldStr, let n = newStr { return "--- before ---\n\(o)\n\n--- after ---\n\(n)" }
                    return nil
                }()
                return ToolInfo(
                    name: displayName(rawName: name, fallback: "Edit"),
                    target: path,
                    status: status, iconName: "pencil",
                    detail: body,
                    detailIsMonospaced: true
                )
            case .write(let path, let content):
                return ToolInfo(
                    name: displayName(rawName: name, fallback: "Write"),
                    target: path,
                    status: status, iconName: "square.and.pencil",
                    detail: content,
                    detailIsMonospaced: true
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
                return ToolInfo(
                    name: displayName(rawName: toolName ?? name, fallback: "Search"),
                    target: target,
                    status: status, iconName: "magnifyingglass",
                    detail: lines.isEmpty ? nil : lines.joined(separator: "\n"),
                    detailIsMonospaced: false
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
                    detail: body.isEmpty ? nil : body,
                    detailIsMonospaced: false
                )
            case .subAgent(let subType, let description, let log):
                let target = [subType, description].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
                return ToolInfo(
                    name: displayName(rawName: name, fallback: "SubAgent"),
                    target: target.isEmpty ? nil : target,
                    status: status, iconName: "person.2",
                    detail: log.isEmpty ? nil : log,
                    detailIsMonospaced: true
                )
            case .plainText(let label, let text, let icon):
                return ToolInfo(
                    name: displayName(rawName: label ?? name, fallback: name.isEmpty ? "Tool" : name),
                    target: nil,
                    status: status,
                    iconName: icon ?? "hammer",
                    detail: text,
                    detailIsMonospaced: false
                )
            case .plan(let text):
                return ToolInfo(
                    name: "Plan",
                    target: text.split(separator: "\n").first.map(String.init),
                    status: status, iconName: "list.bullet.rectangle",
                    detail: text,
                    detailIsMonospaced: false
                )
            case .other:
                return ToolInfo(
                    name: name.isEmpty ? "tool" : name,
                    target: nil,
                    status: status, iconName: "hammer",
                    detail: nil, detailIsMonospaced: false
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
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        guard !text.isEmpty || !images.isEmpty else { return }
        guard let client = getClient() else {
            self.lastError = "Not connected"
            return
        }
        composerText = ""
        pendingImages = []

        // Optimistically append a user bubble so the UI feels instant. The
        // real row will come back via agent_stream `timeline` events.
        let optimisticText = text.isEmpty
            ? "[\(images.count) image\(images.count == 1 ? "" : "s")]"
            : text
        appendLocalUserRow(text: optimisticText)

        do {
            let wireImages = images.map {
                SendAgentMessageRequest.ImageAttachment(
                    data: $0.pngData.base64EncodedString(),
                    mimeType: $0.mimeType
                )
            }
            _ = try await client.sendMessage(
                agentId: agentId,
                text: text,
                images: wireImages.isEmpty ? nil : wireImages
            )
            self.lastError = nil
        } catch {
            self.lastError = "Send failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Pending attachments

    func addImages(_ images: [PendingImageAttachment]) {
        pendingImages.append(contentsOf: images)
    }

    func removeImage(id: UUID) {
        pendingImages.removeAll { $0.id == id }
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
            id: "entry-\(entry.id)",
            kind: entry.item.displayKind,
            text: entry.item.displayText,
            timestamp: entry.timestamp,
            tool: toolInfo(from: entry.item)
        )
    }

    private func appendStreamedRow(item: TimelineItem, seq: Int?, timestamp: String) {
        streamRowCounter += 1
        let id = seq.map { "seq-\($0)" } ?? "stream-\(streamRowCounter)"
        let row = Row(
            id: id,
            kind: item.displayKind,
            text: item.displayText,
            timestamp: timestamp,
            tool: toolInfo(from: item)
        )
        // Coalesce: if the last row has the same id (e.g. assistant_message
        // with same seq arriving twice), replace in place rather than appending.
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

    private func appendLocalUserRow(text: String) {
        let id = "local-\(UUID().uuidString)"
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
