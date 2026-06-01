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
        // Auto heights: NSTableView measures each row via its NSHostingView's
        // intrinsicContentSize (reported by SizingHostingView via Auto Layout).
        // This eliminates the two-step stale-measurement → correction jitter
        // that happened with manual noteHeightOfRows + measuringHost.
        tableView.usesAutomaticRowHeights = true
        tableView.intercellSpacing = NSSize(width: 0, height: CGFloat(settings.bubbleGapPt))
        tableView.dataSource = self
        tableView.delegate = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("turn"))
        col.resizingMask = .autoresizingMask
        tableView.addTableColumn(col)
        // Observe frame changes to synchronously pin scroll to bottom when the
        // document grows (new content / row height increase from streaming).
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

    func bind(vm: ConversationViewModel?, agentProvider: String?, workspaceCwd: String?, pending: Bool) {
        self.boundVM = vm
        self.agentProvider = agentProvider
        self.workspaceCwd = workspaceCwd
        self.pending = pending
        rebuild()
        observe()
    }

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

    private func rebuild() {
        groups = boundVM.map { groupsForDisplay(groupTurns($0.rows, provider: agentProvider), vm: $0) } ?? []
        tableView.reloadData()
        updateEmpty()
        DispatchQueue.main.async { [weak self] in self?.scrollToBottom() }
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
            if let last = new.indices.last { reconfigure(row: last) }
        } else if newIds.starts(with: oldIds) {
            tableView.beginUpdates()
            if !oldIds.isEmpty { reconfigure(row: oldIds.count - 1) }
            tableView.insertRows(at: IndexSet(oldIds.count..<newIds.count), withAnimation: [])
            tableView.endUpdates()
        } else {
            tableView.reloadData()
        }
        updateEmpty()
        // tableFrameChanged handles scroll during streaming; call here as
        // a fallback for cases where the frame may not change (same height).
        if atBottom { scrollToBottom() }
    }

    /// Update one cell's hosted SwiftUI tree in place (no recreation, no flicker).
    private func reconfigure(row: Int) {
        guard row >= 0, row < groups.count else { return }
        if let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TurnCellView {
            cell.configure(group: displayGroup(row), env: makeEnv())
            // Do NOT call noteHeightOfRows here. SizingHostingView fires
            // invalidateIntrinsicContentSize() once SwiftUI layout settles,
            // then onHeightInvalidated calls noteHeightOfRows with the real
            // height. Calling it synchronously now would use a stale
            // measuringHost result — wrong height → immediate correction →
            // two-frame jump on every streaming token.
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
        // When the cell's SwiftUI content changes height (e.g. disclosure toggle),
        // ask NSTableView to re-measure just that row.
        cell.onHeightInvalidated = { [weak self, weak cell, weak tableView] in
            guard let self, let cell, let tableView else { return }
            let r = tableView.row(for: cell)
            guard r >= 0 else { return }
            tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: r))
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { false }
    func selectionShouldChange(in tableView: NSTableView) -> Bool { false }

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
    }

    /// Fires when NSTableView's frame grows (row height changed or rows added).
    /// Synchronously pins scroll to bottom so there is no per-frame lag between
    /// content growth and viewport position — this is what prevents the stutter.
    @objc private func tableFrameChanged() {
        guard let docView = scrollView.documentView else { return }
        let docH = docView.bounds.height
        let viewH = scrollView.contentView.bounds.height
        let scrollY = scrollView.contentView.documentVisibleRect.minY
        // Stay pinned if we were within one generous row-height of the bottom.
        if docH - viewH - scrollY < 400 {
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, docH - viewH)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
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
        hosting.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 13.0, *) { hosting.sizingOptions = [.intrinsicContentSize] }
        addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.topAnchor.constraint(equalTo: topAnchor),
            hosting.bottomAnchor.constraint(equalTo: bottomAnchor),
            hosting.leadingAnchor.constraint(equalTo: leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        hosting.onSizeInvalidated = { [weak self] in self?.onHeightInvalidated?() }
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(group: TurnGroup, env: TurnEnv) {
        hosting.rootView = makeTurnBubble(group, env)
    }
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
