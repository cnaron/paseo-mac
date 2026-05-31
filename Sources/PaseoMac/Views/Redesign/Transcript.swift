import SwiftUI

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

    private var displayedRows: [ConversationViewModel.Row] {
        let base = vm.rows.filter { $0.tool?.name != "AskUserQuestion" }
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        let groups = groupTurns(displayedRows, provider: agentProvider)
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    VStack(alignment: .leading, spacing: settings.bubbleGapPt) {
                        if vm.hasOlderMessages { loadEarlier }
                        if let err = vm.lastError {
                            Text(err).font(.system(size: 14)).foregroundStyle(DS.red).padding(.horizontal, 16)
                        }
                        ForEach(Array(groups.enumerated()), id: \.element.id) { idx, g in
                            turnView(g, isLast: idx == groups.count - 1).id(g.id)
                        }
                        if vm.isAgentWorking && !hasCurrentContent {
                            ThinkingRail()
                        }
                        if !searchText.isEmpty {
                            Text(displayedRows.isEmpty ? "无结果：\"\(searchText)\"" : "\(displayedRows.count) 条结果")
                                .font(.system(size: 12)).foregroundStyle(DS.text3)
                                .frame(maxWidth: .infinity).padding(.vertical, 8)
                        }
                        if searchText.isEmpty { turnStatus.padding(.leading, 53) }
                        Color.clear.frame(height: 8).id("bottom")
                            .onAppear { isNearBottom = true; hasNew = false }
                            .onDisappear { isNearBottom = false }
                    }
                    .frame(maxWidth: DS.transcriptMaxW, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 26).padding(.bottom, 20)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: vm.rows.count) { _, _ in
                    if isNearBottom || vm.rows.last?.kind == "user" { scroll(proxy) } else { hasNew = true }
                }
                .onChange(of: vm.rows.last?.text ?? "") { _, _ in if isNearBottom { scroll(proxy) } }
                .onChange(of: vm.isAgentWorking) { _, working in
                    if !working { Task { try? await Task.sleep(nanoseconds: 150_000_000); scroll(proxy) } }
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
    private func scroll(_ proxy: ScrollViewProxy) { proxy.scrollTo("bottom", anchor: .bottom) }
    private var elapsedString: String? {
        guard let s = vm.turnStartedAt else { return nil }
        return formatDur(Date().timeIntervalSince(s))
    }
    private func formatDur(_ t: TimeInterval) -> String {
        t < 60 ? String(format: "%.1fs", t) : String(format: "%dm %ds", Int(t) / 60, Int(t) % 60)
    }
}
