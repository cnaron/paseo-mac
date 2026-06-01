import SwiftUI
import AppKit

// MARK: - Transcript (AppKit NSTableView) — the stability fix
//
// Rows are `TurnGroup`s (from the reused `groupTurns`). The table owns scrolling
// and row lifecycle, so reconnects / streaming update rows in place WITHOUT
// re-evaluating a giant SwiftUI tree or losing scroll position. Each row hosts the
// existing SwiftUI bubble (`UserTurnView` / `AssistantTurnView`) via NSHostingView.

struct TurnEnv {
    let settings: SettingsStore
    let accent: AccentPalette
    let workspaceCwd: String?
    let bubbleGap: CGFloat
    let onOpenFile: (String) -> Void
    let pendingPermission: PermissionRequestPayload?
    let resolvedIds: Set<String>
    let onAllow: () -> Void
    let onDeny: () -> Void
    let onSubmitAnswers: ([String: String]) -> Void
}

final class TranscriptVC: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let app: AppViewModel
    let settings: SettingsStore
    let onOpenFile: (String) -> Void

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private var emptyHost: NSHostingView<AnyView>!

    private var groups: [TurnGroup] = []
    private weak var boundVM: ConversationViewModel?
    private var agentProvider: String?
    private var workspaceCwd: String?
    private var pending = false
    /// Dedicated controller used to measure SwiftUI bubble heights for
    /// `heightOfRow`. NSHostingController.sizeThatFits(in:) is the supported
    /// way to measure SwiftUI content without it being in a window tree.
    private lazy var measuringController = NSHostingController(rootView: AnyView(EmptyView()))
    private var lastWidth: CGFloat = 0
    /// Per-group height cache. Key is group.id (stable across row index shifts
    /// that happen when new messages are inserted above). Populated by
    /// SizingHostingView.onHeightInvalidated, which fires *after* SwiftUI layout.
    /// Cleared for a specific group whenever its content changes (reconfigure).
    private var rowHeightCache: [String: CGFloat] = [:]
    /// 30-fps streaming throttle: fires at most once per 33 ms during streaming.
    private var throttleTimer: Timer?
    private var pendingReconfigRow: Int?
    /// Keeps the scroll pinned to the bottom during streaming.
    private var autoScroll = true
    /// True while the user is in the middle of a trackpad/mouse scroll gesture.
    /// During this window we skip synchronous sizeThatFits so the main thread
    /// stays free; liveScrollEnded re-measures any rows that got placeholder heights.
    private var isLiveScrolling = false
    /// Observable state shared with the scroll-to-bottom button overlay.
    let scrollState = TranscriptScrollState()

    init(app: AppViewModel, settings: SettingsStore, onOpenFile: @escaping (String) -> Void) {
        self.app = app
        self.settings = settings
        self.onOpenFile = onOpenFile
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        tableView.headerView = nil
        tableView.backgroundColor = .white
        tableView.selectionHighlightStyle = .none
        tableView.usesAutomaticRowHeights = false  // manual heightOfRow — see below
        tableView.rowHeight = 80
        tableView.intercellSpacing = NSSize(width: 0, height: CGFloat(settings.bubbleGapPt))
        tableView.dataSource = self
        tableView.delegate = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("turn"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        // Pin scroll to bottom when the document frame grows (row added/taller).
        tableView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(tableFrameChanged),
            name: NSView.frameDidChangeNotification, object: tableView
        )

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 26, left: 0, bottom: 20, right: 0)
        // Track user-initiated live scroll: start → stop auto-scroll + skip measurement;
        // end → re-measure any visible rows that got placeholder heights.
        NotificationCenter.default.addObserver(
            self, selector: #selector(userDidLiveScroll),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveScrollEnded),
            name: NSScrollView.didEndLiveScrollNotification, object: scrollView
        )

        emptyHost = NSHostingView(rootView: AnyView(EmptyView()))
        emptyHost.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        container.addSubview(emptyHost)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            emptyHost.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyHost.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyHost.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor),
        ])
        view = container
    }

    // MARK: binding & observation

    /// restoreY: if provided, restore the scroll position instead of jumping to bottom.
    func bind(vm: ConversationViewModel?, agentProvider: String?, workspaceCwd: String?,
              pending: Bool, restoreY: CGFloat? = nil) {
        throttleTimer?.invalidate(); throttleTimer = nil; pendingReconfigRow = nil
        self.boundVM = vm
        self.agentProvider = agentProvider
        self.workspaceCwd = workspaceCwd
        self.pending = pending
        rebuild(restoreY: restoreY)
        observe()
    }

    /// Expose scroll Y so ConversationVC can save it before switching agents.
    var currentScrollY: CGFloat { scrollView.contentView.documentVisibleRect.minY }

    /// Restore a saved scroll Y (called after a rebuild).
    func restoreScroll(_ y: CGFloat) {
        guard let docView = scrollView.documentView else { return }
        let maxY = max(0, docView.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(y, maxY)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        autoScroll = isAtBottom()
        scrollState.isAtBottom = autoScroll
    }

    func scrollToBottomPublic() { scrollToBottom() }

    private func observe() {
        guard let vm = boundVM else { updateEmpty(); return }
        withObservationTracking {
            _ = vm.rows
            _ = vm.isAgentWorking
            _ = vm.pendingPermission
            _ = vm.resolvedPermissionIds
        } onChange: { [weak self, weak vm] in
            DispatchQueue.main.async {
                guard let self, self.boundVM === vm else { return }
                self.applyUpdate()
                self.observe()
            }
        }
    }

    private func rebuild(restoreY: CGFloat? = nil) {
        rowHeightCache.removeAll()
        groups = boundVM.map { groupsForDisplay(groupTurns($0.rows, provider: agentProvider), vm: $0) } ?? []
        tableView.reloadData()
        updateEmpty()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let y = restoreY { self.restoreScroll(y) } else { self.scrollToBottom() }
        }
    }

    /// Appends a transient "working" placeholder group when the agent has
    /// started a turn but no assistant row exists yet, so the user sees
    /// "Working…" immediately after sending rather than blank space.
    private func groupsForDisplay(_ base: [TurnGroup], vm: ConversationViewModel) -> [TurnGroup] {
        guard vm.isAgentWorking, base.last?.isUser == true || base.isEmpty else { return base }
        var placeholder = TurnGroup(id: "__working__", isUser: false, provider: agentProvider)
        placeholder.isActive = true
        placeholder.turnStartedAt = vm.turnStartedAt
        placeholder.modelUsed = vm.currentDisplayModel
        placeholder.timestamp = vm.turnStartedAt.map { ISO8601DateFormatter().string(from: $0) }
        return base + [placeholder]
    }

    private func applyUpdate() {
        guard let vm = boundVM else { groups = []; tableView.reloadData(); updateEmpty(); return }
        let old = groups
        let new = groupsForDisplay(groupTurns(vm.rows, provider: agentProvider), vm: vm)
        let oldIds = old.map(\.id), newIds = new.map(\.id)
        let atBottom = isAtBottom()
        groups = new

        if oldIds == newIds {
            // Streaming: throttle to 30 fps so AnyView doesn't rebuild every token.
            if let last = new.indices.last { scheduleReconfigure(row: last) }
        } else if newIds.starts(with: oldIds) {
            tableView.beginUpdates()
            if !oldIds.isEmpty { doReconfigure(row: oldIds.count - 1) }
            tableView.insertRows(at: IndexSet(oldIds.count..<newIds.count), withAnimation: [])
            tableView.endUpdates()
        } else {
            rowHeightCache.removeAll()
            tableView.reloadData()
        }
        updateEmpty()
        if atBottom { scrollToBottom() }
    }

    /// Throttled reconfigure: fires immediately on first call, then at most 30 fps.
    /// This prevents AnyView's full-tree rebuild from running on every streaming token.
    private func scheduleReconfigure(row: Int) {
        if throttleTimer == nil {
            doReconfigure(row: row)
            throttleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: false) { [weak self] _ in
                self?.throttleTimer = nil
                if let r = self?.pendingReconfigRow {
                    self?.pendingReconfigRow = nil
                    self?.scheduleReconfigure(row: r)
                }
            }
        } else {
            pendingReconfigRow = row  // will be drained when timer fires
        }
    }

    /// Immediate (non-throttled) cell update — used for structural changes.
    private func doReconfigure(row: Int) {
        guard row >= 0, row < groups.count else { return }
        // Content changed → its cached height is stale. Drop the entry so the
        // next heightOfRow re-measures via measuringHost; SizingHostingView's
        // post-layout callback will repopulate with the accurate value.
        rowHeightCache.removeValue(forKey: groups[row].id)
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TurnCellView {
            cell.configure(group: displayGroup(row), env: makeEnv())
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        } else {
            tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        }
    }

    // MARK: data source / delegate

    func numberOfRows(in tableView: NSTableView) -> Int { groups.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("turn")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? TurnCellView) ?? TurnCellView(reuseID: id)
        cell.configure(group: displayGroup(row), env: makeEnv())
        // SizingHostingView fires this after SwiftUI layout completes — the cell's
        // fittingSize is accurate here. Cache it by group.id (stable across row
        // index shifts), then tell the table to re-pull the row's height.
        cell.onHeightInvalidated = { [weak self, weak cell, weak tableView] in
            guard let self, let cell, let tableView else { return }
            let r = tableView.row(for: cell)
            guard r >= 0, r < self.groups.count else { return }
            // Re-measure with sizeThatFits rather than intrinsicContentSize.
            // NSHostingView.intrinsicContentSize is unreliable for views that
            // use .frame(maxWidth: .infinity) — it can under-report the height
            // and cause the row to shrink below its actual content size,
            // clipping the completion pill and last lines of text.
            let w = max(tableView.bounds.width, 1)
            self.measuringController.rootView = AnyView(makeTurnBubble(self.displayGroup(r), self.makeEnv()))
            let h = max(self.measuringController.sizeThatFits(in: NSSize(width: w, height: 100_000)).height, 1)
            let cached = self.rowHeightCache[self.groups[r].id]
            self.rowHeightCache[self.groups[r].id] = h
            if cached.map({ abs($0 - h) > 0.5 }) ?? true {
                tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: r))
            }
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }
    func selectionShouldChange(in tableView: NSTableView) -> Bool { false }

    /// Height comes from the per-group cache (key = group.id), populated by
    /// SizingHostingView after SwiftUI layout. For first-render rows outside
    /// a live-scroll gesture, measure via NSHostingController.sizeThatFits —
    /// the only reliable way to size SwiftUI content not in a window tree.
    /// During live scroll we return a cheap estimate so the main thread stays
    /// free; liveScrollEnded corrects any placeholder heights.
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row >= 0, row < groups.count else { return 1 }
        let key = groups[row].id
        if let cached = rowHeightCache[key] { return cached }
        if isLiveScrolling {
            // Don't cache — onHeightInvalidated will supply the real value once
            // the hosted SwiftUI view has rendered.
            return groups[row].isUser ? 90 : 140
        }
        let w = max(tableView.bounds.width, 1)
        measuringController.rootView = AnyView(makeTurnBubble(displayGroup(row), makeEnv()))
        let size = measuringController.sizeThatFits(in: NSSize(width: w, height: 100_000))
        let h = max(size.height, 1)
        rowHeightCache[key] = h
        return h
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let w = tableView.bounds.width
        if abs(w - lastWidth) > 0.5, groups.count > 0 {
            lastWidth = w
            // Clear cache — all rows need re-measuring at the new width.
            rowHeightCache.removeAll()
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<groups.count))
        }
    }

    // MARK: helpers

    /// Mark the last in-progress turn as active (shows elapsed TurnPill + closes
    /// dangling code fences live in MDView).
    private func displayGroup(_ row: Int) -> TurnGroup {
        var g = groups[row]
        let isLast = row == groups.count - 1
        if isLast, !g.isUser, boundVM?.isAgentWorking == true {
            g.isActive = true
            g.turnStartedAt = boundVM?.turnStartedAt
            if !g.blocks.isEmpty, case .markdown(let id, let t, _) = g.blocks[g.blocks.count - 1] {
                g.blocks[g.blocks.count - 1] = .markdown(id, text: t, streaming: true)
            }
        }
        return g
    }

    private func makeEnv() -> TurnEnv {
        let vm = boundVM
        return TurnEnv(
            settings: settings,
            accent: settings.accentPalette,
            workspaceCwd: workspaceCwd,
            bubbleGap: CGFloat(settings.bubbleGapPt),
            onOpenFile: onOpenFile,
            pendingPermission: vm?.pendingPermission,
            resolvedIds: vm?.resolvedPermissionIds ?? [],
            onAllow: { [weak vm] in Task { await vm?.approvePermission() } },
            onDeny: { [weak vm] in Task { await vm?.denyPermission() } },
            onSubmitAnswers: { [weak vm] ans in Task { await vm?.submitQuestionAnswers(ans) } }
        )
    }

    private func updateEmpty() {
        let empty = groups.isEmpty
        emptyHost.isHidden = !empty
        if empty {
            emptyHost.rootView = AnyView(
                TranscriptEmptyView(pending: pending)
                    .environment(app).environment(settings).environment(\.accent, settings.accentPalette)
            )
        }
    }

    private func isAtBottom() -> Bool {
        let visible = scrollView.contentView.documentVisibleRect
        let docHeight = (scrollView.documentView?.bounds.height ?? 0)
        return visible.maxY >= docHeight - 120
    }

    private func scrollToBottom() {
        guard let docView = scrollView.documentView else { return }
        let maxY = max(0, docView.bounds.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        autoScroll = true
        scrollState.isAtBottom = true
    }

    /// NSTableView frame grew. If autoScroll is on, pin to the new bottom immediately.
    @objc private func tableFrameChanged() {
        guard autoScroll else { return }
        scrollToBottom()
    }

    /// User started a live scroll — pause measurement and stop auto-scroll if scrolling up.
    @objc private func userDidLiveScroll() {
        isLiveScrolling = true
        autoScroll = isAtBottom()
        scrollState.isAtBottom = autoScroll
    }

    /// Scroll gesture ended — measure any visible rows that got placeholder heights.
    @objc private func liveScrollEnded() {
        isLiveScrolling = false
        let range = tableView.rows(in: tableView.visibleRect)
        guard range.length > 0 else { return }
        let w = max(tableView.bounds.width, 1)
        var stale = IndexSet()
        for r in range.location ..< (range.location + range.length) {
            guard r >= 0, r < groups.count, rowHeightCache[groups[r].id] == nil else { continue }
            measuringController.rootView = AnyView(makeTurnBubble(displayGroup(r), makeEnv()))
            let h = max(measuringController.sizeThatFits(in: NSSize(width: w, height: 100_000)).height, 1)
            rowHeightCache[groups[r].id] = h
            stale.insert(r)
        }
        if !stale.isEmpty { tableView.noteHeightOfRows(withIndexesChanged: stale) }
    }
}

