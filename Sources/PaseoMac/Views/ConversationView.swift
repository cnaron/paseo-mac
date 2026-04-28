import SwiftUI

struct ConversationView: View {
    @Environment(AppViewModel.self) private var app
    let agentId: String
    @State private var searchText: String = ""
    @State private var isSearchVisible: Bool = false
    @State private var showFileBrowser: Bool = false
    /// Hoisted out of FileBrowserView so the inspector closure re-render can't reset it.
    @State private var browserSelectedFile: String? = nil
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
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "ellipsis.bubble")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(.tertiary)
                            Text("Type a message to start the conversation")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Color.clear.frame(height: 120)
                        }
                        .frame(maxWidth: .infinity)
                    } else {
                        MessageList(vm: vm, availableHeight: geo.size.height, searchText: searchText)
                    }
                }
                .overlay(alignment: .bottom) {
                    if searchText.isEmpty {
                        ComposerView(vm: vm)
                            .padding(.bottom, 20)
                    }
                }
            }
        }
        .navigationTitle(isPending ? "New Conversation" : (agent()?.displayName ?? ""))
        .toolbar {
            ToolbarItem(placement: .principal) {
                ClaudeCodeVersionChip()
            }
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
                Button { toggleSearch() } label: {
                    Image(systemName: isSearchVisible ? "magnifyingglass.circle.fill" : "magnifyingglass")
                }
                .help(isSearchVisible ? "Close search" : "Search messages (⌘F)")
            }
            ToolbarItem(placement: .primaryAction) {
                Button { showFileBrowser.toggle() } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help(showFileBrowser ? "Close file browser" : "Browse files")
                .disabled(agent()?.cwd == nil)
            }
        }
        .inspector(isPresented: $showFileBrowser) {
            if let cwd = agent()?.cwd {
                FileBrowserView(rootPath: cwd, selectedFile: $browserSelectedFile)
                    .inspectorColumnWidth(min: 260, ideal: 340, max: 560)
            }
        }
        .onChange(of: showFileBrowser) { _, shown in
            if !shown { browserSelectedFile = nil }
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
        app.agents.first { $0.id == agentId }
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
    let tool: ConversationViewModel.ToolInfo?
    let toolCluster: [ConversationViewModel.ToolInfo]
    let images: [PendingImageAttachment]
    let modelUsed: String?
    let durationSec: TimeInterval?
}

private func groupRows(_ rows: [ConversationViewModel.Row]) -> [BubbleGroup] {
    var out: [BubbleGroup] = []
    let mergeable: Set<String> = ["user", "assistant", "reasoning"]

    for row in rows {
        // Coalesce consecutive tool rows into a tight cluster so a run of
        // Read → Edit → Bash doesn't get spread out by the inter-bubble gap.
        if row.kind == "tool", let info = row.tool,
           let last = out.last, last.kind == "tool_cluster" {
            var cluster = last.toolCluster
            cluster.append(info)
            out.removeLast()
            out.append(BubbleGroup(
                id: last.id,
                kind: "tool_cluster",
                text: "",
                timestamp: last.timestamp,
                tool: nil,
                toolCluster: cluster,
                images: [],
                modelUsed: nil,
                durationSec: nil
            ))
            continue
        }
        if row.kind == "tool", let info = row.tool {
            out.append(BubbleGroup(
                id: row.id,
                kind: "tool_cluster",
                text: "",
                timestamp: row.timestamp,
                tool: nil,
                toolCluster: [info],
                images: [],
                modelUsed: nil,
                durationSec: nil
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
                tool: nil,
                toolCluster: [],
                images: last.images + row.images,
                modelUsed: last.modelUsed ?? row.modelUsed,
                durationSec: row.durationSec ?? last.durationSec
            ))
        } else {
            out.append(BubbleGroup(
                id: row.id,
                kind: row.kind,
                text: row.text,
                timestamp: row.timestamp,
                tool: row.tool,
                toolCluster: [],
                images: row.images,
                modelUsed: row.modelUsed,
                durationSec: row.durationSec
            ))
        }
    }
    return out
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
    var availableHeight: CGFloat = 500
    var searchText: String = ""

    private var displayedRows: [ConversationViewModel.Row] {
        guard !searchText.isEmpty else { return vm.rows }
        let q = searchText.lowercased()
        return vm.rows.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        let grouped = groupMessages(displayedRows)
        ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    ZStack(alignment: .bottom) {
                        Color.clear
                            .frame(maxWidth: .infinity, minHeight: availableHeight)
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: 0).onAppear {
                                if !vm.rows.isEmpty {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
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
                            ForEach(grouped) { gm in
                                MessageBubble(
                                    group: gm.group,
                                    showConnector: gm.showConnector,
                                    isStreaming: vm.isAgentWorking && gm.id == lastAssistantId,
                                    onApprovePermission: { Task { await vm.approvePermission() } },
                                    onDenyPermission: { Task { await vm.denyPermission() } }
                                )
                                .id(gm.id)
                                .transition(.opacity)
                            }
                            if vm.isLoading {
                                ProgressView().frame(maxWidth: .infinity).padding()
                            }
                            if searchText.isEmpty && vm.isAgentWorking && !vm.isLoading && !hasCurrentTurnContent(vm.rows) {
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
                                if vm.isAgentWorking,
                                   let model = vm.currentDisplayModel ?? vm.lastTurnModel {
                                    TurnStatusBar(
                                        model: model,
                                        startedAt: vm.turnStartedAt,
                                        isWorking: true
                                    )
                                } else if !vm.isAgentWorking, let model = vm.lastTurnModel {
                                    TurnStatusBar(
                                        model: model,
                                        startedAt: nil,
                                        isWorking: false,
                                        duration: vm.lastTurnDuration
                                    )
                                }
                            }
                            Color.clear.frame(height: searchText.isEmpty ? 210 : 24) // breathing room
                            Color.clear.frame(height: 1).id("bottom")
                                .onAppear { isNearBottom = true; hasNewContent = false }
                                .onDisappear { isNearBottom = false }
                        }
                        .padding(.vertical, 16)
                        .padding(.trailing, 44)
                    }
                }
                .onChange(of: vm.rows.count) { _, _ in
                    let lastIsUser = vm.rows.last?.kind == "user"
                    if isNearBottom || lastIsUser {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } else {
                        hasNewContent = true
                    }
                }
                .onChange(of: vm.rows.last?.text ?? "") { _, _ in
                    if isNearBottom {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    } else {
                        hasNewContent = true
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
                        onLoadMore: { Task { await vm.loadOlderMessages() } }
                    )
                    .padding(.trailing, 20)
                    .padding(.vertical, 60)
                }
            }
        }
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

