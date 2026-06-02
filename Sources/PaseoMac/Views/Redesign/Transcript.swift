import AppKit
import SwiftUI

private struct TranscriptBottomOffsetKey: PreferenceKey {
    static let defaultValue = CGFloat.greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Observes only user-driven live scrolling from SwiftUI's enclosing
/// NSScrollView. Content growth can move the bottom marker away from the
/// viewport before our trailing scroll runs, so geometry alone cannot decide
/// whether bottom-following should stop.
private struct TranscriptLiveScrollMonitor: NSViewRepresentable {
    let onUserScroll: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onUserScroll: onUserScroll) }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { context.coordinator.attach(from: view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onUserScroll = onUserScroll
        DispatchQueue.main.async { context.coordinator.attach(from: view) }
    }

    final class Coordinator {
        var onUserScroll: () -> Void
        private weak var scrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []

        init(onUserScroll: @escaping () -> Void) {
            self.onUserScroll = onUserScroll
        }

        deinit { detach() }

        func attach(from view: NSView) {
            guard let scrollView = view.enclosingScrollView else { return }
            guard self.scrollView !== scrollView else { return }
            detach()
            self.scrollView = scrollView
            let center = NotificationCenter.default
            for name in [NSScrollView.didLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                observers.append(center.addObserver(forName: name, object: scrollView, queue: .main) { [weak self] _ in
                    self?.onUserScroll()
                })
            }
        }

        private func detach() {
            let center = NotificationCenter.default
            for observer in observers { center.removeObserver(observer) }
            observers.removeAll()
            scrollView = nil
        }
    }
}

// MARK: - Row → turn grouping
//
// Coalesces the VM's streamed rows into visual turns: consecutive assistant /
// reasoning chunks merge; consecutive tool calls collapse into one cluster (with
// the daemon's running→completed lifecycle fold). Ported from the prior
// ConversationView grouping, restructured to the design's turn/sub-block shape.

func groupTurns(_ rows: [ConversationViewModel.Row], provider: String?) -> [TurnGroup] {
    var out: [TurnGroup] = []
    var current: TurnGroup?

    func flush() { if let c = current { out.append(c); current = nil } }

    for row in rows {
        if row.kind == "user" {
            flush()
            out.append(TurnGroup(id: row.id, isUser: true, text: row.text,
                                 timestamp: row.timestamp, messageId: row.messageId, images: row.images))
            continue
        }
        if current == nil {
            current = TurnGroup(id: "turn-\(row.id)", isUser: false, timestamp: row.timestamp, provider: provider)
        }
        appendBlock(row, into: &current!)
        if let m = row.modelUsed { current!.modelUsed = m }
        if let d = row.durationSec { current!.durationSec = d }
    }
    flush()
    return out
}

private func appendBlock(_ row: ConversationViewModel.Row, into turn: inout TurnGroup) {
    switch row.kind {
    case "assistant":
        if case .markdown(let id, let t, _)? = turn.blocks.last {
            turn.blocks[turn.blocks.count - 1] = .markdown(id, text: t + row.text, streaming: false)
        } else {
            turn.blocks.append(.markdown(row.id, text: row.text, streaming: false))
        }
    case "reasoning":
        if case .reasoning(let id, let t)? = turn.blocks.last {
            turn.blocks[turn.blocks.count - 1] = .reasoning(id, text: t + row.text)
        } else {
            turn.blocks.append(.reasoning(row.id, text: row.text))
        }
    case "tool":
        guard let info = row.tool else { return }
        if case .tools(let id, var arr)? = turn.blocks.last {
            if shouldFoldTool(arr.last, info) { arr[arr.count - 1] = info } else { arr.append(info) }
            turn.blocks[turn.blocks.count - 1] = .tools(id, arr)
        } else {
            turn.blocks.append(.tools(row.id, [info]))
        }
    case "permission":
        turn.blocks.append(.permission(row.id, requestId: row.permissionRequestId))
    case "attention":
        turn.blocks.append(.attention(row.id, text: row.text))
    case "todo":
        turn.blocks.append(.todo(row.id, text: row.text))
    case "error":
        turn.blocks.append(.error(row.id, text: row.text))
    default:
        if !row.text.isEmpty { turn.blocks.append(.markdown(row.id, text: row.text, streaming: false)) }
    }
}

private func shouldFoldTool(_ last: ConversationViewModel.ToolInfo?, _ info: ConversationViewModel.ToolInfo) -> Bool {
    guard let last, last.status == "running", last.name == info.name else { return false }
    let lt = last.target ?? "", it = info.target ?? ""
    return lt == it || lt.isEmpty || it.isEmpty
}

// MARK: - Transcript

struct TranscriptView: View {
    let vm: ConversationViewModel
    var agentProvider: String? = nil
    var workspaceCwd: String? = nil
    var searchText: String = ""
    var onOpenFile: (String) -> Void = { _ in }

