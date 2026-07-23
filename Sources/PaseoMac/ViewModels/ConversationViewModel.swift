import Foundation
import Observation
import UserNotifications
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

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
        let messageId: String?
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
            messageId: String? = nil,
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
            self.messageId = messageId
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

    var rows: [Row] = [] {
        didSet {
            setCachedRows?(rows)
            persistDiskCache_claudecode_20260713()
        }
    }
    var isLoading: Bool = false
    var isAgentWorking: Bool = false
    /// 本设备最近一次"用户主动发送"的时刻（sendComposer / sendInterrupting /
    /// forceSendAnyway）。MessageList 用它区分"我刚发的消息"（应该跳到新
    /// 消息）和"别处到达的用户消息"（channel 转发、定时任务、队列自动
    /// flush——正在回看历史时不该被拽走）。2026.07.23 Naron
    var lastLocalSendAt_claudecode_20260723: Date? = nil
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
    private var metaCacheURL: URL { Self.metaCacheURL_claudecode_20260713(agentId: agentId) }

    private static func metaCacheURL_claudecode_20260713(agentId: String) -> URL {
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

    // MARK: - Disk-backed conversation cache (survives app relaunch)
    //
    // AppViewModel's in-memory `conversationRowsCache` (wired via
    // getCachedRows/setCachedRows below) only lives as long as the process —
    // on iOS the app is routinely killed by the system in the background, so
    // every cold relaunch of a long conversation had to wait on a full
    // fetchTimeline round trip before showing anything, with a blank/spinner
    // screen for however long that took. This mirrors the same rows (plus
    // pagination state) to disk so the transcript paints instantly from the
    // last known state while loadInitial() quietly reconciles with the
    // server in the background. Cleared only when the session itself is
    // archived/deleted (see AppViewModel.archiveAgent →
    // ConversationViewModel.deleteAllDiskState_claudecode_20260713).
    // 2026.07.13 Naron

    private struct PersistedToolInfo_claudecode_20260713: Codable {
        let name: String
        let target: String?
        let status: String
        let iconName: String
        let detailKind: String   // "none" | "plain" | "beforeAfter" | "unifiedDiff"
        let detailText: String?
        let detailMonospaced: Bool?
        let detailBefore: String?
        let detailAfter: String?
    }

    private struct PersistedRow_claudecode_20260713: Codable {
        let id: String
        let kind: String
        let text: String
        let timestamp: String?
        let messageId: String?
        let tool: PersistedToolInfo_claudecode_20260713?
        let modelUsed: String?
        let durationSec: TimeInterval?
        let permissionRequestId: String?
    }

    private struct PersistedConversationCache_claudecode_20260713: Codable {
        let rows: [PersistedRow_claudecode_20260713]
        let hasOlderMessages: Bool
        let oldestCursor: AgentTimelineCursor?
    }

    /// Newest rows kept in the on-disk cache. This is a paint-fast bridge,
    /// not a full-history mirror — loadInitial() always reconciles with the
    /// server's own tail fetch moments after restore, so there's no value
    /// in persisting more than a generous single-screen-and-then-some window.
    private static let diskCacheRowLimit_claudecode_20260713 = 300

    private static func diskCacheDir_claudecode_20260713() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = support.appendingPathComponent("PaseoMac/conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func diskCacheURL_claudecode_20260713(agentId: String) -> URL {
        diskCacheDir_claudecode_20260713().appendingPathComponent("\(agentId).json")
    }

    private static func persistedToolInfo_claudecode_20260713(from tool: ToolInfo) -> PersistedToolInfo_claudecode_20260713 {
        switch tool.detailKind {
        case .none:
            return PersistedToolInfo_claudecode_20260713(
                name: tool.name, target: tool.target, status: tool.status, iconName: tool.iconName,
                detailKind: "none", detailText: nil, detailMonospaced: nil, detailBefore: nil, detailAfter: nil
            )
        case .plain(let text, let monospaced):
            return PersistedToolInfo_claudecode_20260713(
                name: tool.name, target: tool.target, status: tool.status, iconName: tool.iconName,
                detailKind: "plain", detailText: text, detailMonospaced: monospaced, detailBefore: nil, detailAfter: nil
            )
        case .beforeAfter(let before, let after):
            return PersistedToolInfo_claudecode_20260713(
                name: tool.name, target: tool.target, status: tool.status, iconName: tool.iconName,
                detailKind: "beforeAfter", detailText: nil, detailMonospaced: nil, detailBefore: before, detailAfter: after
            )
        case .unifiedDiff(let text):
            return PersistedToolInfo_claudecode_20260713(
                name: tool.name, target: tool.target, status: tool.status, iconName: tool.iconName,
                detailKind: "unifiedDiff", detailText: text, detailMonospaced: nil, detailBefore: nil, detailAfter: nil
            )
        }
    }

    private static func toolInfo_claudecode_20260713(from p: PersistedToolInfo_claudecode_20260713) -> ToolInfo {
        let kind: DetailKind
        switch p.detailKind {
        case "plain": kind = .plain(text: p.detailText ?? "", monospaced: p.detailMonospaced ?? true)
        case "beforeAfter": kind = .beforeAfter(before: p.detailBefore ?? "", after: p.detailAfter ?? "")
        case "unifiedDiff": kind = .unifiedDiff(text: p.detailText ?? "")
        default: kind = .none
        }
        return ToolInfo(name: p.name, target: p.target, status: p.status, iconName: p.iconName, detailKind: kind)
    }

    /// Images never round-trip through this cache (they're already dropped
    /// on the server echo path — see appendStreamedRow's user_message
    /// handling — so a disk-cached historical row never had them to begin
    /// with once this VM is recreated).
    private static func persistedRow_claudecode_20260713(from row: Row) -> PersistedRow_claudecode_20260713 {
        PersistedRow_claudecode_20260713(
            id: row.id, kind: row.kind, text: row.text, timestamp: row.timestamp,
            messageId: row.messageId, tool: row.tool.map(persistedToolInfo_claudecode_20260713(from:)),
            modelUsed: row.modelUsed, durationSec: row.durationSec,
            permissionRequestId: row.permissionRequestId
        )
    }

    private static func row_claudecode_20260713(from p: PersistedRow_claudecode_20260713) -> Row {
        Row(
            id: p.id, kind: p.kind, text: p.text, timestamp: p.timestamp,
            messageId: p.messageId, tool: p.tool.map(toolInfo_claudecode_20260713(from:)),
            images: [], modelUsed: p.modelUsed, durationSec: p.durationSec,
            permissionRequestId: p.permissionRequestId
        )
    }

    private static func loadDiskCache_claudecode_20260713(agentId: String) -> PersistedConversationCache_claudecode_20260713? {
        guard let data = try? Data(contentsOf: diskCacheURL_claudecode_20260713(agentId: agentId)) else { return nil }
        return try? JSONDecoder().decode(PersistedConversationCache_claudecode_20260713.self, from: data)
    }

    /// Fire-and-forget disk write off the main actor. Called from every
    /// `rows` mutation (didSet) — encoding a few hundred small structs is
    /// sub-millisecond, matching the existing saveMetaCache() pattern, so
    /// no debouncing is needed.
    private func persistDiskCache_claudecode_20260713() {
        guard agentId != AppViewModel.pendingAgentId else { return }
        let capped = Array(rows.suffix(Self.diskCacheRowLimit_claudecode_20260713))
        let persisted = PersistedConversationCache_claudecode_20260713(
            rows: capped.map(Self.persistedRow_claudecode_20260713(from:)),
            hasOlderMessages: hasOlderMessages,
            oldestCursor: oldestCursor
        )
        let url = Self.diskCacheURL_claudecode_20260713(agentId: agentId)
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(persisted) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Wipes every on-disk trace of this session: the rows cache above, the
    /// turn-meta chip cache, and the draft/queued UserDefaults entries.
    /// Called from AppViewModel.archiveAgent — the only place a session's
    /// lifetime actually ends. Nothing else should ever clear this state.
    static func deleteAllDiskState_claudecode_20260713(agentId: String) {
        try? FileManager.default.removeItem(at: diskCacheURL_claudecode_20260713(agentId: agentId))
        try? FileManager.default.removeItem(at: metaCacheURL_claudecode_20260713(agentId: agentId))
        let ud = UserDefaults.standard
        ud.removeObject(forKey: "draft_\(agentId)")
        ud.removeObject(forKey: "queued_\(agentId)")
    }

    /// Pull seq out of a stream-generated row id like "seq-42". Returns nil
    /// for tool-* / msg-* / entry-* / stream-* ids.
    private func seqFromId(_ id: String) -> Int? {
        guard id.hasPrefix("seq-") else { return nil }
        return Int(id.dropFirst(4))
    }

    private let getAgentName: () -> String?
    /// Whether this agent's conversation is the one currently on screen
    /// (selectedAgentId == agentId). Used to suppress a notification only
    /// when the user is already looking at this exact conversation — NOT
    /// whenever the app merely has focus, since another agent's turn (e.g.
    /// an AskUserQuestion) can arrive while a different conversation is
    /// open. See sendNotification(). 2026.07.15 Naron
    private var getIsSelected: (() -> Bool)? = nil
    private var getCachedRows: (() -> [Row]?)? = nil
    private var setCachedRows: (([Row]) -> Void)? = nil
    /// Dedup guard for replayed turnCompleted/turnFailed/turnCanceled events
    /// — see the comment at the call site in apply(streamEvent:).
    private var lastHandledTerminalEventTimestamp_claudecode_20260714: String? = nil

    init(
        agentId: String,
        getClient: @escaping () -> DaemonClient?,
        getAgentName: @escaping () -> String?,
        getIsSelected: (() -> Bool)? = nil,
        getCachedRows: (() -> [Row]?)? = nil,
        setCachedRows: (([Row]) -> Void)? = nil
    ) {
        self.agentId = agentId
        self.getClient = getClient
        self.getAgentName = getAgentName
        self.getIsSelected = getIsSelected
        self.getCachedRows = getCachedRows
        self.setCachedRows = setCachedRows

        // In-memory cache (same app run, VM was merely evicted from the LRU)
        // is free to read, so restore it immediately. The on-disk cache
        // (survives a cold relaunch) is deliberately NOT read here — iOS's
        // conversation paging view (TabView) constructs a VM for every open
        // agent up front, and doing disk IO for all of them at once on
        // init reintroduces the same "storm" that made opening any single
        // conversation slow. It's read lazily in
        // ensureLoaded_claudecode_20260713(), which only runs for the
        // conversation actually selected/visible. 2026.07.13 Naron
        if let cached = getCachedRows?() {
            self.rows = cached
        }

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

    private func loadOlderMessagesInternal(limit: Int) async -> [Row] {
        guard hasOlderMessages, let cursor = oldestCursor else { return [] }
        do {
            guard let client = getClient() else { return [] }
            let payload = try await client.fetchTimeline(
                agentId: agentId,
                direction: "before",
                cursor: cursor,
                limit: limit,
                projection: "canonical"
            )
            let older = payload.entries.map(rowFromEntry)
            self.rows = older + self.rows
            self.hasOlderMessages = payload.hasOlder
            self.oldestCursor = payload.startCursor
            Task { await prewarmRenderCache_claudecode_20260713(older) }
            return older
        } catch {
            self.lastError = error.localizedDescription
            return []
        }
    }

    /// True once ensureLoaded_claudecode_20260713() has kicked off (or
    /// skipped, for a brand-new agent that already has optimistic rows) the
    /// first load for this VM's lifetime, so repeated calls (e.g. re-selecting
    /// the same tab) don't refetch every time.
    private var hasRequestedInitialLoad_claudecode_20260713 = false

    /// The actual "this conversation is now visible to the user" entry
    /// point. Cheap VM construction happens unconditionally in
    /// AppViewModel.conversation(for:) — every open agent's TabView page
    /// constructs one — but any I/O (disk cache read, network fetch) is
    /// deferred until here, called only from
    /// AppViewModel.markConversationAccessed_claudecode_20260713 (driven by
    /// selectedAgentId actually changing). This is what keeps opening one
    /// conversation from firing a fetchTimeline storm for every other open
    /// agent. 2026.07.13 Naron
    func ensureLoaded_claudecode_20260713() {
        if hasRequestedInitialLoad_claudecode_20260713 {
            guard lastError != nil else { return }
        }
        hasRequestedInitialLoad_claudecode_20260713 = true
        if rows.isEmpty, agentId != AppViewModel.pendingAgentId,
           let diskCache = Self.loadDiskCache_claudecode_20260713(agentId: agentId) {
            self.rows = diskCache.rows.map(Self.row_claudecode_20260713(from:))
            self.hasOlderMessages = diskCache.hasOlderMessages
            self.oldestCursor = diskCache.oldestCursor
        }
        Task { await loadInitial() }
    }

    func loadInitial() async {
        guard !isLoading else { return }
        // The placeholder VM created during the new-conversation flow has
        // agentId = AppViewModel.pendingAgentId; calling fetchTimeline on it
        // returns "Agent not found" and tears down the connection.
        guard agentId != AppViewModel.pendingAgentId else { return }
        isLoading = true
        lastError = nil
        // Reset per-session display state so switching agents
        // doesn't bleed the previous agent's timer/model.
        lastTurnModel = nil
        lastTurnDuration = nil
        defer { isLoading = false }
        do {
            guard let client = getClient() else { return }
            let payload = try await client.fetchTimeline(agentId: agentId, limit: 50, projection: "projected")
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

            // iOS opens conversations at the tail first. Older turns and full
            // canonical detail are loaded explicitly via the existing load-more
            // path, which keeps first render cheap on large chats. 2026.07.11 Naron

            if isAgentWorking {
                if let lastUserRow = rows.last(where: { $0.kind == "user" }),
                   let ts = lastUserRow.timestamp {
                    let formatterFull = ISO8601DateFormatter()
                    formatterFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let parsed = formatterFull.date(from: ts) ?? ISO8601DateFormatter().date(from: ts) {
                        turnStartedAt = parsed
                    }
                }
            }
            populateHistoricalDurations()
            Task { await prewarmRenderCache_claudecode_20260713(fetched) }
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    /// 会话页"滚动很卡"的根因：LazyVStack 只在一段消息第一次进入屏幕时
    /// 才构建它，此时才第一次跑 Markdown 分块 + 代码高亮，这些同步解析
    /// 工作恰好卡在用户手指划动的那一帧上，感觉就像"在加载历史消息"。
    /// 这里在数据到手后立刻（趁用户还停留在底部、还没开始上滑时）把这批
    /// 消息的解析结果预热进缓存，真正滚动到时直接命中缓存。跨帧让出，
    /// 不会一次性占满一帧。2026.07.13 Naron
    @MainActor
    private func prewarmRenderCache_claudecode_20260713(_ rowsToWarm: [Row]) async {
        for (i, row) in rowsToWarm.enumerated() {
            guard !row.text.isEmpty else { continue }
            for block in Markdown.parseCached_claudecode_20260712(row.text) {
                switch block {
                case .code(let lang, let content):
                    _ = SyntaxHighlighter.highlight(content, language: lang)
                case .heading(_, let text):
                    _ = Markdown.renderInline(text)
                case .paragraph(let text):
                    _ = Markdown.renderInline(text)
                case .blockquote(let text):
                    _ = Markdown.renderInline(Markdown.normalizeBlockquoteText(text))
                case .bulletList(let items):
                    for item in items { _ = Markdown.renderInline(item.text) }
                case .orderedList(_, let items):
                    for item in items { _ = Markdown.renderInline(item.text) }
                case .table(let headers, let tableRows):
                    for h in headers { _ = Markdown.renderInline(h) }
                    for r in tableRows { for c in r { _ = Markdown.renderInline(c) } }
                case .horizontalRule, .image:
                    break
                }
            }
            if i % 4 == 3 { await Task.yield() }
        }
    }

    func loadOlderMessages() async {
        guard !isLoading, hasOlderMessages else { return }
        isLoading = true
        defer { isLoading = false }
        
        // Load a single fixed batch (limit: 40) per explicit user click
        _ = await loadOlderMessagesInternal(limit: 40)
        populateHistoricalDurations()
    }

    // MARK: - Send

    /// How long a turn must have been "working" before we treat it as
    /// stuck. Codex/Claude turns typically finish in seconds to a few
    /// minutes; past this the most likely explanation is a lost
    /// turn_completed event (e.g. the WS was half-open through a Mac
    /// sleep and the event went to /dev/null). Forcing the next user
    /// message through then is safer than letting it queue forever.
    private static let staleTurnSeconds: TimeInterval = 300  // 5 minutes

    /// True when `isAgentWorking` has been set for longer than the stale
    /// threshold. The composer uses this to decide whether to silently
    /// queue OR fall through the "send anyway" interrupt path.
    var turnLooksStuck: Bool {
        guard isAgentWorking, let started = turnStartedAt else { return false }
        return Date().timeIntervalSince(started) > Self.staleTurnSeconds
    }

    /// Default send path: if the agent is mid-turn, queue up for later flush.
    /// Otherwise fire immediately. If the in-progress turn has been
    /// "running" for longer than the stale threshold (5 min default) we
    /// treat it as a missed turn_completed event and dispatch directly,
    /// resetting the local working flag — the daemon will sort out the
    /// ordering server-side. This is the auto-fix for the "overnight
    /// queue" bug; the manual-fix lives on the queue strip's
    /// `Send anyway` button.
    func sendComposer() async {
        guard let pending = drainComposerForSend() else { return }
        lastLocalSendAt_claudecode_20260723 = Date()
        if isAgentWorking && !turnLooksStuck {
            queued.append(pending)
            saveQueued()
        } else {
            if isAgentWorking && turnLooksStuck {
                EventLogger.shared.log("turn", "stale_bypass", [
                    "agent": agentId,
                    "ageSec": Int(turnStartedAt.map { Date().timeIntervalSince($0) } ?? 0)
                ])
                isAgentWorking = false
                turnStartedAt = nil
            }
            await dispatch(pending)
        }
        saveDraft()
    }

    /// Entry point for AppViewModel's scheduled-send timer. Deliberately
    /// separate from sendComposer(): a scheduled message fires whenever its
    /// time arrives, regardless of whatever unrelated draft text the user
    /// currently has sitting in the composer — it must not touch
    /// composerText/pendingImages. Respects the same "queue while the agent
    /// is mid-turn" rule as a normal send. 2026.07.14 Naron
    func sendScheduledText_claudecode_20260714(_ text: String) async {
        guard !text.isEmpty else { return }
        let pending = QueuedMessage(text: text, messageId: UUID().uuidString, images: [])
        if isAgentWorking && !turnLooksStuck {
            queued.append(pending)
            saveQueued()
        } else {
            await dispatch(pending)
        }
    }

    /// Manual escape hatch surfaced on the queue strip when messages
    /// stack up. Cancels any in-flight turn (best-effort), clears the
    /// local working flag, and flushes the queue head + new content.
    /// Use this when the user knows the agent isn't actually doing
    /// anything but the UI claims otherwise.
    func forceSendAnyway() async {
        EventLogger.shared.log("turn", "force_send_anyway", ["agent": agentId])
        lastLocalSendAt_claudecode_20260723 = Date()
        if let client = getClient() {
            _ = try? await client.cancelAgent(agentId: agentId)
        }
        isAgentWorking = false
        turnStartedAt = nil
        // Drain queue front-to-back. Each dispatch is awaited so we
        // don't pile up parallel sends — daemon ordering matters.
        // When the daemon WS is dead (common after overnight Mac sleep
        // leaves a half-open socket), dispatch re-inserts the message
        // at the head; without breaking on that signal the loop spins
        // forever hammering NSUserDefaults and freezes the app until
        // the user force-quits.
        while !queued.isEmpty {
            let next = queued.removeFirst()
            saveQueued()
            let didSend = await dispatch(next)
            if !didSend {
                EventLogger.shared.log("turn", "force_send_abort", [
                    "agent": agentId,
                    "remainingQueue": queued.count
                ])
                saveDraft()
                return
            }
        }
        // If the user typed something while the queue was up, send that too.
        if let pending = drainComposerForSend() {
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
        lastLocalSendAt_claudecode_20260723 = Date()
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
    /// Returns true if the RPC was attempted (even if the daemon then
    /// errored — the local bubble is up and the user sees the failure
    /// banner). Returns false only when the daemon connection isn't
    /// available; in that case the message is put back at the head of
    /// the queue so callers iterating the queue can break out instead
    /// of spinning.
    @discardableResult
    private func dispatch(_ msg: QueuedMessage) async -> Bool {
        guard let client = getClient() else {
            self.lastError = "Not connected"
            queued.insert(msg, at: 0)   // put it back so the user doesn't lose it
            saveQueued()
            return false
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
        return true
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
            // 同一逻辑轮次的终止事件有时会被重复投递——典型场景是 WS 短暂
            // 断开重连，daemon 重放最近一小段事件缓冲区，把已经处理过的
            // turn_completed 又当成新事件推一次。表现正是用户反馈的"通知了
            // 三次，而且不是准确的节点"：多条通知 + 出现在重连发生的那一刻
            // 而不是回复真正完成的那一刻。用事件自带的 timestamp 去重：
            // 两次真正不同的轮次完成，时间戳精确到毫秒不可能相同；一次真正
            // 的重复投递则 timestamp 完全一致，直接跳过整段处理（不只是
            // 跳过通知——重复投递也会导致下面的 flushQueueIfNeeded 把队列
            // 里下一条消息提前发出去）。2026.07.14 Naron
            guard timestamp != lastHandledTerminalEventTimestamp_claudecode_20260714 else {
                EventLogger.shared.log("turn", "duplicate_terminal_event_skipped", [
                    "agent": agentId, "timestamp": timestamp
                ])
                return
            }
            lastHandledTerminalEventTimestamp_claudecode_20260714 = timestamp
            isAgentWorking = false
            let dur = turnStartedAt.map { Date().timeIntervalSince($0) }
            if let dur {
                lastTurnDuration = dur
                EventLogger.shared.log("turn", "finalized", [
                    "agent": agentId, "durSec": Int(dur)
                ])
            }
            if case let .turnFailed(rawErr) = streamEvent {
                var displayErr = rawErr
                // Heuristic: if the daemon sends an unformatted JS object,
                // try to find the actual error message in the timeline we just received.
                if displayErr.contains("[object Object]") {
                    if let lastRowErr = rows.last(where: { $0.kind == "error" && !$0.text.contains("[object Object]") })?.text {
                        displayErr = lastRowErr
                    } else {
                        displayErr = "Backend internal error (unformatted JS error). This often indicates an API Quota limit or transient network failure."
                    }
                }
                self.lastError = displayErr
            }
            flushQueueIfNeeded()
            let m = currentTurnModel
                ?? lastTurnModel
                ?? rows.last(where: { $0.modelUsed != nil })?.modelUsed
            turnStartedAt = nil
            // Stamp duration + resolved model onto the last assistant row so
            // the info is pinned to that bubble even after the next turn starts.
            if let dur, let idx = rows.lastIndex(where: { $0.kind == "assistant" }) {
                rows[idx].durationSec = dur
                if rows[idx].modelUsed == nil, let resolvedModel = m {
                    rows[idx] = Row(
                        id: rows[idx].id, kind: rows[idx].kind, text: rows[idx].text,
                        timestamp: rows[idx].timestamp, messageId: rows[idx].messageId,
                        tool: rows[idx].tool,
                        images: rows[idx].images, modelUsed: resolvedModel, durationSec: dur
                    )
                }
                // Persist so the chip survives app restart / reconnect reload.
                if let seq = seqFromId(rows[idx].id) {
                    metaCache[seq] = TurnMeta(model: rows[idx].modelUsed, duration: dur)
                    saveMetaCache()
                }
            }
            populateHistoricalDurations()
            
            // Trigger notifications
            switch streamEvent {
            case .turnCompleted:
                sendNotification(
                    title: "\(getAgentName() ?? "Agent") finished replying",
                    body: "Turn completed successfully."
                )
            case .turnFailed(let rawErr):
                var desc = rawErr
                if desc.contains("[object Object]") {
                    desc = "Backend internal error."
                }
                sendNotification(
                    title: "\(getAgentName() ?? "Agent") failed to reply",
                    body: desc
                )
            default:
                break
            }
        case .threadStarted:
            break
        case .timelineUpdated(let item):
            appendStreamedRow(item: item, seq: seq, timestamp: timestamp)
        case .permissionRequested(let payload):
            currentPermissionRequestId = payload?.id
            pendingPermission = payload
            appendPermissionRow(timestamp: timestamp, requestId: payload?.id)
            let isQuestion = payload?.isQuestion ?? false
            let desc = payload?.description
                ?? (isQuestion ? payload?.askUserQuestion?.questions.first?.question : nil)
                ?? "Waiting for your authorization."
            sendNotification(
                title: "\(getAgentName() ?? "Agent") \(isQuestion ? "has a question" : "needs permission")",
                body: desc
            )
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
            if entry.seqEnd - entry.seqStart <= 50 {
                for s in entry.seqStart...entry.seqEnd {
                    if let hit = metaCache[s] { meta = hit; break }
                }
            } else {
                for (s, hit) in metaCache {
                    if s >= entry.seqStart && s <= entry.seqEnd {
                        meta = hit
                        break
                    }
                }
            }
        }
        return Row(
            id: rowIdForItem(entry.item, defaultId: "entry-\(entry.id)"),
            kind: entry.item.displayKind,
            text: entry.item.displayText,
            timestamp: entry.timestamp,
            messageId: messageId(from: entry.item),
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
        if case let .userMessage(text, msgId) = item {
            if let msgId,
               let idx = rows.firstIndex(where: { $0.id == "msg-\(msgId)" }) {
                // Preserve the locally-attached image blobs — the daemon
                // doesn't echo them back in the user_message payload.
                rows[idx] = Row(
                    id: rows[idx].id,
                    kind: "user",
                    text: text,
                    timestamp: timestamp,
                    messageId: msgId,
                    tool: nil,
                    images: rows[idx].images
                )
                return
            }

            if let idx = rows.lastIndex(where: {
                isOptimisticUserEchoCandidate($0, text: text, echoTimestamp: timestamp)
            }) {
                rows[idx] = Row(
                    id: rows[idx].id,
                    kind: "user",
                    text: text,
                    timestamp: timestamp,
                    messageId: msgId ?? rows[idx].messageId,
                    tool: nil,
                    images: rows[idx].images
                )
                return
            }

            // Also dedup against rows already loaded from fetchTimeline
            // (which carry entry-xxx ids but the same messageId). Without
            // this check, text-only new conversations show the user message
            // twice: once from loadInitial() and once from the stream echo.
            if let msgId {
                if rows.contains(where: { $0.messageId == msgId }) {
                    return
                }
            } else {
                // If msgId is nil (initial prompt of a new agent), match by text and proximity
                if let lastUser = rows.last(where: { $0.kind == "user" }),
                   lastUser.text == text,
                   let t1 = lastUser.timestamp.flatMap({ ISO8601DateFormatter().date(from: $0) }),
                   let t2 = ISO8601DateFormatter().date(from: timestamp),
                   abs(t2.timeIntervalSince(t1)) < 600 {
                    return
                }
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
            messageId: messageId(from: item),
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

    private func isOptimisticUserEchoCandidate(_ row: Row, text: String, echoTimestamp: String) -> Bool {
        guard row.kind == "user",
              row.id.hasPrefix("msg-"),
              row.text == text else { return false }

        guard let rowTimestamp = row.timestamp,
              let sentAt = ISO8601DateFormatter().date(from: rowTimestamp),
              let echoedAt = ISO8601DateFormatter().date(from: echoTimestamp) else {
            return true
        }
        return abs(echoedAt.timeIntervalSince(sentAt)) < 600
    }

    private func toolInfo(from item: TimelineItem) -> ToolInfo? {
        if case let .toolCall(name, status, _, detail) = item {
            return ToolInfo.from(name: name, status: status, detail: detail)
        }
        return nil
    }

    private func messageId(from item: TimelineItem) -> String? {
        if case let .userMessage(_, messageId) = item {
            return messageId
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
        guard !rows.contains(where: { $0.kind == "user" && $0.text == text }) else { return }
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
    func reconcileAgentStatus(_ status: String, updatedAt: Date? = nil) {
        if status == "running" {
            if !isAgentWorking {
                EventLogger.shared.log("turn", "reconciled_running", [
                    "agent": agentId
                ])
                isAgentWorking = true
            }
            if turnStartedAt == nil {
                turnStartedAt = updatedAt ?? Date()
            }
        } else if status == "idle" && isAgentWorking {
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
                        timestamp: rows[idx].timestamp, messageId: rows[idx].messageId,
                        tool: rows[idx].tool,
                        images: rows[idx].images, modelUsed: model, durationSec: dur
                    )
                }
                if let seq = seqFromId(rows[idx].id) {
                    metaCache[seq] = TurnMeta(model: rows[idx].modelUsed, duration: dur)
                    saveMetaCache()
                }
            }
            currentTurnModel = nil
            populateHistoricalDurations()
        }
    }

    func populateHistoricalDurations() {
        let formatterFull = ISO8601DateFormatter()
        formatterFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func parseTS(_ s: String?) -> Date? {
            guard let s else { return nil }
            return formatterFull.date(from: s) ?? ISO8601DateFormatter().date(from: s)
        }

        var currentUserAt: Date? = nil
        var currentLastItemAt: Date? = nil
        var turnRowIndices: [Int] = []

        func flushTurn() {
            guard let start = currentUserAt, let end = currentLastItemAt, !turnRowIndices.isEmpty else {
                turnRowIndices.removeAll()
                return
            }
            let dur = max(0, end.timeIntervalSince(start))
            
            // Stamp duration on the last row of the turn (interrupted/errored/completed)
            if let lastIdx = turnRowIndices.last, lastIdx < rows.count {
                rows[lastIdx].durationSec = dur
            }
            
            // Also stamp duration on any assistant rows in this turn
            for idx in turnRowIndices {
                if idx < rows.count && rows[idx].kind == "assistant" {
                    rows[idx].durationSec = dur
                }
            }
            turnRowIndices.removeAll()
        }

        for i in 0..<rows.count {
            let row = rows[i]
            if row.kind == "user" {
                flushTurn()
                currentUserAt = parseTS(row.timestamp)
                currentLastItemAt = nil
            } else if currentUserAt != nil {
                if let ts = parseTS(row.timestamp) {
                    currentLastItemAt = ts
                }
                turnRowIndices.append(i)
            }
        }
        if !isAgentWorking {
            flushTurn()
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
        guard !rows.contains(where: { $0.id == id }) else { return }
        rows.append(Row(
            id: id,
            kind: "user",
            text: text,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            messageId: messageId,
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
            messageId: nil,
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
            messageId: nil,
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
            messageId: nil,
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

    private func sendNotification(title: String, body: String) {
        #if os(macOS)
        // Only suppress the notification when the user is both looking at
        // the app AND already has THIS agent's conversation open — the app
        // being merely frontmost (e.g. viewing a different agent) must not
        // swallow the alert, or an AskUserQuestion/permission ask on a
        // background agent goes completely unnoticed. 2026.07.15 Naron
        if NSApplication.shared.isActive && (getIsSelected?() ?? false) { return }
        #endif
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func cleanToolNameForSummary(_ name: String) -> String {
        let firstLine = name.split(separator: "\n").first.map(String.init) ?? name
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 20 {
            return String(trimmed.prefix(17)) + "..."
        }
        return trimmed
    }

    var activeStatusText: String? {
        guard isAgentWorking else { return nil }
        if let lastRow = rows.last {
            if lastRow.kind == "tool", let tool = lastRow.tool, tool.status == "running" {
                let name = cleanToolNameForSummary(tool.name)
                let targetText = tool.target.map { s in
                    let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    return " (\(clean.count > 24 ? String(clean.prefix(24)) + "..." : clean))"
                } ?? ""
                return "Running: \(name)\(targetText)..."
            } else if lastRow.kind == "reasoning" {
                return "Thinking..."
            } else if lastRow.kind == "assistant" {
                return "Replying..."
            } else if lastRow.kind == "compaction" {
                return "Compacting..."
            } else if lastRow.kind == "permission" || lastRow.kind == "attention" {
                return "Waiting for authorization..."
            }
        }
        return "Thinking..."
    }

    var liveConsoleLines: [String] {
        guard isAgentWorking else { return [] }
        if let lastRow = rows.last {
            if lastRow.kind == "tool", let tool = lastRow.tool, tool.status == "running" {
                let detail = tool.detailPlain.trimmingCharacters(in: .whitespacesAndNewlines)
                if !detail.isEmpty {
                    let lines = detail.split(separator: "\n").map(String.init)
                    return Array(lines.suffix(4))
                }
                let targetStr = tool.target ?? ""
                return ["$ \(tool.name) \(targetStr)"]
            } else if lastRow.kind == "reasoning" {
                return ["Thinking: \(lastRow.text)"]
            } else if lastRow.kind == "assistant" {
                return [lastRow.text]
            }
        }
        return ["Thinking..."]
    }
}
