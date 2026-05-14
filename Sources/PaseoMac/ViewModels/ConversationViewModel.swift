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
        /// Set on permission/attention rows so the View can collapse them
        /// after `permission_resolved` arrives — otherwise the row falls
        /// back to a stale Allow/Deny banner that still appears to ask the
        /// user for input even though the answer already went through.
        let permissionRequestId: String?

        init(
            id: String,
            kind: String,
            text: String,
            timestamp: String?,
            tool: ToolInfo? = nil,
            images: [PendingImageAttachment] = [],
            modelUsed: String? = nil,
            durationSec: TimeInterval? = nil,
            permissionRequestId: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.text = text
            self.timestamp = timestamp
            self.tool = tool
            self.images = images
            self.modelUsed = modelUsed
            self.durationSec = durationSec
            self.permissionRequestId = permissionRequestId
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
    var composerForceUpdate: UInt = 0

    var hasOlderMessages: Bool = false
    private var oldestCursor: AgentTimelineCursor? = nil
    private var currentPermissionRequestId: String? = nil
    /// Latest pending permission request. `nil` when no permission is
    /// pending; set when a `permission_requested` event arrives and cleared
    /// on `permission_resolved`. Drives the UI's question vs. allow/deny
    /// rendering inside the permission timeline row.
    var pendingPermission: PermissionRequestPayload? = nil
    /// Permission request IDs we've seen a `permission_resolved` for. The
    /// View checks this to collapse the corresponding permission/attention
    /// rows so the user doesn't see a stale Allow/Deny banner after they
    /// already answered the question.
    var resolvedPermissionIds: Set<String> = []

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

    /// Cached per-bubble (model, duration) keyed by stream seq. Stream events
    /// stamp this on turn_completed; loadInitial restores it so historical
    /// bubbles keep their TurnMetaChip across app restarts and reconnects.
    /// Daemon's TimelineEntry doesn't carry this metadata, so without a
    /// client-side cache only live-streamed bubbles would have a chip.
    private struct TurnMeta: Codable {
        let model: String?
        let duration: TimeInterval?
    }
    private var metaCache: [Int: TurnMeta] = [:]
    private var metaCacheURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("PaseoMac/meta", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(agentId).json")
    }

    private func loadMetaCache() {
        guard let data = try? Data(contentsOf: metaCacheURL),
              let raw = try? JSONDecoder().decode([String: TurnMeta].self, from: data) else { return }
        metaCache = Dictionary(uniqueKeysWithValues: raw.compactMap { (k, v) -> (Int, TurnMeta)? in
            guard let i = Int(k) else { return nil }
            return (i, v)
        })
    }

    private func saveMetaCache() {
        let snapshot = metaCache
        let url = metaCacheURL
        Task.detached(priority: .utility) {
            let stringKeyed = Dictionary(uniqueKeysWithValues: snapshot.map { (String($0.key), $0.value) })
            if let data = try? JSONEncoder().encode(stringKeyed) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    /// Pull seq out of a stream-generated row id like "seq-42". Returns nil
    /// for tool-* / msg-* / entry-* / stream-* ids.
    private func seqFromId(_ id: String) -> Int? {
        guard id.hasPrefix("seq-") else { return nil }
        return Int(id.dropFirst(4))
    }

    init(agentId: String, getClient: @escaping () -> DaemonClient?) {
        self.agentId = agentId
        self.getClient = getClient
        let ud = UserDefaults.standard
        self.composerText = ud.string(forKey: "draft_\(agentId)") ?? ""
        if let data = ud.data(forKey: "queued_\(agentId)"),
           let items = try? JSONDecoder().decode([PersistedQueued].self, from: data) {
            self.queued = items.map { QueuedMessage(text: $0.text, messageId: $0.messageId, images: []) }
        }
        loadMetaCache()
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
        // The placeholder VM created during the new-conversation flow has
        // agentId = AppViewModel.pendingAgentId; calling fetchTimeline on it
        // returns "Agent not found" and tears down the connection.
        guard agentId != AppViewModel.pendingAgentId else { return }
        isLoading = true
        // Reset per-session display state so switching agents
        // doesn't bleed the previous agent's timer/model.
        lastTurnModel = nil
        lastTurnDuration = nil
        defer { isLoading = false }
        do {
            guard let client = getClient() else { return }
            let payload = try await client.fetchTimeline(agentId: agentId, projection: "canonical")
            let fetched = payload.entries.map(rowFromEntry)
            // For brand-new agents the daemon may not have persisted the
            // first message yet — fetched is empty while the streaming
            // path has already populated optimistic/echoed rows. Naively
            // overwriting blanks them out and the only escape is jumping
            // around the timeline to force a re-render. Trust local rows
            // when fetch returns nothing.
            if !fetched.isEmpty || self.rows.isEmpty {
                self.rows = fetched
            }
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
        composerForceUpdate &+= 1
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
        EventLogger.shared.log("send", "request", [
            "agent": agentId, "messageId": msg.messageId,
            "len": msg.text.count, "images": msg.images.count
        ])
        let started = Date()
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
            EventLogger.shared.log("send", "ack", [
                "agent": agentId, "messageId": msg.messageId,
                "elapsedMs": Int(Date().timeIntervalSince(started) * 1000)
            ])
            self.lastError = nil
        } catch {
            EventLogger.shared.log("send", "error", [
                "agent": agentId, "messageId": msg.messageId,
                "err": error.localizedDescription
            ])
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
            // If the snapshot lookup didn't have a model handy (status pings
            // sometimes drop it), keep whatever we resolved on the previous
            // turn rather than blanking out the live "Opus · 2m" chip.
            if let m = currentModel { currentTurnModel = m }
            turnStartedAt = Date()
        case .turnCompleted, .turnFailed, .turnCanceled:
            isAgentWorking = false
            let dur = turnStartedAt.map { Date().timeIntervalSince($0) }
            if let dur {
                lastTurnDuration = dur
                EventLogger.shared.log("turn", "finalized", [
                    "agent": agentId, "durSec": Int(dur)
                ])
            }
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
                // Persist so the chip survives app restart / reconnect reload.
                if let seq = seqFromId(rows[idx].id) {
                    metaCache[seq] = TurnMeta(model: rows[idx].modelUsed, duration: dur)
                    saveMetaCache()
                }
            }
            flushQueueIfNeeded()
        case .threadStarted:
            break
        case .timelineUpdated(let item):
            appendStreamedRow(item: item, seq: seq, timestamp: timestamp)
        case .permissionRequested(let payload):
            currentPermissionRequestId = payload?.id
            pendingPermission = payload
            appendPermissionRow(timestamp: timestamp, requestId: payload?.id)
        case .permissionResolved(let requestId):
            if !requestId.isEmpty { resolvedPermissionIds.insert(requestId) }
            currentPermissionRequestId = nil
            pendingPermission = nil
        case .attentionRequired(let reason):
            // "finished" fires after every turn completes; TurnStatusBar already
            // shows the duration so an extra banner is pure noise. Keep
            // "permission" / "failed" / errors since they need user action.
            guard reason != "finished" else { break }
            let linkedId = (reason == "permission") ? currentPermissionRequestId : nil
            appendAttentionRow(reason: reason, timestamp: timestamp, requestId: linkedId)
        case .other:
            break
        }
    }

    // MARK: - Row helpers

    private func rowFromEntry(_ entry: TimelineEntry) -> Row {
        // Daemon collapses multiple stream chunks into one entry spanning
        // [seqStart...seqEnd]. The stamp at turn_completed targeted the
        // last assistant chunk, so prefer seqEnd; fall back to scanning
        // the range for safety since coalescing rules may shift over time.
        var meta: TurnMeta? = metaCache[entry.seqEnd] ?? metaCache[entry.seqStart]
        if meta == nil && entry.seqStart < entry.seqEnd {
            for s in entry.seqStart...entry.seqEnd {
                if let hit = metaCache[s] { meta = hit; break }
            }
        }
        return Row(
            id: rowIdForItem(entry.item, defaultId: "entry-\(entry.id)"),
            kind: entry.item.displayKind,
            text: entry.item.displayText,
            timestamp: entry.timestamp,
            tool: toolInfo(from: entry.item),
            modelUsed: meta?.model,
            durationSec: meta?.duration
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

    /// Public entry point for AppViewModel.submitPendingAgent (images path) to
    /// pre-populate the new conversation with an optimistic user bubble before
    /// the daemon's user_message echo arrives. Without this, switching to the
    /// just-created agent would briefly render an empty conversation.
    func injectOptimisticFirstMessage(
        text: String,
        messageId: String,
        images: [PendingImageAttachment]
    ) {
        appendLocalUserRow(text: text, messageId: messageId, images: images)
    }

    /// Clear `lastError` if it was a stale connection-related message left
    /// over from a disconnect window. Called by AppViewModel after a
    /// successful reconnect so the red error banner doesn't linger
    /// indefinitely while the sidebar already shows "Connected".
    func clearConnectionError() {
        guard let err = lastError else { return }
        let lower = err.lowercased()
        if lower.contains("not connected")
            || lower.contains("daemon is not connected")
            || lower.contains("relay channel is not connected")
            || lower.contains("relay connection")
            || lower.contains("send failed: daemon") {
            lastError = nil
        }
    }

    /// Seed the live turn model for a brand-new agent whose first
    /// turn_started event arrived before the agent_status that would have
    /// populated agents[].model. Without this, AppViewModel passes
    /// currentModel: nil at turn_started and the per-bubble
    /// model + duration chip never appears on the first reply.
    /// Idempotent — only seeds when no model is currently in flight.
    func seedTurnModel(_ model: String) {
        if currentTurnModel == nil {
            currentTurnModel = model
        }
    }

    /// Reconcile working state with daemon's authoritative status.
    /// Call when an `agent_status` event arrives or on reconnect: if the
    /// daemon says idle but we think we're still working, the
    /// `turn_completed` event was lost (briefly disconnected). Without this
    /// the spinner hangs forever and the only fix is restarting the app.
    func reconcileAgentStatus(_ status: String) {
        if status == "idle" && isAgentWorking {
            EventLogger.shared.log("turn", "reconciled_idle", [
                "agent": agentId,
                "durSec": turnStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
            ])
            isAgentWorking = false
            if let started = turnStartedAt {
                lastTurnDuration = Date().timeIntervalSince(started)
            }
            turnStartedAt = nil
            // Pin model on the last assistant row, mirroring turn_completed flow.
            if let dur = lastTurnDuration,
               let model = currentTurnModel ?? rows.last(where: { $0.modelUsed != nil })?.modelUsed,
               let idx = rows.lastIndex(where: { $0.kind == "assistant" }) {
                lastTurnModel = model
                rows[idx].durationSec = dur
                if rows[idx].modelUsed == nil {
                    rows[idx] = Row(
                        id: rows[idx].id, kind: rows[idx].kind, text: rows[idx].text,
                        timestamp: rows[idx].timestamp, tool: rows[idx].tool,
                        images: rows[idx].images, modelUsed: model, durationSec: dur
                    )
                }
                if let seq = seqFromId(rows[idx].id) {
                    metaCache[seq] = TurnMeta(model: rows[idx].modelUsed, duration: dur)
                    saveMetaCache()
                }
            }
            currentTurnModel = nil
        }
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

    private func appendPermissionRow(timestamp: String, requestId: String?) {
        streamRowCounter += 1
        rows.append(Row(
            id: "perm-\(streamRowCounter)",
            kind: "permission",
            text: "",
            timestamp: timestamp,
            tool: nil,
            permissionRequestId: requestId
        ))
    }

    private func appendAttentionRow(reason: String, timestamp: String, requestId: String?) {
        streamRowCounter += 1
        rows.append(Row(
            id: "attn-\(streamRowCounter)",
            kind: "attention",
            text: reason,
            timestamp: timestamp,
            tool: nil,
            permissionRequestId: requestId
        ))
    }

    func approvePermission() async {
        guard let client = getClient() else { return }
        if let req = pendingPermission {
            // Real permission_response RPC. Works for tool/plan/mode kinds.
            _ = try? await client.respondPermission(
                agentId: agentId, requestId: req.id,
                response: .allow(updatedInput: nil)
            )
        } else {
            // Pre-payload fallback (legacy path; daemon never delivered the
            // request structure). Keep the y/n shortcut so older agents
            // resumed from disk still answer.
            _ = try? await client.sendMessage(agentId: agentId, text: "y")
        }
    }

    func denyPermission() async {
        guard let client = getClient() else { return }
        if let req = pendingPermission {
            _ = try? await client.respondPermission(
                agentId: agentId, requestId: req.id,
                response: .deny(message: nil)
            )
        } else {
            _ = try? await client.sendMessage(agentId: agentId, text: "n")
        }
    }

    /// Submit answers for the pending AskUserQuestion. `answers` is keyed by
    /// the question's `header` field (daemon-side normalizer re-keys for the
    /// underlying tool's expected schema).
    func submitQuestionAnswers(_ answers: [String: String]) async {
        guard let client = getClient(),
              let req = pendingPermission,
              let aq = req.askUserQuestion else { return }
        let payload = AskUserQuestionAnswers(
            questions: aq.questions,
            answers: answers
        )
        _ = try? await client.respondPermission(
            agentId: agentId, requestId: req.id,
            response: .allow(updatedInput: payload)
        )
    }
}