// MARK: - Observable scroll state (shared with the scroll-to-bottom button overlay)

@Observable
final class TranscriptScrollState {
    var isAtBottom: Bool = true
}

// MARK: - Hosted turn cell

/// NSHostingView subclass that fires `onSizeInvalidated` whenever SwiftUI
/// signals that the hosted content wants a different size. This lets
/// NSTableView re-measure the row height after user interactions like
/// disclosure toggles that change content height inside the cell.
final class SizingHostingView: NSHostingView<AnyView> {
    var onSizeInvalidated: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        // Defer out of any active layout pass to avoid re-entrant table updates.
        DispatchQueue.main.async { [weak self] in self?.onSizeInvalidated?() }
    }
}

final class TurnCellView: NSTableCellView {
    private let hosting: SizingHostingView
    /// Set by TranscriptVC; called when SwiftUI content height changes.
    var onHeightInvalidated: (() -> Void)?

    init(reuseID: NSUserInterfaceItemIdentifier) {
        hosting = SizingHostingView(rootView: AnyView(EmptyView()))
        super.init(frame: .zero)
        self.identifier = reuseID
        // CRITICAL: clip subviews so any height-mis-estimate during streaming
        // does NOT bleed the SwiftUI content across the next row's frame.
        self.wantsLayer = true
        self.layer?.masksToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 13.0, *) { hosting.sizingOptions = [.intrinsicContentSize] }
        addSubview(hosting)
        // Pin top/leading/trailing only — hosting's bottom is free, its height
        // comes from SwiftUI's intrinsicContentSize. A bottomAnchor == cell
        // bottom constraint would stretch the host (or compress it) and force
        // SwiftUI to paint outside its own frame, causing the overlap visuals.
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        hosting.onSizeInvalidated = { [weak self] in self?.onHeightInvalidated?() }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(group: TurnGroup, env: TurnEnv) {
        hosting.rootView = makeTurnBubble(group, env)
    }

