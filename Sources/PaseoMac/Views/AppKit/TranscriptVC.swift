import SwiftUI
import AppKit

// MARK: - Transcript (NSScrollView + NSStackView) — no manual height measurement
//
// Each TurnGroup gets one NSHostingView<AnyView> in a vertical NSStackView.
// Heights are handled entirely by SwiftUI + Auto Layout via .preferredContentSize —
// no sizeThatFits callback, no heightOfRow, no noteHeightOfRows from our code.
// Streaming is an in-place rootView update on the last hosting view; the stack
// re-layouts automatically.

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

final class TranscriptVC: NSViewController {
    let app: AppViewModel
    let settings: SettingsStore
    let onOpenFile: (String) -> Void

    private let scrollView = NSScrollView()
    private let documentView = TranscriptDocumentView()
    private let stackView = NSStackView()
    private var emptyHost: NSHostingView<AnyView>!

    private var groups: [TurnGroup] = []
    private weak var boundVM: ConversationViewModel?
    private var agentProvider: String?
    private var workspaceCwd: String?
    private var pending = false

    // Streaming throttle: at most 30 fps rootView updates.
    private var throttleTimer: Timer?
    private var pendingStreamingUpdate = false

    // Auto-scroll: follow bottom while agent is working.
    private var autoScroll = true
    let scrollState = TranscriptScrollState()

    // Per-turn hosting views, in insertion order.
    private var orderedHostIds: [String] = []
    private var hostMap: [String: NSHostingView<AnyView>] = [:]

    init(app: AppViewModel, settings: SettingsStore, onOpenFile: @escaping (String) -> Void) {
        self.app = app
        self.settings = settings
        self.onOpenFile = onOpenFile
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        // Stack view: vertical, fills full width, spacing between turns.
        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 0
        stackView.edgeInsets = NSEdgeInsets(top: 26, left: 0, bottom: 20, right: 0)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        documentView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: documentView.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stackView.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        NotificationCenter.default.addObserver(
            self, selector: #selector(userDidLiveScroll),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView
        )

        emptyHost = NSHostingView(rootView: AnyView(EmptyView()))
        emptyHost.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.white.cgColor
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

    override func viewDidLoad() {
        super.viewDidLoad()
        // Constrain document view width to the scroll view's visible content area.
        // This is what gives each NSHostingView a definite width so SwiftUI can
        // compute the correct wrapped-text height via .preferredContentSize.
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        // When the document view grows (new turn added), scroll to bottom if pinned.
        documentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(documentFrameChanged),
            name: NSView.frameDidChangeNotification, object: documentView
        )
    }

    // MARK: binding & observation

    func bind(vm: ConversationViewModel?, agentProvider: String?, workspaceCwd: String?,
              pending: Bool, restoreY: CGFloat? = nil) {
        throttleTimer?.invalidate(); throttleTimer = nil; pendingStreamingUpdate = false
        self.boundVM = vm
        self.agentProvider = agentProvider
        self.workspaceCwd = workspaceCwd
        self.pending = pending
        rebuild(restoreY: restoreY)
        observe()
    }

    var currentScrollY: CGFloat { scrollView.contentView.documentVisibleRect.minY }

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
                self.scheduleApplyUpdate()
                self.observe()
            }
        }
    }

    // MARK: rebuild & update

    private func rebuild(restoreY: CGFloat? = nil) {
        clearHosts()
        groups = boundVM.map { groupsForDisplay(groupTurns($0.rows, provider: agentProvider), vm: $0) } ?? []
        let env = makeEnv()
        for group in groups { appendHost(for: group, env: env) }
        updateEmpty()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let y = restoreY { self.restoreScroll(y) } else { self.scrollToBottom() }
        }
    }

    private func scheduleApplyUpdate() {
        if throttleTimer == nil {
            applyUpdate()
            throttleTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: false) { [weak self] _ in
                self?.throttleTimer = nil
                if self?.pendingStreamingUpdate == true {
                    self?.pendingStreamingUpdate = false
                    self?.scheduleApplyUpdate()
                }
            }
        } else {
            pendingStreamingUpdate = true
        }
    }

    private func applyUpdate() {
        guard let vm = boundVM else { clearHosts(); updateEmpty(); return }
        let new = groupsForDisplay(groupTurns(vm.rows, provider: agentProvider), vm: vm)
        let newIds = new.map(\.id)
        let oldIds = orderedHostIds
        let atBottom = isAtBottom()
        groups = new
        let env = makeEnv()

        if oldIds == newIds {
            // Streaming update: refresh the last hosting view in place.
            // No layout pass is triggered on other rows.
            if let last = new.last, let host = hostMap[last.id] {
                host.rootView = AnyView(makeTurnBubble(displayGroup(new.count - 1), env))
            }
        } else if newIds.starts(with: oldIds) {
            // One or more new turns appended.
            if let lastOldIdx = oldIds.indices.last {
                hostMap[oldIds[lastOldIdx]]?.rootView =
                    AnyView(makeTurnBubble(displayGroup(lastOldIdx), env))
            }
            for i in oldIds.count ..< new.count {
                appendHost(for: new[i], env: env)
            }
        } else {
            // Structural change (e.g. rewind, reconnect).
            rebuild()
            return
        }

        updateEmpty()
        if atBottom { scrollToBottom() }
    }

    // MARK: host management

    private func appendHost(for group: TurnGroup, env: TurnEnv) {
        let host = NSHostingView(rootView: AnyView(makeTurnBubble(group, env)))
        host.sizingOptions = [.preferredContentSize]
        host.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(host)
        // Pin to full stack width so SwiftUI wraps text at the correct column.
        host.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        orderedHostIds.append(group.id)
        hostMap[group.id] = host
    }

    private func clearHosts() {
        for view in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        orderedHostIds.removeAll()
        hostMap.removeAll()
    }

    // MARK: helpers

    private func groupsForDisplay(_ base: [TurnGroup], vm: ConversationViewModel) -> [TurnGroup] {
        guard vm.isAgentWorking, base.last?.isUser == true || base.isEmpty else { return base }
        var placeholder = TurnGroup(id: "__working__", isUser: false, provider: agentProvider)
        placeholder.isActive = true
        placeholder.turnStartedAt = vm.turnStartedAt
        placeholder.modelUsed = vm.currentDisplayModel
        placeholder.timestamp = vm.turnStartedAt.map { ISO8601DateFormatter().string(from: $0) }
        return base + [placeholder]
    }

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
        let docHeight = scrollView.documentView?.bounds.height ?? 0
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

    @objc private func documentFrameChanged() {
        guard autoScroll else { return }
        scrollToBottom()
    }

    @objc private func userDidLiveScroll() {
        autoScroll = isAtBottom()
        scrollState.isAtBottom = autoScroll
    }
}

// MARK: - Flipped coordinate system (y=0 at top, content grows downward)

private final class TranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Observable scroll state

@Observable
final class TranscriptScrollState {
    var isAtBottom: Bool = true
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
                    Text(err).font(.system(size: 13)).foregroundStyle(DS.text2)
                        .multilineTextAlignment(.center).padding(.horizontal, 40)
                } else if let text = app.creatingAgentText {
                    UserTurnView(group: TurnGroup(id: "creating", isUser: true, text: text, images: app.creatingAgentImages))
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在启动会话…").font(.system(size: 13)).foregroundStyle(DS.text2)
                    }
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

// MARK: - Shared bubble builder (same SwiftUI views as before)

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