    @Environment(SettingsStore.self) private var settings
    @State private var isNearBottom = true
    @State private var hasNew = false
    @State private var viewportHeight: CGFloat = 0
    @State private var shownTurnCount: Int = 30
    @State private var expansionAnchorId: String? = nil

    private let nearBottomThreshold: CGFloat = 120
    private let turnPageSize = 20

    private var displayedRows: [ConversationViewModel.Row] {
        let base = vm.rows.filter { $0.tool?.name != "AskUserQuestion" }
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        let groups = groupTurns(displayedRows, provider: agentProvider)
        let hiddenCount = max(0, groups.count - shownTurnCount)
        let visibleGroups = hiddenCount > 0 ? Array(groups.suffix(shownTurnCount)) : groups
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: settings.bubbleGapPt) {
                        // Spacer at top pushes all content toward the composer.
                        // alignment:.bottom on .frame(minHeight:) doesn't work inside
                        // ScrollView (unbounded height), so Spacer is the reliable fix.
                        Spacer(minLength: 0)
                        if vm.isLoading && displayedRows.isEmpty {
                            ProgressView()
                                .controlSize(.small)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 18)
                        }
                        // Server-side pagination: only show when all local turns are visible.
                        if vm.hasOlderMessages && hiddenCount == 0 { loadEarlier }
                        // Client-side pagination: show earlier locally-loaded turns.
                        if hiddenCount > 0 { showEarlier(hiddenCount, firstVisibleId: visibleGroups.first?.id) }
                        if let err = vm.lastError {
                            Text(err).font(.system(size: 14)).foregroundStyle(DS.red).padding(.horizontal, 16)
                        }
                        ForEach(Array(visibleGroups.enumerated()), id: \.element.id) { idx, g in
                            turnView(g, isLast: idx == visibleGroups.count - 1).id(g.id)
                        }
                        if vm.isAgentWorking && !hasCurrentContent {
                            ThinkingRail()
                        }
                        if !searchText.isEmpty {
                            Text(displayedRows.isEmpty ? "无结果：\"\(searchText)\"" : "\(displayedRows.count) 条结果")
                                .font(.system(size: 12)).foregroundStyle(DS.text3)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        if searchText.isEmpty {
                            turnStatus
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.leading, 16)
                        }
                        // Extra clearance so queued messages don't overlap the last turn.
                        if !vm.queued.isEmpty {
                            Color.clear.frame(height: 44)
                        }
                        // Bottom marker == the TRUE content bottom (the bottom gap
                        // lives here, NOT in an outer .padding). That makes
                        // scrollTo("bottom",.bottom) land exactly where
                        // defaultScrollAnchor(.bottom) pins, so send/jump don't fight
                        // the anchor. Its height grows while the agent is working —
                        // this IS the tail compensation: the just-sent message and
                        // the working indicator get breathing room above the composer
                        // instead of being glued to it.
                        Color.clear.frame(height: vm.isAgentWorking ? 44 : 20).id("bottom")
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: TranscriptBottomOffsetKey.self,
                                        value: geometry.frame(in: .named("transcript-scroll")).maxY
                                    )
                                }
                            }
                    }
                    .frame(maxWidth: DS.transcriptMaxW, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: max(viewportHeight - 46, 0))
                    .padding(.horizontal, 40)
                    .padding(.top, 26)
                }
                // Native bottom-pinning: while the scroll is at the bottom, content
                // growth keeps the bottom aligned IN THE SAME LAYOUT PASS. This is
                // what kills the streaming jitter — the old per-token
                // `scrollTo("bottom")` always ran a frame behind the freshly
                // appended token, producing a scroll → drift → snap cycle. We no
                // longer scroll during streaming at all.
                .defaultScrollAnchor(.bottom)
                .coordinateSpace(name: "transcript-scroll")
                .background {
                    GeometryReader { geometry in
                        Color.clear
                            .onAppear { viewportHeight = geometry.size.height }
                            .onChange(of: geometry.size.height) { _, height in viewportHeight = height }
                    }
                }
                .onPreferenceChange(TranscriptBottomOffsetKey.self) { bottomY in
                    let nearBottom = bottomY <= viewportHeight + nearBottomThreshold
                    guard nearBottom != isNearBottom else { return }
                    isNearBottom = nearBottom
                    if nearBottom { hasNew = false }
                }
                // Streaming follow is handled by defaultScrollAnchor above, so these
                // only flag unread content when the user has scrolled up to read
                // history. No scrollTo during streaming.
                .onChange(of: vm.rows.count) { oldCount, newCount in
                    guard searchText.isEmpty else { return }
                    if !isNearBottom && newCount > oldCount { hasNew = true }
                }
                .onChange(of: vm.rows.last?.text ?? "") { _, _ in
                    guard searchText.isEmpty else { return }
                    if !isNearBottom { hasNew = true }
                }
                // Sending a message: discrete one-shot jump to the bottom, even if
                // the user had scrolled up, so the just-sent message + working
                // indicator come into view.
                .onChange(of: vm.bottomFollowRequest) { _, _ in
                    guard searchText.isEmpty else { return }
                    hasNew = false
                    isNearBottom = true
                    scrollToBottom(proxy)
                }
                .onChange(of: shownTurnCount) { _, _ in
                    guard let id = expansionAnchorId else { return }
                    Task { @MainActor in
                        await Task.yield()
                        proxy.scrollTo(id, anchor: .top)
                        expansionAnchorId = nil
                    }
                }

                if !isNearBottom { jumpButton(proxy) }
            }
            .task {
                guard !vm.rows.isEmpty else { return }
                try? await Task.sleep(nanoseconds: 60_000_000)
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private func turnView(_ g: TurnGroup, isLast: Bool) -> some View {
        if g.isUser {
            UserTurnView(group: g, onOpenFile: onOpenFile)
        } else {
            AssistantTurnView(
                group: streamingAdjusted(g, isLast: isLast),
                isStreaming: isLast && vm.isAgentWorking,
                workspaceCwd: workspaceCwd,
                onOpenFile: onOpenFile,
                pendingPermission: vm.pendingPermission,
                resolvedIds: vm.resolvedPermissionIds,
                onAllow: { Task { await vm.approvePermission() } },
                onDeny: { Task { await vm.denyPermission() } },
                onSubmitAnswers: { ans in Task { await vm.submitQuestionAnswers(ans) } }
            )
        }
    }

    /// Marks the last markdown block streaming while the agent is working so
    /// `MDView` closes dangling code fences live.
    private func streamingAdjusted(_ g: TurnGroup, isLast: Bool) -> TurnGroup {
        guard isLast, vm.isAgentWorking, !g.blocks.isEmpty else { return g }
        var copy = g
        if case .markdown(let id, let t, _) = copy.blocks[copy.blocks.count - 1] {
            copy.blocks[copy.blocks.count - 1] = .markdown(id, text: t, streaming: true)
        }
        return copy
    }

    private var loadEarlier: some View {
        Button { Task { await vm.loadOlderMessages() } } label: {
            HStack(spacing: 6) {
                if vm.isLoading { ProgressView().controlSize(.mini) }
                else { DSIcon(name: "chevron-up", size: 13, weight: .semibold) }
                Text("加载更早的消息").font(.system(size: 12.5))
            }
            .foregroundStyle(DS.text3)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(DS.hover, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity).padding(.bottom, 8)
    }

    private func showEarlier(_ hiddenCount: Int, firstVisibleId: String?) -> some View {
        Button {
            expansionAnchorId = firstVisibleId
            shownTurnCount += turnPageSize
        } label: {
            HStack(spacing: 6) {
                DSIcon(name: "chevron-up", size: 13, weight: .semibold)
                Text("显示更早 \(min(turnPageSize, hiddenCount)) 条").font(.system(size: 12.5))
            }
            .foregroundStyle(DS.text3)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(DS.hover, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity).padding(.bottom, 8)
    }

    @ViewBuilder private var turnStatus: some View {
        if vm.isAgentWorking {
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                TurnPill(working: true, elapsed: elapsedString)
            }
        } else if vm.lastTurnModel != nil, let d = vm.lastTurnDuration {
            TurnPill(working: false, duration: formatDur(d))
        }
    }

    private func jumpButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            isNearBottom = true
            withAnimation(.easeOut(duration: 0.18)) { proxy.scrollTo("bottom", anchor: .bottom) }
            hasNew = false
        } label: {
            HStack(spacing: 6) {
                DSIcon(name: "chevron-down", size: 13, weight: .semibold).foregroundStyle(DS.text)
                if hasNew { Circle().fill(settings.accentPalette.accent).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.regularMaterial, in: Capsule())
            .dsShadow(DS.shadowPop)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 14)
        .transition(.opacity)
    }

    private var hasCurrentContent: Bool {
        guard let last = vm.rows.last else { return false }
        return ["assistant", "reasoning", "tool"].contains(last.kind)
    }
    /// Discrete one-shot scroll to the bottom, deferred one runloop tick so the
    /// just-appended row is laid out before we scroll. Used only for explicit
    /// events (sending a message) — NOT during streaming, where
    /// defaultScrollAnchor(.bottom) keeps the bottom pinned without scrollTo.
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo("bottom", anchor: .bottom)
        }
    }
    private var elapsedString: String? {
        guard let s = vm.turnStartedAt else { return nil }
        return formatDur(Date().timeIntervalSince(s))
    }
    private func formatDur(_ t: TimeInterval) -> String {
        t < 60 ? String(format: "%.1fs", t) : String(format: "%dm %ds", Int(t) / 60, Int(t) % 60)
    }
}