    /// Post-SwiftUI-layout height — accurate when called from onHeightInvalidated.
    var fittingHeight: CGFloat { max(hosting.intrinsicContentSize.height, 1) }
}

// MARK: - shared bubble builder (cell render + height measurement use one tree)

@MainActor
func makeTurnBubble(_ g: TurnGroup, _ env: TurnEnv) -> AnyView {
    AnyView(
        Group {
            if g.isUser {
                UserTurnView(group: g, onOpenFile: env.onOpenFile)
            } else {
                AssistantTurnView(
                    group: g, isStreaming: false, workspaceCwd: env.workspaceCwd, onOpenFile: env.onOpenFile,
                    pendingPermission: env.pendingPermission, resolvedIds: env.resolvedIds,
                    onAllow: env.onAllow, onDeny: env.onDeny, onSubmitAnswers: env.onSubmitAnswers
                )
            }
        }
        .frame(maxWidth: DS.transcriptMaxW, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .center)
        .environment(env.settings)
        .environment(\.accent, env.accent)
    )
}

// MARK: - Empty / pending overlay

private struct TranscriptEmptyView: View {
    let pending: Bool
    @Environment(AppViewModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            if pending {
                if let err = app.creatingAgentError {
                    DSIcon(name: "alert", size: 28).foregroundStyle(DS.orange)
                    Text("无法启动会话").font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.text)
                    Text(err).font(.system(size: 13)).foregroundStyle(DS.text2).multilineTextAlignment(.center).padding(.horizontal, 40)
                } else if let text = app.creatingAgentText {
                    UserTurnView(group: TurnGroup(id: "creating", isUser: true, text: text, images: app.creatingAgentImages))
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在启动会话…").font(.system(size: 13)).foregroundStyle(DS.text2) }
                } else {
                    DSIcon(name: "chat", size: 34, weight: .light).foregroundStyle(DS.text3)
                    Text("输入消息开始对话").font(.system(size: 14)).foregroundStyle(DS.text2)
                }
            } else {
                DSIcon(name: "chat", size: 32, weight: .light).foregroundStyle(DS.text3)
                Text(app.connectionState == .connected ? "从侧栏选择一个会话" : "未连接")
                    .font(.system(size: 14)).foregroundStyle(DS.text2)
            }
        }
        .frame(maxWidth: 520)
    }
}
