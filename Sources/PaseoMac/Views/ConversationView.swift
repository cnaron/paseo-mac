import SwiftUI

struct ConversationView: View {
    @Environment(AppViewModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    let agentId: String
    @State private var searchText: String = ""
    @State private var isSearchVisible: Bool = false
    @State private var isResumingArchived: Bool = false
    @State private var gitHubUrl: String? = nil
    /// Live-measured composer height. Drives the bottom breathing room in
    /// MessageList so the last message stays above the composer even when
    /// it grows (e.g. providers populate after reconnect and chips appear).
    @State private var measuredComposerHeight: CGFloat = 210
    @FocusState private var searchFocused: Bool

    var body: some View {
        let isPending = agentId == AppViewModel.pendingAgentId
        let vm = app.conversation(for: agentId)
        VStack(spacing: 0) {
            // Inline search bar (toggled by toolbar button)
            if isSearchVisible {
                searchBar
            }
            GeometryReader { geo in
                Group {
                    if isPending {
                        if let creatingText = app.creatingAgentText {
                            PendingCreatingView(
                                text: creatingText,
                                images: app.creatingAgentImages,
                                availableHeight: geo.size.height,
                                bottomPadding: max(measuredComposerHeight, 210)
                            )
                        } else {
                            VStack(spacing: 14) {
                                Spacer()
                                if let err = app.creatingAgentError {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 28, weight: .regular))
                                        .foregroundStyle(.orange)
                                    Text("Couldn't start the agent")
                                        .font(.headline)
                                    Text(err)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 32)
                                        .textSelection(.enabled)
                                    Text("Your message has been put back into the composer — edit and try again, or hit ⌘W to cancel.")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 32)
                                } else {
                                    Image(systemName: "ellipsis.bubble")
                                        .font(.system(size: 36, weight: .light))
                                        .foregroundStyle(.tertiary)
                                    Text("Type a message to start the conversation")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Color.clear.frame(height: 120)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        MessageList(
                            vm: vm,
                            availableHeight: geo.size.height,
                            searchText: searchText,
                            bottomPadding: max(measuredComposerHeight, 210),
                            workspaceCwd: agent()?.cwd,
                            agentProvider: agent()?.provider,
                            agentCapabilities: agent()?.capabilities,
                            onRewind: { messageId, mode, text in
                                Task {
                                    await app.rewindAgent(
                                        agentId: agentId,
                                        messageId: messageId,
                                        mode: mode,
                                        rewoundText: text
                                    )
                                }
                            }
                        )
                    }
                }
                .overlay(alignment: .bottom) {
                    if searchText.isEmpty {
                        if app.isArchivedAgent(agentId) && !isResumingArchived && !vm.isAgentWorking {
                            ArchivedConversationBanner(
                                cwd: agent()?.cwd ?? "",
                                onResume: { isResumingArchived = true }
                            )
                            .padding(.bottom, 20)
                        } else {
                            VStack(spacing: 0) {
                                if isResumingArchived && app.isArchivedAgent(agentId) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "archivebox")
                                            .font(.caption2)
                                        Text("Resuming archived conversation")
                                            .font(.caption2)
                                    }
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 4)
                                    .background(Color.secondary.opacity(0.07))
                                }
                                ComposerView(vm: vm)
                            }
                            .padding(.bottom, 20)
                            .background(
                                GeometryReader { gp in
                                    Color.clear.preference(
                                        key: ComposerHeightKey.self,
                                        value: gp.size.height + 16  // small margin so last msg has breathing room
                                    )
                                }
                            )
                        }
                    }
                }
            }
        }
        .onPreferenceChange(ComposerHeightKey.self) { newValue in
            // Only trust positive measurements; ignore zero-init.
            if newValue > 0 { measuredComposerHeight = newValue }
        }
        .navigationTitle(isPending ? "New Conversation" : (agent()?.displayName ?? ""))
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if let a = agent() {
                    UsageChip(agent: a)
                }
            }
            ToolbarItem(placement: .automatic) {
                if vm.isAgentWorking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Working…").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if let cwd = agent()?.cwd {
                        Task { await app.createAgent(cwd: cwd) }
                    }
                } label: {
                    Image(systemName: "plus")
                }
                .help("New agent in same directory")
                .disabled(agent() == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(branchTargets, id: \.provider) { entry in
                        Button {
                            Task {
                                // Allow the menu to close before triggering a state change
                                // that replaces the ConversationView identity. Otherwise AppKit
                                // gets stuck in its menu tracking runloop.
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                await app.branchAgent(fromAgentId: agentId, newProvider: entry.provider)
                            }
                        } label: {
                            Label {
                                Text(entry.label + (entry.isCurrent ? " (current)" : ""))
                            } icon: {
                                Image(systemName: ProviderIcon.symbolName(for: entry.provider))
                            }
                        }
                        .disabled(entry.isCurrent || entry.status != "ready")
                    }
                    if branchTargets.allSatisfy({ $0.isCurrent || $0.status != "ready" }) {
                        Divider()
                        Text("No other providers ready").font(.caption).foregroundStyle(.secondary)
                    }
                } label: {
                    if app.branchInFlight == agentId {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.triangle.branch").font(.system(size: 14, weight: .semibold))
                    }
                }
                .help("Continue this conversation with another provider")
                .disabled(shouldDisableBranch)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { toggleSearch() } label: {
                    Image(systemName: isSearchVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
                }
                .help(isSearchVisible ? "Close search" : "Search messages (⌘F)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWorkspaceFiles()
                } label: {
                    Image(systemName: "folder")
                }
                .help("Open file preview window")
                .disabled(agent()?.cwd == nil)
            }
            if let urlStr = gitHubUrl, let url = URL(string: urlStr) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square")
                    }
                    .help("Open repository on GitHub")
                }
            }
        }
        // Use a composite id so the task re-runs once `agent()?.cwd` becomes
        // known (initial render can happen before `app.agents` is populated).
        .task(id: "\(agentId)|\(agent()?.cwd ?? "")") {
            guard let cwd = agent()?.cwd else { return }
            gitHubUrl = await app.fetchGitHubUrl(for: cwd)
        }
        .onChange(of: agentId) {
            gitHubUrl = nil
            isResumingArchived = false
        }
        .onChange(of: vm.rows.count) { old, new in
            guard isResumingArchived, new > old else { return }
            // Keep isResumingArchived = true so the banner stays hidden during polling.
            // It resets via onChange(of: agentId) when navigation succeeds.
            let before = Set(app.agents.map(\.id))
            let resumingAgentId = agentId
            Task {
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    try? await app.refreshAgents()
                    if let newAgent = app.agents.first(where: { !before.contains($0.id) }) {
                        app.selectedAgentId = newAgent.id
                        return
                    }
                    if !app.isArchivedAgent(resumingAgentId) {
                        // Same agent became active (daemon unarchived it in place)
                        return
                    }
                }
                isResumingArchived = false
            }
        }
        .onKeyPress(.escape) {
            if isSearchVisible { hideSearch(); return .handled }
            return .ignored
        }
    }

    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 13))
                TextField("Search messages", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($searchFocused)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                Button { hideSearch() } label: {
                    Text("Done")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            Divider()
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func toggleSearch() {
        if isSearchVisible {
            hideSearch()
        } else {
            isSearchVisible = true
            DispatchQueue.main.async { searchFocused = true }
        }
    }

    private func hideSearch() {
        isSearchVisible = false
        searchText = ""
        searchFocused = false
    }

    private func agent() -> AgentSnapshot? {
        app.agents.first { $0.id == agentId } ?? app.archivedAgents.first { $0.id == agentId }
    }

    // MARK: - Branch helpers

    private struct BranchTarget {
        let provider: String
        let label: String
        let status: String
        let isCurrent: Bool
    }

    private static let providerOrder = ["claude", "codex", "antigravity", "gemini", "opencode", "copilot", "pi"]

    private var branchTargets: [BranchTarget] {
        let current = agent()?.provider
        return Self.providerOrder.compactMap { id in
            guard let snap = app.providers.first(where: { $0.provider == id }) else { return nil }
            return BranchTarget(
                provider: id,
                label: snap.label ?? id.capitalized,
                status: snap.status,
                isCurrent: id == current
            )
        }
    }

    private var shouldDisableBranch: Bool {
        let vm = app.conversation(for: agentId)
        let hasContent = !vm.rows.isEmpty
        let hasOtherReady = branchTargets.contains { !$0.isCurrent && $0.status == "ready" }
        return !hasContent || !hasOtherReady
    }

    private func openWorkspaceFiles() {
        guard let cwd = agent()?.cwd else { return }
        openWindow(value: WorkspaceFilePreviewRoute(cwd: cwd, path: "."))
    }
}

// MARK: - Archived conversation banner

private struct ArchivedConversationBanner: View {
    let cwd: String
    var onResume: () -> Void = {}
    @Environment(AppViewModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "archivebox")
                    .foregroundStyle(.secondary)
                Text("This conversation is archived")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            HStack(spacing: 8) {
                Button("Resume conversation") {
                    onResume()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("New conversation") {
                    Task { await app.createAgent(cwd: cwd) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(cwd.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }
}

// MARK: - Row grouping

/// One visual bubble on the canvas, produced by coalescing consecutive
/// `ConversationViewModel.Row`s of the same kind. We merge user/assistant/
/// reasoning streams because the daemon emits them in chunks that would
/// otherwise render as dozens of tiny bubbles for one logical response.
private struct BubbleGroup: Identifiable {
    let id: String
    let kind: String
    let text: String
    let timestamp: String?
    let messageId: String?
    let tool: ConversationViewModel.ToolInfo?
    let toolCluster: [ConversationViewModel.ToolInfo]
    let images: [PendingImageAttachment]
    let modelUsed: String?
    let durationSec: TimeInterval?
    /// Threads the row's permission-request ID through grouping so the
    /// renderer can collapse permission/attention bubbles once the user
    /// has answered. Nil for non-permission rows.
    let permissionRequestId: String?
}

private func groupRows(_ rows: [ConversationViewModel.Row]) -> [BubbleGroup] {
    var out: [BubbleGroup] = []
    let mergeable: Set<String> = ["assistant", "reasoning"]

    for row in rows {
        // Coalesce consecutive tool rows into a tight cluster so a run of
        // Read → Edit → Bash doesn't get spread out by the inter-bubble gap.
        if row.kind == "tool", let info = row.tool,
           let last = out.last, last.kind == "tool_cluster" {
            var cluster = last.toolCluster
            if shouldFoldToolEmit(into: cluster.last, info: info) {
                // Same call's lifecycle update (running → running with target,
                // or running → completed). Daemon emits these as separate
                // rows when callId is empty, so collapse here. Latest wins.
                cluster[cluster.count - 1] = info
            } else {
                cluster.append(info)
            }
            out.removeLast()
            out.append(BubbleGroup(
                id: last.id,
                kind: "tool_cluster",
                text: "",
                timestamp: last.timestamp,
                messageId: nil,
                tool: nil,
                toolCluster: cluster,
                images: [],
                modelUsed: nil,
                durationSec: nil,
                permissionRequestId: nil
            ))
            continue
        }
        if row.kind == "tool", let info = row.tool {
            out.append(BubbleGroup(
                id: row.id,
                kind: "tool_cluster",
                text: "",
                timestamp: row.timestamp,
                messageId: nil,
                tool: nil,
                toolCluster: [info],
                images: [],
                modelUsed: nil,
                durationSec: nil,
                permissionRequestId: nil
            ))
            continue
        }

        if let last = out.last,
           last.kind == row.kind,
           mergeable.contains(row.kind) {
            // Streaming chunks of the same kind merge into one bubble.
            let merged = last.text + row.text
            out.removeLast()
            out.append(BubbleGroup(
                id: last.id,
                kind: last.kind,
                text: merged,
                timestamp: last.timestamp,
                messageId: last.messageId,
                tool: nil,
                toolCluster: [],
                images: last.images + row.images,
                modelUsed: last.modelUsed ?? row.modelUsed,
                durationSec: row.durationSec ?? last.durationSec,
                permissionRequestId: last.permissionRequestId
            ))
        } else {
            out.append(BubbleGroup(
                id: row.id,
                kind: row.kind,
                text: row.text,
                timestamp: row.timestamp,
                messageId: row.messageId,
                tool: row.tool,
                toolCluster: [],
                images: row.images,
                modelUsed: row.modelUsed,
                durationSec: row.durationSec,
                permissionRequestId: row.permissionRequestId
            ))
        }
    }
    return out
}

/// Decide whether a new tool emit is just a lifecycle update of the last one
/// in the cluster, vs a genuinely new call. We only fold when the prior entry
/// is still `running` (sealed entries — completed/failed — never absorb
/// subsequent ones) and the names match. Targets must match unless one side
/// is empty, which is how the daemon's initial running emit looks before the
/// argument detail arrives.
private func shouldFoldToolEmit(
    into last: ConversationViewModel.ToolInfo?,
    info: ConversationViewModel.ToolInfo
) -> Bool {
    guard let last = last else { return false }
    guard last.status == "running" else { return false }
    guard last.name == info.name else { return false }
    let lt = last.target ?? ""
    let it = info.target ?? ""
    return lt == it || lt.isEmpty || it.isEmpty
}

// MARK: - Timeline grouping helper

private struct GroupedMessage: Identifiable {
    let id: String
    let group: BubbleGroup
    let showConnector: Bool
}

private func groupMessages(_ rows: [ConversationViewModel.Row]) -> [GroupedMessage] {
    let groups = groupRows(rows)
    return groups.enumerated().map { index, group in
        let showConnector: Bool = {
            guard group.kind != "user" else { return false }
            guard index + 1 < groups.count else { return false }
            return groups[index + 1].kind != "user"
        }()
        return GroupedMessage(id: group.id, group: group, showConnector: showConnector)
    }
}

// MARK: - Message list

private struct MessageList: View {
    @Bindable var vm: ConversationViewModel
    @Environment(SettingsStore.self) private var settings
    @State private var isNearBottom: Bool = true
    @State private var hasNewContent: Bool = false
    @State private var suppressAutoScroll: Bool = false
    var availableHeight: CGFloat = 500
    var searchText: String = ""
    /// Driven by the parent view from a measured composer height so the
    /// last message never gets hidden behind the composer.
    var bottomPadding: CGFloat = 210
    var workspaceCwd: String? = nil
    var agentProvider: String? = nil
    var agentCapabilities: AgentCapabilityFlags? = nil
    var onRewind: ((String, AgentRewindMode, String) -> Void)? = nil

    private var displayedRows: [ConversationViewModel.Row] {
        // AskUserQuestion is fully owned by the permission_request flow's
        // inline picker. The bare tool_call row never gets a "completed"
        // event (daemon closes it via agent_permission_response, not
        // tool_result) so it lingers as "AskUserQuestion running" forever
        // after the user answers. Hide it.
        let base = vm.rows.filter { $0.tool?.name != "AskUserQuestion" }
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        let grouped = groupMessages(displayedRows)
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    ZStack(alignment: .bottom) {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: availableHeight)
                        LazyVStack(alignment: .leading, spacing: CGFloat(settings.bubbleGap)) {
                            Color.clear.frame(height: 0).task {
                                // Defer so LazyVStack finishes layout before scrollTo
                                guard !vm.rows.isEmpty else { return }
                                try? await Task.sleep(nanoseconds: 50_000_000)
                                proxy.scrollTo("bottom", anchor: .bottom)
                            }
                            if vm.hasOlderMessages {
                                Button {
                                    Task { await vm.loadOlderMessages() }
                                } label: {
                                    HStack(spacing: 6) {
                                        if vm.isLoading {
                                            ProgressView().controlSize(.mini)
                                        } else {
                                            Image(systemName: "arrow.up.circle")
                                                .font(.caption.weight(.semibold))
                                        }
                                        Text("Load earlier messages")
                                            .font(.callout)
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(Color.secondary.opacity(0.1), in: Capsule())
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                            }
                            if let err = vm.lastError {
                                Text(err)
                                    .font(.callout)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 16)
                            }
                            let lastAssistantId = grouped
                                .last(where: { $0.group.kind == "assistant" })?.id
                            let segmentCopyTexts = Self.computeSegmentCopyTexts(grouped)
                            ForEach(grouped) { gm in
                                MessageBubble(
                                    group: gm.group,
                                    showConnector: gm.showConnector,
                                    isStreaming: vm.isAgentWorking && gm.id == lastAssistantId,
                                    workspaceCwd: workspaceCwd,
                                    agentProvider: agentProvider,
                                    agentCapabilities: agentCapabilities,
                                    pendingPermission: vm.pendingPermission,
                                    isPermissionResolved: gm.group.permissionRequestId
                                        .map { vm.resolvedPermissionIds.contains($0) } ?? false,
                                    turnCopyText: segmentCopyTexts[gm.id],
                                    onApprovePermission: { Task { await vm.approvePermission() } },
                                    onDenyPermission: { Task { await vm.denyPermission() } },
                                    onSubmitQuestionAnswers: { answers in
                                        Task { await vm.submitQuestionAnswers(answers) }
                                    },
                                    onRewind: { messageId, mode, text in
                                        onRewind?(messageId, mode, text)
                                    },
                                    isPinned: vm.isPinned(gm.id),
                                    onTogglePin: {
                                        vm.togglePin(id: gm.id, snippet: gm.group.text, kind: gm.group.kind)
                                    }
                                )
                                .id(gm.id)
                                .transition(.opacity)
                            }
                            if vm.isLoading {
                                ProgressView().frame(maxWidth: .infinity).padding()
                            }
                            if searchText.isEmpty && vm.isReplying && !vm.isLoading && !hasCurrentTurnContent(vm.rows) {
                                ThinkingIndicator()
                                    .id("typing")
                                    .transition(.opacity)
                            }
                            if !searchText.isEmpty {
                                Text(displayedRows.isEmpty
                                     ? "No results for \"\(searchText)\""
                                     : "\(displayedRows.count) result\(displayedRows.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                            }
                            // Status bar: only shown when there is real turn data
                            // from this session. Nothing on cold start.
                            if searchText.isEmpty {
                                if vm.isReplying {
                                    TurnStatusBar(
                                        startedAt: vm.replyStartedAt,
                                        isWorking: true
                                    )
                                } else if vm.lastTurnModel != nil {
                                    TurnStatusBar(
                                        startedAt: nil,
                                        isWorking: false,
                                        duration: vm.lastTurnDuration
                                    )
                                }
                            }
                            Color.clear.frame(height: searchText.isEmpty ? bottomPadding : 24) // breathing room driven by measured composer height
                            Color.clear.frame(height: 1).id("bottom")
                                .onAppear { isNearBottom = true; hasNewContent = false }
                                .onDisappear { isNearBottom = false }
                        }
                        .padding(.vertical, 16)
                        .padding(.trailing, 44)
                    }
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: vm.rows.count) { old, new in
                    guard !suppressAutoScroll else { return }
                    let lastIsUser = vm.rows.last?.kind == "user"
                    if isNearBottom || lastIsUser {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } else if new > old {
                        hasNewContent = true
                    }
                }
                .onChange(of: vm.rows.last?.text ?? "") { _, _ in
                    guard !suppressAutoScroll else { return }
                    if isNearBottom {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } else {
                        hasNewContent = true
                    }
                }
                .onChange(of: vm.isAgentWorking) { _, isWorking in
                    guard !isWorking, !suppressAutoScroll else { return }
                    // turn_completed stamps TurnMetaChip + TurnStatusBar changes;
                    // neither triggers the count/text observers above.
                    // Wait for layout to settle then scroll to reveal the chip.
                    Task {
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if !vm.pinnedMessages.isEmpty {
                        PinnedBar(
                            pins: vm.pinnedMessages,
                            onTap: { id in
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            },
                            onUnpin: { id in vm.unpin(id: id) }
                        )
                    }
                }


                if !isNearBottom {
                    jumpToBottomButton(proxy: proxy)
                }
            }
            .overlay(alignment: .trailing) {
                let ug = grouped.filter { $0.group.kind == "user" && ($0.group.text.trimmingCharacters(in: .whitespacesAndNewlines).count > 2 || !$0.group.images.isEmpty) }
                    .map { UserMessageTimeline.Item(id: $0.id, text: $0.group.text, hasImages: !$0.group.images.isEmpty) }
                if !ug.isEmpty {
                    UserMessageTimeline(
                        items: ug, proxy: proxy,
                        hasOlderMessages: vm.hasOlderMessages,
                        isLoadingMore: vm.isLoading,
                        onLoadMore: { Task { await vm.loadOlderMessages() } },
                        onNavigate: {
                            suppressAutoScroll = true
                            isNearBottom = false
                            Task {
                                try? await Task.sleep(nanoseconds: 1_500_000_000)
                                suppressAutoScroll = false
                            }
                        }
                    )
                    .padding(.trailing, 20)
                    .padding(.vertical, 60)
                }
            }
        }
    }




    /// For each response segment (content between user messages), collect all
    /// assistant bubble texts and store the combined string keyed to the LAST
    /// assistant bubble's id. All other assistant bubbles map to nothing, so
    /// only the final bubble in a segment shows the Copy button.
    private static func computeSegmentCopyTexts(_ groups: [GroupedMessage]) -> [String: String] {
        var result: [String: String] = [:]
        var segmentBubbles: [(id: String, text: String)] = []

        func flush() {
            guard !segmentBubbles.isEmpty else { return }
            let combined = segmentBubbles.map(\.text).joined(separator: "\n\n")
            result[segmentBubbles[segmentBubbles.count - 1].id] = combined
            segmentBubbles.removeAll()
        }

        for gm in groups {
            switch gm.group.kind {
            case "user": flush()
            case "assistant": segmentBubbles.append((id: gm.id, text: gm.group.text))
            default: break
            }
        }
        flush()
        return result
    }

    private func jumpToBottomButton(proxy: ScrollViewProxy) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            hasNewContent = false
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.down")
                    .font(.caption.weight(.semibold))
                if hasNewContent {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 160)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
        .animation(.easeInOut(duration: 0.2), value: hasNewContent)
    }
}

// MARK: - Pinned messages bar (Telegram-style)

private struct PinnedBar: View {
    let pins: [ConversationViewModel.PinnedMessage]
    let onTap: (String) -> Void
    let onUnpin: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(pins) { pin in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor)
                            .frame(width: 3, height: 22)
                        Image(systemName: pin.kind == "user" ? "person.crop.circle.fill" : "sparkles")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(pin.snippet)
                            .font(.caption2)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Button { onUnpin(pin.id) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06)))
                    .contentShape(Capsule())
                    .onTapGesture { onTap(pin.id) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
    }
}

private struct MessageBubble: View {
    let group: BubbleGroup
    let showConnector: Bool
    var isStreaming: Bool = false
    var workspaceCwd: String? = nil
    var agentProvider: String? = nil
    var agentCapabilities: AgentCapabilityFlags? = nil
    var pendingPermission: PermissionRequestPayload? = nil
    var isPermissionResolved: Bool = false
    /// Combined text of all assistant bubbles in the same response segment.
    /// Non-nil only on the LAST assistant bubble of a segment — that's the
    /// only one that shows the Copy button.
    var turnCopyText: String? = nil
    var onApprovePermission: (() -> Void)? = nil
    var onDenyPermission: (() -> Void)? = nil
    var onSubmitQuestionAnswers: (([String: String]) -> Void)? = nil
    var onRewind: ((String, AgentRewindMode, String) -> Void)? = nil
    var isPinned: Bool = false
    var onTogglePin: (() -> Void)? = nil
    @State private var reasoningExpanded: Bool = false
    @State private var isExpanded: Bool = false
    @State private var didCopy: Bool = false
    @State private var hovering: Bool = false

    private var isLong: Bool { group.text.count > 500 }

    var body: some View {
        bubbleContent
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button { onTogglePin?() } label: {
                        Image(systemName: isPinned ? "pin.fill" : "pin")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(isPinned ? Color.accentColor : Color.secondary)
                            .padding(5)
                            .background(.regularMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help(isPinned ? "Unpin message" : "Pin message")
                    .padding(.top, 4)
                    .padding(.trailing, 10)
                    .transition(.opacity)
                }
            }
            .onHover { h in
                withAnimation(.easeInOut(duration: 0.12)) { hovering = h }
            }
            .contextMenu { bubbleContextMenu }
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch group.kind {
        case "user":
            userBubble
        case "tool_cluster":
            toolTimelineItem
        case "assistant":
            assistantTimelineItem
        case "reasoning":
            reasoningTimelineItem
        case "permission":
            permissionTimelineItem
        case "attention":
            attentionTimelineItem
        default:
            sideTimelineItem
        }
    }

    // One context menu for every bubble kind (not just user bubbles), so any
    // message can be pinned. Copy + Pin always; Rewind only where a messageId
    // and rewind modes exist.
    @ViewBuilder
    private var bubbleContextMenu: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(group.text, forType: .string)
        } label: { Label("Copy text", systemImage: "doc.on.doc") }
        Button {
            onTogglePin?()
        } label: {
            Label(isPinned ? "Unpin message" : "Pin message",
                  systemImage: isPinned ? "pin.slash" : "pin")
        }
        if let messageId = group.messageId, let onRewind, !rewindModes.isEmpty {
            Divider()
            Menu("Rewind") {
                ForEach(rewindModes, id: \.self) { mode in
                    Button(rewindLabel(mode)) { onRewind(messageId, mode, group.text) }
                }
            }
        }
    }

    // MARK: User (right-aligned bubble, unchanged)
    //
    // Layout note: the `maxWidth` cap must come AFTER padding+background so
    // the bubble hugs its content for short messages.

    private var userBubble: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                if !group.images.isEmpty {
                    UserBubbleImages(images: group.images)
                }
                if !group.text.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        Group {
                            if isLong && !isExpanded {
                                MarkdownBodyView(text: group.text, workspaceCwd: workspaceCwd)
                                    .frame(maxHeight: 160)
                                    .clipped()
                                    .mask(
                                        VStack(spacing: 0) {
                                            Color.black
                                            LinearGradient(
                                                colors: [.black, .clear],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                            .frame(height: 56)
                                        }
                                    )
                            } else {
                                MarkdownBodyView(text: group.text, workspaceCwd: workspaceCwd)
                            }
                        }
                        if isLong {
                            Button(isExpanded ? "Show less ↑" : "Show more ↓") {
                                withAnimation(.easeInOut(duration: 0.18)) { isExpanded.toggle() }
                            }
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                }
                if let ts = group.timestamp, let label = formatTimestamp(ts) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }
            .frame(maxWidth: 560, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var rewindModes: [AgentRewindMode] {
        agentCapabilities?.rewindModes ?? []
    }

    private func rewindLabel(_ mode: AgentRewindMode) -> String {
        switch mode {
        case .conversation: return "Rewind Conversation"
        case .files: return "Rewind Files"
        case .both: return "Rewind Conversation and Files"
        }
    }

    // MARK: Assistant narrative — clock icon, inline text

    private var assistantTimelineItem: some View {
        FlowStep(iconName: "clock", showLine: showConnector) {
            VStack(alignment: .leading, spacing: 4) {
                MarkdownBodyView(text: group.text, isStreaming: isStreaming, workspaceCwd: workspaceCwd)
                if let chipLabel = displayProviderModel(provider: agentProvider, model: group.modelUsed),
                   turnCopyText != nil {
                    TurnMetaChip(model: chipLabel, durationSec: group.durationSec)
                }
                if !isStreaming, let copyText = turnCopyText {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(copyText, forType: .string)
                        didCopy = true
                        Task {
                            try? await Task.sleep(nanoseconds: 1_500_000_000)
                            didCopy = false
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 10, weight: .medium))
                            Text(didCopy ? "Copied" : "Copy")
                                .font(.caption2)
                        }
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Copy full reply to clipboard")
                    .padding(.top, 2)
                    .animation(.easeInOut(duration: 0.15), value: didCopy)
                }
            }
            .contextMenu {
                Button("Copy text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(group.text, forType: .string)
                }
            }
        }
    }

    // MARK: Reasoning — clock icon, collapsible thinking block

    private var reasoningTimelineItem: some View {
        FlowStep(iconName: "clock", showLine: showConnector) {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        reasoningExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("Thinking · \(wordCount(group.text)) words")
                            .font(.caption.weight(.medium))
                        Spacer(minLength: 0)
                        Image(systemName: reasoningExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                if reasoningExpanded {
                    MarkdownBodyView(text: group.text, workspaceCwd: workspaceCwd)
                        .foregroundStyle(.secondary)
                        .italic()
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: Tool cluster — terminal icon, minimal label rows

    private var toolTimelineItem: some View {
        FlowStep(iconName: "bolt", showLine: showConnector) {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(group.toolCluster.enumerated()), id: \.offset) { _, info in
                    ToolRowTimeline(info: info, workspaceCwd: workspaceCwd)
                }
            }
        }
    }

    // MARK: Fallback (todo / error / system)

    private var sideTimelineItem: some View {
        FlowStep(iconName: sideIcon, showLine: showConnector) {
            Text(group.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(sideTextColor)
                .font(group.kind == "compaction" ? .callout.italic() : .body)
        }
    }

    private var sideTextColor: Color {
        switch group.kind {
        case "error": return .red
        case "compaction": return .accentColor
        default: return .secondary
        }
    }

    // MARK: Permission request — approve/deny buttons or AskUserQuestion picker

    @ViewBuilder
    private var permissionTimelineItem: some View {
        if isPermissionResolved {
            // Daemon confirmed the resolution — collapse so we don't leave a
            // stale banner asking the user again.
            EmptyView()
        } else if let aq = pendingPermission?.askUserQuestion {
            FlowStep(iconName: "questionmark.bubble.fill", showLine: showConnector) {
                AskUserQuestionView(
                    questions: aq.questions,
                    onSubmit: { onSubmitQuestionAnswers?($0) },
                    onCancel: { onDenyPermission?() }
                )
            }
        } else {
            FlowStep(iconName: "exclamationmark.shield.fill", showLine: showConnector) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Permission Required")
                        .font(.callout.bold())
                        .foregroundStyle(.orange)
                    HStack(spacing: 8) {
                        Button("Allow") { onApprovePermission?() }
                            .buttonStyle(.borderedProminent)
                            .tint(.green)
                            .controlSize(.small)
                        Button("Deny") { onDenyPermission?() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
        }
    }

    // MARK: Attention required — informational banner

    @ViewBuilder
    private var attentionTimelineItem: some View {
        if isPermissionResolved {
            // Stale "Attention Required: permission" once the user answers.
            EmptyView()
        } else {
            FlowStep(iconName: "exclamationmark.circle.fill", showLine: showConnector) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Attention Required")
                        .font(.callout.bold())
                        .foregroundStyle(.orange)
                    if !group.text.isEmpty {
                        Text(group.text)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var sideIcon: String {
        switch group.kind {
        case "error": "exclamationmark.circle"
        case "todo": "checklist"
        case "compaction": "arrow.up.right.and.arrow.down.left"
        default: "info.circle"
        }
    }

    private func displayProviderModel(provider: String?, model: String?) -> String? {
        if let m = model, !m.isEmpty { return m }
        switch provider {
        case "gemini": return "Gemini"
        case "antigravity": return "Antigravity"
        case "claude": return "Claude"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        case "copilot": return "Copilot"
        default: return provider?.capitalized
        }
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

// MARK: - Timeline connector wrapper

/// Wraps assistant-side content in the Claude.ai-style timeline layout:
/// a small icon on the left, optional thin connector line running downward
/// to the next item, and content to the right.
private struct FlowStep<Content: View>: View {
    let iconName: String
    let showLine: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 11, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 16, alignment: .top)  // glyph top = content top

            content()
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.bottom, showLine ? 14 : 8)
        }
        .padding(.horizontal, 16)
        .background {
            if showLine {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 1, height: max(0, geo.size.height - 16))
                        .position(x: 27, y: (geo.size.height + 16) / 2)
                }
            }
        }
    }
}

// MARK: - Tool row (timeline style)

/// One tool invocation in the timeline. Collapsed: name + target + badge.
/// Tap to expand the detail payload (script output, diff, etc.).
private struct ToolRowTimeline: View {
    let info: ConversationViewModel.ToolInfo
    var workspaceCwd: String? = nil
    @Environment(\.openWindow) private var openWindow
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            summaryRow
            if expanded, info.hasDetail {
                detailView.padding(.top, 2)
            }
        }
    }

    private var summaryRow: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: info.iconName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)
            Text(info.name)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let target = info.target, !target.isEmpty {
                if target.hasPrefix("/") {
                    let loc = FileLocation.parse(target)
                    Button {
                        if let cwd = workspaceCwd, !cwd.isEmpty {
                            let target = loc.display
                            let route = WorkspaceFilePreviewRouting.forceRoute(cwd: cwd, rawLocation: target)
                            openWindow(value: route)
                        } else {
                            FileLocationOpener.open(loc)
                        }
                    } label: {
                        Text(truncate(loc.display, max: 64))
                            .font(.callout)
                            .foregroundStyle(Markdown.fileLinkColor)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help(loc.lineEnd != nil ? "Open \(loc.path) at lines \(loc.lineStart!)–\(loc.lineEnd!)"
                          : (loc.lineStart != nil ? "Open \(loc.path) at line \(loc.lineStart!)" : "Open \(loc.path)"))
                } else {
                    Text(truncate(target, max: 64))
                        .font(.callout)
                        .foregroundStyle(Color.secondary.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            detailBadge

            if let status = statusSuffix {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            Spacer(minLength: 0)

            if info.hasDetail {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard info.hasDetail else { return }
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
    }

    @ViewBuilder
    private var detailBadge: some View {
        switch info.detailKind {
        case .plain(_, let mono) where mono:
            badgePill("Script")
        case .beforeAfter, .unifiedDiff:
            badgePill("Edit")
        default:
            EmptyView()
        }
    }

    private func badgePill(_ label: String) -> some View {
        Text(label)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var detailView: some View {
        switch info.detailKind {
        case .none:
            EmptyView()
        case .plain(let text, let mono):
            Text(text)
                .font(mono ? .system(.caption, design: .monospaced) : .callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        case .beforeAfter(let before, let after):
            BeforeAfterView(before: before, after: after)
        case .unifiedDiff(let text):
            DiffView(text: text)
        }
    }

    private var statusSuffix: String? {
        switch info.status {
        case "completed", "": return nil
        default: return info.status
        }
    }

    private var statusColor: Color {
        switch info.status {
        case "running": .blue
        case "failed", "error": .red
        case "canceled": .orange
        default: .secondary
        }
    }

    private func truncate(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        let head = s.prefix(max / 2 - 1)
        let tail = s.suffix(max / 2 - 1)
        return "\(head)…\(tail)"
    }

    private func parseFilePath(_ raw: String) -> (String, Int?) {
        let location = FileLocation.parse(raw)
        return (location.path, location.lineStart)
    }
}

/// Opens file references in whichever editor the user has set as default.
/// When a line number is present, falls back to a CLI invocation that the
/// common editors accept (`code -g`, `cursor -g`, `subl`), since
/// `NSWorkspace.open(URL)` alone has no way to express "and jump to line N".
/// Editors that don't honor the CLI just open the file at the top — same
/// behavior as before, no regression.
enum FileLocationOpener {
    static func open(_ loc: FileLocation) {
        let url = URL(fileURLWithPath: loc.path)
        guard let line = loc.lineStart else {
            NSWorkspace.shared.open(url)
            return
        }
        // Try a few known editor CLIs in order of how common they are on
        // dev machines. Each one accepts `<path>:<line>:<col>` (subl style)
        // or `-g <path>:<line>:<col>` (vscode/cursor style).
        let target = loc.lineEnd != nil ? "\(loc.path):\(line):1" : "\(loc.path):\(line)"
        for cli in ["cursor", "code", "subl"] {
            if runCLI(cli, args: cli == "subl" ? [target] : ["-g", target]) { return }
        }
        // Final fallback: plain open. The line hint is lost but the file
        // still opens in whatever the user's "Open With" default is.
        NSWorkspace.shared.open(url)
    }

    private static func runCLI(_ command: String, args: [String]) -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/env"
        task.arguments = [command] + args
        // Discard both streams so a missing CLI on PATH doesn't spam stderr.
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}

/// Parsed reference to a file location: `path:line` or `path:start-end`.
/// Mirrors upstream's `WorkspaceFileLocation` so future editor-integration
/// hooks can carry range info through to the open call.
struct FileLocation: Hashable, Sendable {
    let path: String
    let lineStart: Int?
    let lineEnd: Int?

    static func parse(_ raw: String) -> FileLocation {
        let parsed = WorkspaceFilePreviewRouting.parseLocation(raw)
        return FileLocation(path: parsed.path, lineStart: parsed.lineStart, lineEnd: parsed.lineEnd)
    }

    /// `path:line` or `path:start-end` form used by tooltips and the
    /// "open" button label.
    var display: String {
        if let s = lineStart, let e = lineEnd { return "\(path):\(s)-\(e)" }
        if let s = lineStart { return "\(path):\(s)" }
        return path
    }
}

// MARK: - Usage chip (toolbar)

/// Compact cost + context-window indicator for the selected agent.
/// Values come from `AgentSnapshot.lastUsage`, which the daemon refreshes
/// after each turn. Hover tooltip shows per-token breakdown.
private struct UsageChip: View {
    let agent: AgentSnapshot

    var body: some View {
        if let u = agent.lastUsage, hasAnything(u) {
            HStack(spacing: 6) {
                if let cost = u.totalCostUsd, cost > 0 {
                    Text(formatCost(cost))
                        .font(.caption2)
                        .monospacedDigit()
                }
                if let used = u.contextWindowUsedTokens,
                   let max = u.contextWindowMaxTokens, max > 0 {
                    contextBar(used: used, max: max)
                }
            }
            .foregroundStyle(.secondary)
            .help(tooltip(u))
        }
    }

    private func hasAnything(_ u: AgentUsage) -> Bool {
        u.contextWindowUsedTokens != nil || (u.totalCostUsd ?? 0) > 0
    }

    private func contextBar(used: Int, max: Int) -> some View {
        let ratio = min(max > 0 ? Double(used) / Double(max) : 0, 1.0)
        return HStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: ratio)
                    .stroke(barColor(ratio: ratio), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 16, height: 16)
            Text("\(compactTokens(used))/\(compactTokens(max))")
                .font(.caption2)
                .monospacedDigit()
        }
    }

    private func barColor(ratio: Double) -> Color {
        if ratio >= 0.9 { return .red }
        if ratio >= 0.7 { return .orange }
        return .accentColor
    }

    private func formatCost(_ cost: Double) -> String {
        cost >= 10 ? String(format: "$%.2f", cost) : String(format: "$%.3f", cost)
    }

    private func compactTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }

    private func tooltip(_ u: AgentUsage) -> String {
        var lines: [String] = []
        if let v = u.inputTokens { lines.append("Input: \(v.formatted())") }
        if let v = u.cachedInputTokens { lines.append("Cached: \(v.formatted())") }
        if let v = u.outputTokens { lines.append("Output: \(v.formatted())") }
        if let v = u.totalCostUsd { lines.append(String(format: "Cost: $%.4f", v)) }
        if let used = u.contextWindowUsedTokens {
            let maxStr = u.contextWindowMaxTokens.map { " / \($0.formatted())" } ?? ""
            lines.append("Context: \(used.formatted())\(maxStr)")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Model pill (per-assistant-turn label)

/// Small muted chip showing which model produced an assistant turn.
/// Lets a mid-conversation model switch show up in the transcript.
private struct ModelPill: View {
    let model: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sparkles")
                .font(.caption2)
            Text(prettyName(model))
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.08), in: Capsule())
    }

    private func prettyName(_ raw: String) -> String {
        // "claude-opus-4-7[1m]" → "Opus 4.7 1M"
        var s = raw
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        s = s.replacingOccurrences(of: "[1m]", with: " 1M")
        s = s.replacingOccurrences(of: "[", with: " ")
        s = s.replacingOccurrences(of: "]", with: "")
        // opus-4-7 → Opus 4.7
        let parts = s.split(separator: "-")
        if parts.count >= 3 {
            let name = parts[0].capitalized
            let ver = "\(parts[1]).\(parts[2])"
            let rest = parts.dropFirst(3).joined(separator: " ")
            return "\(name) \(ver)\(rest.isEmpty ? "" : " \(rest)")"
        }
        return raw
    }
}

// MARK: - User bubble image strip

/// Renders attached images inside a user bubble. Images cap at ~240pt tall
/// so they don't dominate the window; click opens a QuickLook-ish full-size
/// view via SwiftUI's default sheet.
private struct UserBubbleImages: View {
    let images: [PendingImageAttachment]
    @State private var zoomed: PendingImageAttachment? = nil

    // Single image gets a larger cell; grids use a smaller fixed cell.
    private var cellSize: CGFloat { images.count == 1 ? 130 : 76 }

    var body: some View {
        LazyVGrid(columns: gridColumns(count: images.count), spacing: 4) {
            ForEach(images) { img in
                if let ns = NSImage(contentsOf: img.fileURL) {
                    Image(nsImage: ns)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFill()          // fills frame, crops surplus
                        .frame(width: cellSize, height: cellSize)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                        .onTapGesture { zoomed = img }
                }
            }
        }
        .sheet(item: $zoomed) { img in
            if let ns = NSImage(contentsOf: img.fileURL) {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: ns)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFit()
                        .frame(maxWidth: 960, maxHeight: 760)
                        .padding(24)
                    Button {
                        zoomed = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(14)
                }
            }
        }
    }

    private func gridColumns(count: Int) -> [GridItem] {
        let cols = min(count, 2)
        return Array(
            repeating: GridItem(.fixed(cellSize), spacing: 4),
            count: max(cols, 1)
        )
    }
}

// MARK: - Edit before/after renderer (Claude-Code style)

/// Stacked "── before ──" / "── after ──" code blocks. Used when a tool_call
/// provides both `oldString` and `newString` (no colored +/- formatting —
/// just plain monospace so the eye can compare the two regions directly).
private struct BeforeAfterView: View {
    let before: String
    let after: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            codeSection(label: "── before ──", text: before)
            codeSection(label: "── after ──", text: after)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func codeSection(label: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Unified diff renderer

/// Colored line-by-line renderer for unified diffs. No syntax highlighting;
/// just enough hue to make add/remove/context skimmable.
private struct DiffView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                DiffLine(line: line)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct DiffLine: View {
    let line: String

    var body: some View {
        Text(line.isEmpty ? " " : line)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(foreground)
            .textSelection(.enabled)
            .padding(.horizontal, 10)
            .padding(.vertical, 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }

    private var foreground: Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .secondary }
        if line.hasPrefix("+") { return .green }
        if line.hasPrefix("-") { return .red }
        if line.hasPrefix("@@") { return .purple }
        return .primary
    }

    private var background: Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return Color.green.opacity(0.10) }
        if line.hasPrefix("-") { return Color.red.opacity(0.10) }
        if line.hasPrefix("@@") { return Color.purple.opacity(0.08) }
        return .clear
    }
}

// MARK: - Shared timestamp helper

private func formatTimestamp(_ iso: String) -> String? {
    let frac = ISO8601DateFormatter()
    frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    guard let date = frac.date(from: iso) ?? plain.date(from: iso) else { return nil }
    // Full m/d/y hh:mm always (even today), POSIX-fixed so the order stays
    // month/day/year regardless of the system locale.
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "M/d/yy HH:mm"
    return f.string(from: date)
}

// MARK: - Per-bubble model + duration chip

private struct TurnMetaChip: View {
    let model: String
    let durationSec: TimeInterval?

    var body: some View {
        HStack(spacing: 4) {
            Text(prettyModel(model))
            if let d = durationSec {
                Text("·")
                    .foregroundStyle(.quaternary)
                Text(formatDuration(d))
                    .monospacedDigit()
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
        .padding(.top, 2)
    }

    private func prettyModel(_ raw: String) -> String {
        var s = raw
        if s.hasPrefix("claude-") { s.removeFirst("claude-".count) }
        s = s.replacingOccurrences(of: "[1m]", with: " 1M")
            .replacingOccurrences(of: "[", with: " ")
            .replacingOccurrences(of: "]", with: "")
        let parts = s.split(separator: "-")
        if parts.count >= 3 {
            let name = parts[0].capitalized
            let ver = "\(parts[1]).\(parts[2])"
            let rest = parts.dropFirst(3).joined(separator: " ")
            return "\(name) \(ver)\(rest.isEmpty ? "" : " \(rest)")"
        }
        return raw
    }

    private func formatDuration(_ t: TimeInterval) -> String {
        if t < 60 { return String(format: "%.1fs", t) }
        return String(format: "%dm %ds", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - Turn status bar (pill with animated dots + elapsed time)

private struct TurnStatusBar: View {
    let startedAt: Date?
    let isWorking: Bool
    var duration: TimeInterval? = nil

    @State private var elapsed: TimeInterval = 0
    @State private var phase: Int = 0

    var body: some View {
        HStack(spacing: 8) {
            if isWorking {
                HStack(spacing: 3) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(Color.orange.opacity(phase == i ? 0.95 : 0.35))
                            .frame(width: 5, height: 5)
                            .animation(.easeInOut(duration: 0.4), value: phase)
                    }
                }
            } else {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
            Text(displayTime)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .padding(.leading, 58)
        .padding(.trailing, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .task(id: isWorking) {
            guard isWorking, let start = startedAt else { return }
            var ticks = 0
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(start)
                if ticks % 2 == 0 {
                    phase = (phase + 1) % 3
                }
                ticks += 1
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private var displayTime: String {
        let t = isWorking ? elapsed : (duration ?? elapsed)
        if t < 60 { return String(format: "%.1fs", t) }
        return String(format: "%dm %ds", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - Claude Code version chip (toolbar)

private struct ClaudeCodeVersionChip: View {
    @Environment(AppViewModel.self) private var app

    var body: some View {
        if let version = app.claudeCodeCurrentVersion, version != "unknown" {
            HStack(spacing: 3) {
                Text("CC")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text("v\(version)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(app.claudeCodeUpdateAvailable ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                if app.isUpdatingClaudeCode {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else if app.claudeCodeUpdateAvailable {
                    Button {
                        Task { await app.updateClaudeCode() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .help("Update Claude Code to v\(app.claudeCodeLatestVersion ?? "")")
                }
            }
            .help(app.claudeCodeUpdateAvailable
                  ? "Claude Code v\(version) · Update to v\(app.claudeCodeLatestVersion ?? "?")"
                  : "Claude Code v\(version) · Up to date")
        }
    }
}

/// Returns true if the most recent rows contain agent-produced content
/// (assistant text, tool calls, reasoning). When true, the typing dots
/// are unnecessary because the user can already see streaming output.
private func hasCurrentTurnContent(_ rows: [ConversationViewModel.Row]) -> Bool {
    guard let last = rows.last else { return false }
    let agentKinds: Set<String> = ["assistant", "reasoning", "tool"]
    return agentKinds.contains(last.kind)
}

// MARK: - User message timeline (right rail)

private struct UserMessageTimeline: View {
    struct Item: Identifiable { let id: String; let text: String; var hasImages: Bool = false }
    let items: [Item]
    let proxy: ScrollViewProxy
    var hasOlderMessages: Bool = false
    var isLoadingMore: Bool = false
    var onLoadMore: (() -> Void)? = nil
    var onNavigate: (() -> Void)? = nil
    @State private var hoveredId: String? = nil

    private let nodeH: CGFloat = 28

    var body: some View {
        VStack(spacing: 0) {
            if hasOlderMessages {
                Button { onLoadMore?() } label: {
                    Group {
                        if isLoadingMore {
                            ProgressView()
                                .progressViewStyle(.circular)
                                .scaleEffect(0.45)
                        } else {
                            Image(systemName: "chevron.up")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .help("Load earlier messages")
                Rectangle()
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 1.5, height: 4)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                TimelineNodeView(
                    isFirst: i == 0 && !hasOlderMessages,
                    isLast: i == items.count - 1,
                    isHovered: hoveredId == item.id,
                    previewText: item.text,
                    height: nodeH
                )
                .onHover { h in
                    withAnimation(.spring(response: 0.16, dampingFraction: 0.72)) {
                        hoveredId = h ? item.id : nil
                    }
                }
                .onTapGesture {
                    onNavigate?()
                    proxy.scrollTo(item.id, anchor: .top)
                    Task {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(item.id, anchor: .top)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
        .frame(width: 22)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
    }
}

private struct TimelineNodeView: View {
    let isFirst: Bool
    let isLast: Bool
    let isHovered: Bool
    let previewText: String
    let height: CGFloat
    private let dot: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.accentColor.opacity(isFirst ? 0 : 0.18))
                .frame(width: 1.5, height: (height - dot) / 2)
            Circle()
                .fill(isHovered ? Color.accentColor : Color.accentColor.opacity(0.38))
                .frame(width: dot, height: dot)
            .scaleEffect(isHovered ? 1.65 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: isHovered)
            Rectangle()
                .fill(Color.accentColor.opacity(isLast ? 0 : 0.18))
                .frame(width: 1.5, height: (height - dot) / 2)
        }
        .frame(width: 22, height: height)
        .contentShape(Rectangle())
        .overlay(alignment: .leading) {
            if isHovered {
                TimelinePreviewCard(text: previewText)
                    .offset(x: -(200 + 10))
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.94, anchor: .trailing)),
                        removal: .opacity
                    ))
            }
        }
    }
}

private struct TimelinePreviewCard: View {
    let text: String

    private var preview: String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = t
            .replacingOccurrences(of: #"```[\s\S]*?```"#, with: "…", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`#>]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.count > 130 ? String(cleaned.prefix(130)) + "…" : cleaned
    }

    var body: some View {
        Text(preview.isEmpty ? text.prefix(130) + (text.count > 130 ? "…" : "") : preview)
            .font(.caption2)
            .lineLimit(4)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(width: 200, alignment: .leading)
            .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.13), radius: 8, y: 3)
    }
}

// MARK: - Thinking indicator (shown while agent hasn't yet produced content)

/// Matches the reasoning block header visually so the transition to real
/// reasoning content is seamless.
private struct ThinkingIndicator: View {
    @State private var phase: Int = 0

    var body: some View {
        FlowStep(iconName: "clock", showLine: false) {
            HStack(spacing: 4) {
                Text("Thinking")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    ForEach(0..<3) { i in
                        Circle()
                            .fill(Color.secondary.opacity(phase == i ? 0.75 : 0.25))
                            .frame(width: 4, height: 4)
                            .animation(.easeInOut(duration: 0.4), value: phase)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 450_000_000)
                phase = (phase + 1) % 3
            }
        }
    }
}



// MARK: - Composer height preference

/// Bubbles the live-measured composer height up so MessageList can size its
/// bottom breathing room dynamically. Without this the last message gets
/// hidden behind a tall composer (provider chips, attachments, etc).
private struct ComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        let next = nextValue()
        if next > 0 { value = next }
    }
}

// MARK: - Pending creating view (optimistic bubble + "Starting agent…" spinner)

private struct PendingCreatingView: View {
    let text: String
    let images: [PendingImageAttachment]
    /// Drives the bottom-anchor trick so the user bubble lands in the same
    /// y-position it will occupy once MessageList takes over. Without this,
    /// the bubble starts near the top of the view here, jumps to the top
    /// again briefly when MessageList mounts (before its deferred scroll
    /// fires), then settles at the bottom — visible as a top-then-down
    /// bounce on every new conversation.
    var availableHeight: CGFloat = 500
    var bottomPadding: CGFloat = 210

    var body: some View {
        ScrollView {
            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(maxWidth: .infinity, minHeight: availableHeight)
                VStack(alignment: .trailing, spacing: 14) {
                    userBubble
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Starting agent…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, bottomPadding)
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private var userBubble: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 4) {
                if !images.isEmpty {
                    UserBubbleImages(images: images)
                }
                if !text.isEmpty {
                    MarkdownBodyView(text: text)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        .frame(maxWidth: 520, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - AskUserQuestion picker

/// Inline UI for an `AskUserQuestion` permission request. For each question
/// the user sees the provided option labels as clickable chips plus a text
/// field for a free-form answer (the implicit "Other" path). Submit is
/// disabled until every question has a non-empty answer.
private struct AskUserQuestionView: View {
    let questions: [AskUserQuestion.Question]
    let onSubmit: ([String: String]) -> Void
    let onCancel: () -> Void

    @State private var draft: [String: String] = [:]

    private var canSubmit: Bool {
        questions.allSatisfy { !(draft[$0.header] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Question from agent")
                .font(.callout.bold())
                .foregroundStyle(.orange)
            ForEach(questions) { q in
                questionRow(q)
            }
            HStack(spacing: 8) {
                Button("Submit") { onSubmit(draft) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!canSubmit)
                Button("Skip") { onCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private func questionRow(_ q: AskUserQuestion.Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !q.header.isEmpty {
                Text(q.header)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(q.question)
                .font(.callout)
                .textSelection(.enabled)
            // Options as wrap-flow chips
            FlowLayout(spacing: 6) {
                ForEach(q.options) { opt in
                    let selected = (draft[q.header] ?? "") == opt.label
                    Button {
                        draft[q.header] = opt.label
                    } label: {
                        Text(opt.label)
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                selected
                                ? Color.accentColor.opacity(0.22)
                                : Color.secondary.opacity(0.12),
                                in: RoundedRectangle(cornerRadius: 14)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 14)
                                    .stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1)
                            )
                            .help(opt.description ?? "")
                    }
                    .buttonStyle(.plain)
                }
            }
            TextField(
                "Other (type a custom answer)…",
                text: Binding(
                    get: { draft[q.header] ?? "" },
                    set: { draft[q.header] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)
            .onSubmit {
                if canSubmit { onSubmit(draft) }
            }
        }
        .padding(.vertical, 2)
    }
}

/// Minimal wrap-flow layout for chip rows. Wraps to a new line when the
/// next subview wouldn't fit on the current row.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            totalWidth = max(totalWidth, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(totalWidth, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.minX + maxWidth, x > bounds.minX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
