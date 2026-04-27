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
        /// Images the user attached to this message. Populated on the local
        /// optimistic row; preserved across the server's user_message echo
        /// (which doesn't ship the image bytes back).
        let images: [PendingImageAttachment]

        /// Model the agent was running with when this row was produced.
        /// Populated on live streaming so a subsequent model switch shows up
        /// as a differently-tagged chip on the next assistant turn.
        let modelUsed: String?
        /// Wall-clock seconds the turn took. Only set on the last assistant
        /// row of a turn, after turn_completed/failed/canceled arrives.
        var durationSec: TimeInterval?

        init(
            id: String,
            kind: String,
            text: String,
            timestamp: String?,
            tool: ToolInfo? = nil,
            images: [PendingImageAttachment] = [],
            modelUsed: String? = nil,
            durationSec: TimeInterval? = nil
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.timestamp = timestamp
            self.tool = tool
            self.images = images
            self.modelUsed = modelUsed
            self.durationSec = durationSec
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
                // Prefer the colored unified diff (easier to spot added vs
                // removed lines). Fall back to before/after blocks only when
                // no unified diff is available.
                let kind: DetailKind
                if let d = diff, !d.isEmpty {
                    kind = .unifiedDiff(text: d)
                } else if let o = oldStr, let n = newStr, !(o.isEmpty && n.isEmpty) {
                    kind = .beforeAfter(before: o, after: n)
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

    var hasOlderMessages: Bool = false
    private var oldestCursor: AgentTimelineCursor? = nil
    private var currentPermissionRequestId: String? = nil

    /// Messages the user submitted while the agent was busy. We display them
    /// above the composer and flush them one at a time as turns complete.
    var queued: [QueuedMessage] = []

    struct QueuedMessage: Identifiable, Hashable {
        let id: UUID = UUID()
        let text: String                  // final text (text files already inlined)
        let messageId: String             // client-chosen for dedup
        let images: [PendingImageAttachment]
        let createdAt: Date = Date()

        /// Short preview for the chip strip.
        var preview: String {
            let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
            let trimmed = first.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty
                ? "[\(images.count) image\(images.count == 1 ? "" : "s")]"
                : String(trimmed.prefix(80))
        }
    }

    private let getClient: () -> DaemonClient?
    private var streamRowCounter: Int = 0
    /// Model the agent was running with when the most recent `turn_started`
    /// event fired. Used to tag subsequent assistant_message rows so a
    /// mid-conversation model switch is visible per bubble.
    private(set) var currentTurnModel: String? = nil
    private(set) var turnStartedAt: Date? = nil
    /// Elapsed seconds for the most recent completed turn.
    var lastTurnDuration: TimeInterval? = nil
    /// Model used in the most recent turn (for bottom-of-reply display).
    var lastTurnModel: String? = nil
    /// Model to show while a turn is in progress (before lastTurnModel is set).
    var currentDisplayModel: String? { currentTurnModel }

    init(agentId: String, getClient: @escaping () -> DaemonClient?) {
        self.agentId = agentId
        self.getClient = getClient
        let ud = UserDefaults.standard
        self.composerText = ud.string(forKey: "draft_\(agentId)") ?? ""
        if let data = ud.data(forKey: "queued_\(agentId)"),
           let items = try? JSONDecoder().decode([PersistedQueued].self, from: data) {
            self.queued = items.map { QueuedMessage(text: $0.text, messageId: $0.messageId, images: []) }
        }
    }

    // MARK: - Draft persistence

    private struct PersistedQueued: Codable {
        let text: String
        let messageId: String
    }

    func saveDraft() {
        let ud = UserDefaults.standard
        if composerText.isEmpty {
            ud.removeObject(forKey: "draft_\(agentId)")
        } else {
            ud.set(composerText, forKey: "draft_\(agentId)")
        }
    }

    func saveQueued() {
        let ud = UserDefaults.standard
        let items = queued.map { PersistedQueued(text: $0.text, messageId: $0.messageId) }
        if items.isEmpty {
            ud.removeObject(forKey: "queued_\(agentId)")
        } else if let data = try? JSONEncoder().encode(items) {
            ud.set(data, forKey: "queued_\(agentId)")
        }
    }

    // MARK: - Loading

    func loadInitial() async {
        guard !isLoading else { return }
        isLoading = true
        // Reset per-session display state so switching agents
        // doesn't bleed the previous agent's timer/model.
        lastTurnModel = nil
        lastTurnDuration = nil
        defer { isLoading = false }
        do {
            guard let client = getClient() else { return }
            let payload = try await client.fetchTimeline(agentId: agentId, projection: "canonical")
            self.rows = payload.entries.map(rowFromEntry)
            self.hasOlderMessages = payload.hasOlder
            self.oldestCursor = payload.startCursor
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    func loadOlderMessages() async {
        guard !isLoading, hasOlderMessages, let cursor = oldestCursor else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let client = getClient() else { return }
            let payload = try await client.fetchTimeline(
                agentId: agentId,
                direction: "before",
                cursor: cursor,
                limit: 50,
                projection: "canonical"
            )
            let older = payload.entries.map(rowFromEntry)
            self.rows = older + self.rows
            self.hasOlderMessages = payload.hasOlder
            self.oldestCursor = payload.startCursor
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    // MARK: - Send

    /// Default send path: if the agent is mid-turn, queue up for later flush.
    /// Otherwise fire immediately.
    func sendComposer() async {
        guard let pending = drainComposerForSend() else { return }
        if isAgentWorking {
            queued.append(pending)
            saveQueued()
        } else {
            await dispatch(pending)
        }
        saveDraft()
    }

    /// "Interrupt and send" path: cancels whatever the agent is doing right
    /// now, then sends this message immediately (without touching the rest
    /// of the queue). Useful when the user realizes the current run is off
    /// the rails and they want to steer without waiting.
    func sendInterrupting() async {
        guard let pending = drainComposerForSend() else { return }
        if isAgentWorking, let client = getClient() {
            do { _ = try await client.cancelAgent(agentId: agentId) }
            catch { /* best-effort; still try to send */ }
        }
        await dispatch(pending)
    }

    func removeQueued(id: UUID) {
        queued.removeAll { $0.id == id }
        saveQueued()
    }

    /// Pull a queued message back into the composer for editing.
    func editQueued(id: UUID) {
        guard let idx = queued.firstIndex(where: { $0.id == id }) else { return }
        let msg = queued.remove(at: idx)
        composerText = msg.text
        pendingImages = msg.images
        saveQueued()
    }

    /// Pull the composer's current content into a QueuedMessage and clear it.
    /// Returns nil if nothing is actually pending.
    private func drainComposerForSend() -> QueuedMessage? {
        let baseText = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = pendingImages
        let textFiles = pendingTextFiles
        if baseText.isEmpty && images.isEmpty && textFiles.isEmpty { return nil }

        composerText = ""
        pendingImages = []
        pendingTextFiles = []

        let finalText = composeOutgoingText(baseText: baseText, files: textFiles)
        return QueuedMessage(
            text: finalText,
            messageId: UUID().uuidString,
            images: images
        )
    }

    /// Actually fire the RPC and append an optimistic local bubble.
    private func dispatch(_ msg: QueuedMessage) async {
        guard let client = getClient() else {
            self.lastError = "Not connected"
            queued.insert(msg, at: 0)   // put it back so the user doesn't lose it
            return
        }
        appendLocalUserRow(text: msg.text, messageId: msg.messageId, images: msg.images)
        do {
            let wireImages = msg.images.map {
                SendAgentMessageRequest.ImageAttachment(
                    data: $0.pngData.base64EncodedString(),
                    mimeType: $0.mimeType
                )
            }
            _ = try await client.sendMessage(
                agentId: agentId,
                text: msg.text,
                messageId: msg.messageId,
                images: wireImages.isEmpty ? nil : wireImages
            )
            self.lastError = nil
        } catch {
            self.lastError = "Send failed: \(error.localizedDescription)"
        }
    }

    /// Called when the VM sees a terminal turn event. Pops and sends the
    /// next queued message if any.
    private func flushQueueIfNeeded() {
        guard !queued.isEmpty else { return }
        let next = queued.removeFirst()
        saveQueued()
        Task { await dispatch(next) }
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

    func apply(streamEvent: AgentStreamEvent, seq: Int?, timestamp: String, currentModel: String? = nil) {
        switch streamEvent {
        case .turnStarted:
            isAgentWorking = true
            currentTurnModel = currentModel
            turnStartedAt = Date()
        case .turnCompleted, .turnFailed, .turnCanceled:
            isAgentWorking = false
            let dur = turnStartedAt.map { Date().timeIntervalSince($0) }
            if let dur { lastTurnDuration = dur }
            lastTurnModel = currentTurnModel
                ?? rows.last(where: { $0.modelUsed != nil })?.modelUsed
            turnStartedAt = nil
            // Stamp duration + resolved model onto the last assistant row so
            // the info is pinned to that bubble even after the next turn starts.
            if let dur, let idx = rows.lastIndex(where: { $0.kind == "assistant" }) {
                rows[idx].durationSec = dur
                if rows[idx].modelUsed == nil, let m = lastTurnModel {
                    rows[idx] = Row(
                        id: rows[idx].id, kind: rows[idx].kind, text: rows[idx].text,
                        timestamp: rows[idx].timestamp, tool: rows[idx].tool,
                        images: rows[idx].images, modelUsed: m, durationSec: dur
                    )
                }
            }
            flushQueueIfNeeded()
        case .threadStarted:
            break
        case .timelineUpdated(let item):
            appendStreamedRow(item: item, seq: seq, timestamp: timestamp)
        case .permissionRequested(let requestId):
            currentPermissionRequestId = requestId
            appendPermissionRow(timestamp: timestamp)
        case .permissionResolved:
            currentPermissionRequestId = nil
        case .attentionRequired(let reason):
            appendAttentionRow(reason: reason, timestamp: timestamp)
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
                // Preserve the locally-attached image blobs — the daemon
                // doesn't echo them back in the user_message payload.
                rows[idx] = Row(
                    id: localId,
                    kind: "user",
                    text: text,
                    timestamp: timestamp,
                    tool: nil,
                    images: rows[idx].images
                )
                return
            }
        }

        streamRowCounter += 1
        let defaultId = seq.map { "seq-\($0)" } ?? "stream-\(streamRowCounter)"
        let id = rowIdForItem(item, defaultId: defaultId)
        // Tag narrative rows with the model that was active when the turn
        // started. Tool rows and user messages don't carry a model label.
        let tagged: String? = {
            switch item {
            case .assistantMessage, .reasoning: return currentTurnModel
            default: return nil
            }
        }()
        let row = Row(
            id: id,
            kind: item.displayKind,
            text: item.displayText,
            timestamp: timestamp,
            tool: toolInfo(from: item),
            modelUsed: tagged
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

    private func appendLocalUserRow(
        text: String,
        messageId: String,
        images: [PendingImageAttachment] = []
    ) {
        // Id is derived from the messageId we sent so appendStreamedRow can
        // find and replace this row when the daemon echoes it back.
        let id = "msg-\(messageId)"
        rows.append(Row(
            id: id,
            kind: "user",
            text: text,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            tool: nil,
            images: images
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

    private func appendPermissionRow(timestamp: String) {
        streamRowCounter += 1
        rows.append(Row(
            id: "perm-\(streamRowCounter)",
            kind: "permission",
            text: "",
            timestamp: timestamp,
            tool: nil
        ))
    }

    private func appendAttentionRow(reason: String, timestamp: String) {
        streamRowCounter += 1
        rows.append(Row(
            id: "attn-\(streamRowCounter)",
            kind: "attention",
            text: reason,
            timestamp: timestamp,
            tool: nil
        ))
    }

    func approvePermission() async {
        guard let client = getClient() else { return }
        _ = try? await client.sendMessage(agentId: agentId, text: "y")
    }

    func denyPermission() async {
        guard let client = getClient() else { return }
        _ = try? await client.sendMessage(agentId: agentId, text: "n")
    }
}