private struct MessageBubble: View {
    let group: BubbleGroup
    let showConnector: Bool
    var isStreaming: Bool = false
    var onApprovePermission: (() -> Void)? = nil
    var onDenyPermission: (() -> Void)? = nil
    @State private var reasoningExpanded: Bool = false
    @State private var isHoveredForCopy: Bool = false
    @State private var isExpanded: Bool = false

    private var isLong: Bool { group.text.count > 500 }

    var body: some View {
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
                                MarkdownBodyView(text: group.text)
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
                                MarkdownBodyView(text: group.text)
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

    // MARK: Assistant narrative — clock icon, inline text, copy button on hover

    private var assistantTimelineItem: some View {
        FlowStep(iconName: "clock", showLine: showConnector) {
            VStack(alignment: .leading, spacing: 4) {
                MarkdownBodyView(text: group.text, isStreaming: isStreaming)
                if let model = group.modelUsed {
                    TurnMetaChip(model: model, durationSec: group.durationSec)
                }
            }
        }
        .onHover { isHoveredForCopy = $0 }
        .overlay(alignment: .topTrailing) {
            if isHoveredForCopy {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(group.text, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .padding(5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(4)
                .help("Copy message")
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
                    MarkdownBodyView(text: group.text)
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
                    ToolRowTimeline(info: info)
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
                .foregroundStyle(group.kind == "error" ? Color.red : Color.secondary)
        }
    }

    // MARK: Permission request — approve / deny buttons

    private var permissionTimelineItem: some View {
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

    // MARK: Attention required — informational banner

    private var attentionTimelineItem: some View {
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

    private var sideIcon: String {
        switch group.kind {
        case "error": "exclamationmark.circle"
        case "todo": "checklist"
        default: "info.circle"
        }
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private func formatTimestamp(_ iso: String) -> String? {
        let frac = ISO8601DateFormatter()
        frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        guard let date = frac.date(from: iso) ?? plain.date(from: iso) else { return nil }
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "just now" }
        if diff < 3600 { return "\(Int(diff / 60))m ago" }
        if Calendar.current.isDateInToday(date) {
            return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
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
            Text(info.name)
                .font(.callout)
                .foregroundStyle(.secondary)

            if let target = info.target, !target.isEmpty {
                if target.hasPrefix("/") {
                    Button {
                        let (filePath, _) = parseFilePath(target)
                        NSWorkspace.shared.open(URL(fileURLWithPath: filePath))
                    } label: {
                        Text(truncate(target, max: 64))
                            .font(.callout)
                            .foregroundStyle(Color.accentColor.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .help("Open file")
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
        if let colon = raw.lastIndex(of: ":"),
           colon > raw.startIndex,
           let line = Int(raw[raw.index(after: colon)...]) {
            return (String(raw[..<colon]), line)
        }
        return (raw, nil)
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
        u.contextWindowUsedTokens != nil
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
                if let ns = NSImage(data: img.pngData) {
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
            if let ns = NSImage(data: img.pngData) {
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

// MARK: - Turn status bar (live timer + model, shown during and after a turn)

/// Persistent status bar below the last reply. While the agent is working it
/// ticks every second; after completion it freezes on the final duration.
/// Styled like Claude Code's bottom status line.
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

private struct TurnStatusBar: View {
    let model: String
    let startedAt: Date?
    let isWorking: Bool
    var duration: TimeInterval? = nil

    @State private var elapsed: TimeInterval = 0

    var body: some View {
        HStack(spacing: 6) {
            if isWorking {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.7)
            } else {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
            }
            Text(prettyModel(model))
                .font(.caption)
            Text("·")
                .foregroundStyle(.tertiary)
            Text(displayTime)
                .font(.caption.monospacedDigit())
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 58)  // align with timeline content column (16 padding + 22 icon + 10 gap = 48, +10 breathing room)
        .padding(.trailing, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
        .task(id: isWorking) {
            guard isWorking, let start = startedAt else { return }
            while !Task.isCancelled {
                elapsed = Date().timeIntervalSince(start)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }

    private var displayTime: String {
        let t = isWorking ? elapsed : (duration ?? elapsed)
        if t < 60 { return String(format: "%.1fs", t) }
        return String(format: "%dm %ds", Int(t) / 60, Int(t) % 60)
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
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(item.id, anchor: .top)
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
