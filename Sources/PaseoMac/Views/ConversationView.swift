import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
private func openConversationURL_claudecode_20260709(_ url: URL) {
    #if os(macOS)
    NSWorkspace.shared.open(url)
    #elseif os(iOS)
    UIApplication.shared.open(url, options: [:], completionHandler: nil)
    #endif
}

struct ConversationView: View {
    @Environment(AppViewModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(SettingsStore.self) private var settings
    let agentId: String
    @State private var searchText: String = ""
    @State private var isSearchVisible: Bool = false
    @State private var isResumingArchived: Bool = false
    @State private var gitHubUrl: String? = nil
    @State private var isFileExplorerVisible: Bool = false
    /// Live-measured composer height. Drives the bottom breathing room in
    /// MessageList so the last message stays above the composer even when
    /// it grows (e.g. providers populate after reconnect and chips appear).
    @State private var measuredComposerHeight: CGFloat = 120
    @State private var searchTask: Task<Void, Never>? = nil
    @FocusState private var searchFocused: Bool

    var body: some View {
        let isPending = agentId == AppViewModel.pendingAgentId
        let vm = app.conversation(for: agentId)
        VStack(spacing: 0) {
            // Inline search bar (toggled by toolbar button)
            if isSearchVisible {
                searchBar
            }
            HStack(spacing: 0) {
                GeometryReader { geo in
                    Group {
                        if isPending {
                            if let creatingText = app.creatingAgentText {
                                PendingCreatingView(
                                    text: creatingText,
                                    images: app.creatingAgentImages,
                                    availableHeight: geo.size.height,
                                    bottomPadding: max(measuredComposerHeight, 110)
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
                                bottomPadding: max(measuredComposerHeight, 110),
                                workspaceCwd: agent()?.cwd,
                                agentProvider: agent()?.provider,
                                agentModel: agent()?.model,
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
                if isFileExplorerVisible, let cwd = agent()?.cwd {
                    Divider()
                    WorkspaceFileTreeView(cwd: cwd)
                        .frame(width: 250)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .onPreferenceChange(ComposerHeightKey.self) { newValue in
            // Only trust positive measurements; ignore zero-init.
            if newValue > 0 { measuredComposerHeight = newValue }
        }
        .navigationTitle(isPending ? "New Conversation" : {
            let name = agent()?.displayName ?? ""
            return name.count > 25 ? String(name.prefix(25)) + "..." : name
        }())
        .toolbar {
            #if os(macOS)
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
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isFileExplorerVisible.toggle()
                    }
                } label: {
                    Image(systemName: isFileExplorerVisible ? "sidebar.right" : "folder")
                }
                .help(isFileExplorerVisible ? "Hide File Explorer" : "Show File Explorer")
                .disabled(agent()?.cwd == nil)
            }
            if let urlStr = gitHubUrl, let url = URL(string: urlStr) {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        openConversationURL_claudecode_20260709(url)
                    } label: {
                        Label("Open", systemImage: "arrow.up.right.square")
                    }
                    .help("Open repository on GitHub")
                }
            }
            #endif
        }
        #if os(iOS)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            iosFloatingHeader_claudecode_20260709(vm: vm, isPending: isPending)
        }
        .background(Color(uiColor: .systemBackground))
        #endif
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
        .background(PlatformColor.controlBackground)
    }

    #if os(iOS)
    private func iosFloatingHeader_claudecode_20260709(
        vm: ConversationViewModel,
        isPending: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            HStack(spacing: 6) {
                if vm.isAgentWorking {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(iosTitle_claudecode_20260709(isPending: isPending))
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let a = agent(), let model = a.model, !model.isEmpty {
                    Text(shortModelName_claudecode_20260709(model))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Color.secondary.opacity(0.09), in: Capsule())

            Button {
                if let cwd = agent()?.cwd {
                    Task { await app.createAgent(cwd: cwd) }
                }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            .disabled(agent() == nil)

            Menu {
                Button {
                    toggleSearch()
                } label: {
                    Label(isSearchVisible ? "Close Search" : "Search", systemImage: "magnifyingglass")
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isFileExplorerVisible.toggle()
                    }
                } label: {
                    Label(isFileExplorerVisible ? "Hide Files" : "Files", systemImage: "folder")
                }
                .disabled(agent()?.cwd == nil)
                if let urlStr = gitHubUrl, let url = URL(string: urlStr) {
                    Button {
                        openConversationURL_claudecode_20260709(url)
                    } label: {
                        Label("Open Repository", systemImage: "arrow.up.right.square")
                    }
                }
                if !branchTargets.isEmpty {
                    Divider()
                    ForEach(branchTargets, id: \.provider) { entry in
                        Button {
                            Task { await app.branchAgent(fromAgentId: agentId, newProvider: entry.provider) }
                        } label: {
                            Label(entry.label + (entry.isCurrent ? " (current)" : ""), systemImage: ProviderIcon.symbolName(for: entry.provider))
                        }
                        .disabled(entry.isCurrent || entry.status != "ready")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 19, weight: .bold))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .background(Color(uiColor: .systemBackground).opacity(0.72))
    }

    private func iosTitle_claudecode_20260709(isPending: Bool) -> String {
        if isPending { return "New chat" }
        let name = agent()?.displayName ?? "Paseo"
        return name.count > 18 ? String(name.prefix(18)) + "..." : name
    }

    private func shortModelName_claudecode_20260709(_ model: String) -> String {
        model
            .replacingOccurrences(of: "claude-", with: "")
            .replacingOccurrences(of: "gpt-", with: "")
            .replacingOccurrences(of: "-latest", with: "")
    }
    #endif

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
        #if os(macOS)
        openWindow(value: WorkspaceFilePreviewRoute(cwd: cwd, path: "."))
        #elseif os(iOS)
        app.activeWorkspaceRoute = WorkspaceFilePreviewRoute(cwd: cwd, path: ".")
        #endif
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

private struct MessageTurn: Identifiable {
    let id: String
    var userMessage: GroupedMessage?
    var intermediateMessages: [GroupedMessage] = []
    var assistantMessage: GroupedMessage?
}

private func groupTurns(_ grouped: [GroupedMessage], isAgentWorking: Bool) -> [MessageTurn] {
    var turns: [MessageTurn] = []

    // Step 1: Split grouped messages into segments by user messages
    var segments: [[GroupedMessage]] = []
    var currentSegment: [GroupedMessage] = []

    for gm in grouped {
        if gm.group.kind == "user" {
            if !currentSegment.isEmpty {
                segments.append(currentSegment)
            }
            currentSegment = [gm]
        } else {
            currentSegment.append(gm)
        }
    }
    if !currentSegment.isEmpty {
        segments.append(currentSegment)
    }

    // Step 2: Convert each segment into a MessageTurn
    for (segIdx, segment) in segments.enumerated() {
        var userMsg: GroupedMessage? = nil
        var assistantMsg: GroupedMessage? = nil
        var intermediateMsgs: [GroupedMessage] = []

        if let first = segment.first, first.group.kind == "user" {
            userMsg = first
        }

        let isLastSegment = (segIdx == segments.count - 1)
        let isRunningTurn = isAgentWorking && isLastSegment

        if isRunningTurn {
            // Fold everything under intermediate messages while executing the turn
            for gm in segment {
                if gm.group.kind == "user" {
                    continue
                }
                intermediateMsgs.append(gm)
            }
        } else {
            // Every "assistant" kind group in the segment is real reply
            // text — it always belongs in the visible summary, regardless
            // of where it falls relative to tool calls. Only genuinely
            // non-reply content (tool calls, reasoning/thinking, permission
            // asks) belongs in the folded "process" bucket.
            //
            // This used to be stricter: only the single literal-last
            // "assistant" group counted as the visible summary, and every
            // earlier one — even if it was just an earlier paragraph of the
            // same reply, split apart because a tool call happened to land
            // between paragraphs — fell into the fold. That's backwards:
            // "this turn touched a tool call somewhere" isn't a reason to
            // hide reply text, it's just where that tool call happened to
            // occur. Now all assistant chunks concatenate into one visible
            // summary in original order; the tool call itself still folds,
            // it just no longer drags surrounding reply text down with it.
            // 2026.07.15 Naron
            var assistantGroups: [GroupedMessage] = []
            for gm in segment {
                if gm.group.kind == "user" {
                    continue
                }
                if gm.group.kind == "assistant" {
                    assistantGroups.append(gm)
                } else {
                    intermediateMsgs.append(gm)
                }
            }

            if let last = assistantGroups.last {
                // 折叠掉正式回复前的过程叙述：多于一条 assistant chunk 时，只有
                // 最后一条是真正对外的回复，之前的（agent 在工具调用之间顺手
                // 吐出的自述/状态播报）全部折叠进 intermediateMessages（以
                // reasoning 样式展示），跟复制逻辑（只取最后一条 chunk）保持
                // 一致。只有一条 chunk 时完全不受影响。同步自 paseo-mac
                // 2026.07.16 Naron 的修复。
                if assistantGroups.count > 1 {
                    let priorChunks = assistantGroups[0..<(assistantGroups.count - 1)]
                    let preambleText = priorChunks.map { $0.group.text }.joined()
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !preambleText.isEmpty {
                        intermediateMsgs.append(GroupedMessage(
                            id: "\(last.id)-preamble",
                            group: BubbleGroup(
                                id: "\(last.group.id)-preamble",
                                kind: "reasoning",
                                text: preambleText,
                                timestamp: last.group.timestamp,
                                messageId: nil,
                                tool: nil,
                                toolCluster: [],
                                images: [],
                                modelUsed: nil,
                                durationSec: nil,
                                permissionRequestId: nil
                            ),
                            showConnector: false
                        ))
                    }
                }

                let combinedText = last.group.text
                let combinedImages = last.group.images
                assistantMsg = GroupedMessage(
                    id: last.id,
                    group: BubbleGroup(
                        id: last.group.id,
                        kind: "assistant",
                        text: combinedText,
                        timestamp: last.group.timestamp,
                        messageId: last.group.messageId,
                        tool: nil,
                        toolCluster: [],
                        images: combinedImages,
                        modelUsed: last.group.modelUsed,
                        durationSec: last.group.durationSec,
                        permissionRequestId: last.group.permissionRequestId
                    ),
                    showConnector: last.showConnector
                )
            }
        }

        let turnId = segment.first?.id ?? UUID().uuidString
        turns.append(MessageTurn(
            id: turnId,
            userMessage: userMsg,
            intermediateMessages: intermediateMsgs,
            assistantMessage: assistantMsg
        ))
    }

    return turns
}

// MARK: - Message list

private struct ScrollState_claudecode_20260722: Equatable {
    let isNearBottom: Bool
    let isAtBottom: Bool
}

private struct ScrollStateKey_claudecode_20260723: PreferenceKey {
    static let defaultValue = ScrollState_claudecode_20260722(isNearBottom: true, isAtBottom: true)
    static func reduce(value: inout ScrollState_claudecode_20260722, nextValue: () -> ScrollState_claudecode_20260722) {
        value = nextValue()
    }
}

/// 老系统（< iOS 18 / < macOS 15）才需要 GeometryReader + PreferenceKey 探
/// 针来跟踪"离底部多远"；现代系统由 onScrollGeometryChange 直接拿滚动几何，
/// 这个探针在滚动的每一帧都触发 preference 传播、白白增加布局开销（大会话
/// 里就是肉眼可见的卡顿）。按可用性只在老路径安装。2026.07.23 Naron
private struct LegacyScrollStateProbe_claudecode_20260723: ViewModifier {
    let availableHeight: CGFloat

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content
        } else {
            content.background(
                GeometryReader { geo in
                    let maxY = geo.frame(in: .named("ScrollViewSpace")).maxY
                    let distanceFromBottom = max(0, maxY - availableHeight)
                    Color.clear.preference(
                        key: ScrollStateKey_claudecode_20260723.self,
                        value: ScrollState_claudecode_20260722(
                            isNearBottom: distanceFromBottom <= 100,
                            isAtBottom: distanceFromBottom <= 20
                        )
                    )
                }
            )
        }
    }
}

private struct NearBottomTrackingModifier_claudecode_20260714: ViewModifier {
    let availableHeight: CGFloat
    @Binding var isNearBottom: Bool
    @Binding var isAtBottom: Bool
    @Binding var hasNewContent: Bool
    @Binding var trackingGraceActive: Bool
    @Binding var isUserScrolling: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            content.onScrollPhaseChange { _, newPhase in
                // 用户手指/触控板正在驱动滚动（含惯性）期间，一切程序化
                // scrollTo 都会打断手势、把页面拽回去——这正是"回看历史
                // 上滑总被回坐"的手感来源。.animating 是程序化滚动自己，
                // 不算用户操作。2026.07.23 Naron
                let userDriven: Bool
                switch newPhase {
                case .tracking, .interacting, .decelerating: userDriven = true
                default: userDriven = false
                }
                if isUserScrolling != userDriven {
                    isUserScrolling = userDriven
                }
            }
            .onScrollGeometryChange(for: ScrollState_claudecode_20260722.self) { geometry in
                let maxOffset = max(0, geometry.contentSize.height - geometry.containerSize.height)
                let distanceFromBottom = maxOffset - geometry.contentOffset.y
                return ScrollState_claudecode_20260722(
                    isNearBottom: distanceFromBottom <= 100,
                    isAtBottom: distanceFromBottom <= 20
                )
            } action: { _, state in
                guard !trackingGraceActive else { return }
                if isNearBottom != state.isNearBottom {
                    isNearBottom = state.isNearBottom
                }
                if isAtBottom != state.isAtBottom {
                    isAtBottom = state.isAtBottom
                    if state.isAtBottom {
                        hasNewContent = false
                    }
                }
            }
        } else {
            content.onPreferenceChange(ScrollStateKey_claudecode_20260723.self) { state in
                guard !trackingGraceActive else { return }
                if isNearBottom != state.isNearBottom {
                    isNearBottom = state.isNearBottom
                }
                if isAtBottom != state.isAtBottom {
                    isAtBottom = state.isAtBottom
                    if state.isAtBottom {
                        hasNewContent = false
                    }
                }
            }
        }
    }
}

struct MessageList: View {
    @Bindable var vm: ConversationViewModel
    @Environment(SettingsStore.self) private var settings
    @State private var isNearBottom: Bool = true
    @State private var isAtBottom: Bool = true
    @State private var showJumpButton_claudecode_20260714: Bool = false
    @State private var jumpButtonShowTask_claudecode_20260714: Task<Void, Never>? = nil
    @State private var trackingGraceActive_claudecode_20260714: Bool = true
    @State private var hasNewContent: Bool = false
    @State private var suppressAutoScroll: Bool = false
    @State private var isUserScrolling_claudecode_20260723: Bool = false
    @State private var lastAutoScrollAt_claudecode_20260711: Date = .distantPast
    var availableHeight: CGFloat = 500
    var searchText: String = ""
    var bottomPadding: CGFloat = 210
    var workspaceCwd: String? = nil
    var agentProvider: String? = nil
    var agentModel: String? = nil
    var agentCapabilities: AgentCapabilityFlags? = nil
    var onRewind: ((String, AgentRewindMode, String) -> Void)? = nil
    var jumpListPresented: Binding<Bool>? = nil

    private var displayedRows: [ConversationViewModel.Row] {
        let base = vm.rows.filter {
            if $0.tool?.name == "AskUserQuestion" { return false }
            if $0.kind == "user" {
                let trimmed = $0.text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if trimmed == "y" || trimmed == "n" { return false }
            }
            return true
        }
        guard !searchText.isEmpty else { return base }
        let q = searchText.lowercased()
        return base.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        let grouped = groupMessages(displayedRows)
        let turns = groupTurns(grouped, isAgentWorking: vm.isAgentWorking)
        let lastTurnId = turns.last?.id
        let segmentCopyTexts = Self.computeSegmentCopyTexts(grouped)

        @ViewBuilder
        func messageListContent(proxy: ScrollViewProxy) -> some View {
            if vm.hasOlderMessages {
                Button {
                    let anchorId = turns.first?.id
                    isNearBottom = false
                    isAtBottom = false
                    suppressAutoScroll = true
                    Task {
                        await vm.loadOlderMessages()
                        if let anchorId {
                            withTransaction(Transaction(animation: nil)) {
                                proxy.scrollTo(anchorId, anchor: .top)
                            }
                        }
                        suppressAutoScroll = false
                    }
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
            ForEach(turns) { turn in
                TurnItemView(
                    turn: turn,
                    isLastTurn: turn.id == lastTurnId,
                    isAgentWorking: vm.isAgentWorking,
                    workspaceCwd: workspaceCwd,
                    agentProvider: agentProvider,
                    agentModel: agentModel,
                    agentCapabilities: agentCapabilities,
                    pendingPermission: vm.pendingPermission,
                    resolvedPermissionIds: vm.resolvedPermissionIds,
                    segmentCopyTexts: segmentCopyTexts,
                    availableHeight: availableHeight,
                    onApprovePermission: { Task { await vm.approvePermission() } },
                    onDenyPermission: { Task { await vm.denyPermission() } },
                    onSubmitQuestionAnswers: { answers in
                        Task { await vm.submitQuestionAnswers(answers) }
                    },
                    onRewind: { messageId, mode, text in
                        onRewind?(messageId, mode, text)
                    },
                    onToggleExpanded: {
                        guard isAtBottom else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(turn.id, anchor: .top)
                        }
                    }
                )
                .id(turn.id)
                .transition(.opacity)
            }
            if vm.isLoading && vm.rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding()
            }
            if searchText.isEmpty && vm.isAgentWorking && !vm.isLoading && !hasCurrentTurnContent(vm.rows) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking...")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            Color.clear.frame(height: bottomPadding).id("bottom")
        }

        return ScrollViewReader { proxy in
            ZStack(alignment: .bottom) {
                ScrollView {
                    if turns.count <= 3 {
                        VStack(alignment: .leading, spacing: CGFloat(settings.bubbleGap)) {
                            messageListContent(proxy: proxy)
                        }
                        .padding(.vertical, 16)
                        #if os(iOS)
                        .padding(.horizontal, 18)
                        #else
                        .padding(.trailing, 44)
                        #endif
                        .modifier(LegacyScrollStateProbe_claudecode_20260723(availableHeight: availableHeight))
                    } else {
                        LazyVStack(alignment: .leading, spacing: CGFloat(settings.bubbleGap)) {
                            messageListContent(proxy: proxy)
                        }
                        .padding(.vertical, 16)
                        #if os(iOS)
                        .padding(.horizontal, 18)
                        #else
                        .padding(.trailing, 44)
                        #endif
                        .modifier(LegacyScrollStateProbe_claudecode_20260723(availableHeight: availableHeight))
                    }
                }
                .coordinateSpace(name: "ScrollViewSpace")
                .modifier(NearBottomTrackingModifier_claudecode_20260714(
                    availableHeight: availableHeight,
                    isNearBottom: $isNearBottom,
                    isAtBottom: $isAtBottom,
                    hasNewContent: $hasNewContent,
                    trackingGraceActive: $trackingGraceActive_claudecode_20260714,
                    isUserScrolling: $isUserScrolling_claudecode_20260723
                ))
                .task(id: vm.agentId) {
                    trackingGraceActive_claudecode_20260714 = true
                    isNearBottom = true
                    isAtBottom = true
                    showJumpButton_claudecode_20260714 = false
                    jumpButtonShowTask_claudecode_20260714?.cancel()

                    if let lastTurnId = turns.last?.id {
                        withTransaction(Transaction(animation: nil)) {
                            proxy.scrollTo(lastTurnId, anchor: .bottom)
                        }
                    }
                    withTransaction(Transaction(animation: nil)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard !Task.isCancelled else { return }
                    withTransaction(Transaction(animation: nil)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard !Task.isCancelled else { return }
                    trackingGraceActive_claudecode_20260714 = false
                    withTransaction(Transaction(animation: nil)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
                .onChange(of: isNearBottom) { _, nearBottom in
                    jumpButtonShowTask_claudecode_20260714?.cancel()
                    if nearBottom {
                        showJumpButton_claudecode_20260714 = false
                    } else {
                        jumpButtonShowTask_claudecode_20260714 = Task {
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            guard !Task.isCancelled else { return }
                            showJumpButton_claudecode_20260714 = true
                        }
                    }
                }
                #if os(iOS)
                // .safeAreaInset(edge:.bottom) 挂在 MessageList 外层，不受
                // 这条影响，键盘弹出时仍会正常把输入框顶到键盘上方。
                // 2026.07.14 Naron
                .ignoresSafeArea(.keyboard, edges: .bottom)
                #endif
                .onAppear {
                    trackingGraceActive_claudecode_20260714 = true
                    isNearBottom = true
                    showJumpButton_claudecode_20260714 = false
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: vm.rows.last?.id) { oldLastId, newLastId in
                    guard !suppressAutoScroll else { return }
                    guard newLastId != nil else { return }
                    let lastIsUser = vm.rows.last?.kind == "user"
                    if lastIsUser {
                        // 用户消息不一定是"本机刚发的"：channel 转发、定时
                        // 任务、队列自动 flush 也会以 user row 落进来。正在
                        // 回看历史（不在底部）时被这种消息拽走是"上滑总被
                        // 回坐"的主因之一——只有本机主动发送才无条件跳转。
                        // 2026.07.23 Naron
                        guard isNearBottom || isRecentLocalSend_claudecode_20260723() else {
                            hasNewContent = true
                            return
                        }
                        if let lastTurn = turns.last {
                            withAnimation(.easeInOut(duration: 0.25)) {
                                proxy.scrollTo(lastTurn.id, anchor: .top)
                            }
                        }
                    } else {
                        if isNearBottom && !isUserScrolling_claudecode_20260723 {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        } else {
                            hasNewContent = true
                        }
                    }
                }
                .onChange(of: vm.rows.last?.text ?? "") { _, _ in
                    guard !suppressAutoScroll else { return }
                    if isNearBottom && !isUserScrolling_claudecode_20260723 {
                        scrollToBottomThrottled_claudecode_20260711(proxy: proxy)
                    } else if !isNearBottom {
                        hasNewContent = true
                    }
                }
                .onChange(of: vm.isAgentWorking) { _, isWorking in
                    guard !suppressAutoScroll else { return }
                    if isWorking {
                        // turn 开始在长跑会话里非常频繁（心跳/排程/channel
                        // 消息都会开新 turn）。不在底部时禁止拽人。
                        // 2026.07.23 Naron
                        guard (isNearBottom && !isUserScrolling_claudecode_20260723)
                            || isRecentLocalSend_claudecode_20260723() else { return }
                        if let lastTurn = turns.last {
                            Task {
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                withAnimation(.easeInOut(duration: 0.25)) {
                                    proxy.scrollTo(lastTurn.id, anchor: .top)
                                }
                            }
                        }
                    } else {
                        if isNearBottom && !isUserScrolling_claudecode_20260723 {
                            Task {
                                try? await Task.sleep(nanoseconds: 150_000_000)
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    proxy.scrollTo("bottom", anchor: .bottom)
                                }
                            }
                        }
                    }
                }

                if showJumpButton_claudecode_20260714 {
                    jumpToBottomButton(proxy: proxy, lastTurnId: lastTurnId)
                }
            }
            .modifier(UserMessageJumpAffordance_claudecode_20260713(
                grouped: grouped, proxy: proxy, vm: vm,
                firstTurnId: turns.first?.id,
                jumpListPresented: jumpListPresented,
                suppressAutoScroll: $suppressAutoScroll,
                isNearBottom: $isNearBottom,
                isAtBottom: $isAtBottom
            ))
        }
    }




    private func scrollToBottomThrottled_claudecode_20260711(proxy: ScrollViewProxy) {
        guard isNearBottom, !isUserScrolling_claudecode_20260723 else { return }
        let now = Date()
        guard now.timeIntervalSince(lastAutoScrollAt_claudecode_20260711) >= 0.12 else { return }
        lastAutoScrollAt_claudecode_20260711 = now
        proxy.scrollTo("bottom", anchor: .bottom)
    }

    /// 本机 3 秒内主动发送过消息（composer / interrupt / force send）。
    /// 用于区分"我刚发的、应该跳过去"和"外部到达的用户消息"。
    /// 2026.07.23 Naron
    private func isRecentLocalSend_claudecode_20260723() -> Bool {
        guard let at = vm.lastLocalSendAt_claudecode_20260723 else { return false }
        return Date().timeIntervalSince(at) < 3
    }

    /// Shared "how close to the bottom is the content container's own
    /// bottom edge" tracker, used as a `.background` on whichever container
    /// (ZStack for short conversations, LazyVStack for long ones) actually
    /// holds the message content. Reading the CONTAINER's frame — not a
    /// marker view buried inside it — is what makes this reliable
    /// regardless of LazyVStack virtualization or which branch is active.
    ///
    /// Reports through a PreferenceKey (read once, centrally, via
    /// `.onPreferenceChange` on the ScrollView) instead of `.onChange(of:
    /// geo.frame(...))` directly — `.onChange` on a GeometryReader-derived
    /// value is known to lag or get skipped during an active scroll drag in
    /// SwiftUI (it tends to only catch up once the gesture settles), which
    /// is exactly the "reached the bottom by hand-scrolling but the button
    /// doesn't go away" symptom: tapping the button worked because that
    /// path optimistically sets isNearBottom itself and never depended on
    /// this callback firing. PreferenceKey propagation is the mechanism
    /// SwiftUI actually keeps in sync during layout/scroll changes.


    /// For each response segment (content between user messages), collect all
    /// assistant bubble texts and store the combined string keyed to the LAST
    /// assistant bubble's id. All other assistant bubbles map to nothing, so
    /// only the final bubble in a segment shows the Copy button.
        private static func computeSegmentCopyTexts(_ groups: [GroupedMessage]) -> [String: String] {
        var result: [String: String] = [:]
        var segmentBubbles: [(id: String, text: String)] = []

        func flush() {
            guard !segmentBubbles.isEmpty else { return }
            let lastBubble = segmentBubbles[segmentBubbles.count - 1]
            result[lastBubble.id] = lastBubble.text
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

    private func jumpToBottomButton(proxy: ScrollViewProxy, lastTurnId: String?) -> some View {
        Button {
            isNearBottom = true
            isAtBottom = true
            hasNewContent = false
            if let lastTurnId {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(lastTurnId, anchor: .bottom)
                }
                Task {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    withTransaction(Transaction(animation: nil)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    withTransaction(Transaction(animation: nil)) {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 44, height: 44)
                if hasNewContent {
                    Circle()
                        .fill(settings.themeAccentColor)
                        .frame(width: 8, height: 8)
                        .offset(x: -8, y: 8)
                }
            }
            .foregroundStyle(.primary)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.14), radius: 10, y: 4)
            .contentShape(Circle())
        }
        // .plain 没有任何按下反馈，点击那一下手感很"空"，跟"响应迟钝"的
        // 观感是同一件事的两面。加一个轻微按下缩放，视觉上立刻确认"点到了"。
        // 2026.07.14 Naron
        .buttonStyle(JumpToBottomButtonStyle_claudecode_20260714())
        .frame(width: 56, height: 56)
        .padding(.trailing, 18)
        .padding(.bottom, 24)
        .zIndex(3)
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
        .animation(.easeInOut(duration: 0.2), value: hasNewContent)
    }
}

private struct JumpToBottomButtonStyle_claudecode_20260714: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

private struct TurnItemView: View {
    let turn: MessageTurn
    let isLastTurn: Bool
    let isAgentWorking: Bool
    let workspaceCwd: String?
    let agentProvider: String?
    let agentModel: String?
    let agentCapabilities: AgentCapabilityFlags?
    let pendingPermission: PermissionRequestPayload?
    let resolvedPermissionIds: Set<String>
    let segmentCopyTexts: [String: String]
    let availableHeight: CGFloat
    let onApprovePermission: (() -> Void)?
    let onDenyPermission: (() -> Void)?
    let onSubmitQuestionAnswers: (([String: String]) -> Void)?
    let onRewind: ((String, AgentRewindMode, String) -> Void)?
    let onToggleExpanded: (() -> Void)?

    var body: some View {
        EquatableTurnWrapper(
            turnId: turn.id,
            intermediateCount: turn.intermediateMessages.count,
            assistantText: turn.assistantMessage?.group.text,
            isLastTurn: isLastTurn,
            isAgentWorking: isAgentWorking,
            hasPendingPermission: (pendingPermission != nil),
            content: MessageTurnView(
                turn: turn,
                isLastTurn: isLastTurn,
                isAgentWorking: isAgentWorking,
                workspaceCwd: workspaceCwd,
                agentProvider: agentProvider,
                agentModel: agentModel,
                agentCapabilities: agentCapabilities,
                pendingPermission: pendingPermission,
                resolvedPermissionIds: resolvedPermissionIds,
                segmentCopyTexts: segmentCopyTexts,
                availableHeight: availableHeight,
                onApprovePermission: onApprovePermission,
                onDenyPermission: onDenyPermission,
                onSubmitQuestionAnswers: onSubmitQuestionAnswers,
                onRewind: onRewind,
                onToggleExpanded: onToggleExpanded
            )
        )
    }
}

private struct EquatableTurnWrapper: View, Equatable {
    let turnId: String
    let intermediateCount: Int
    let assistantText: String?
    let isLastTurn: Bool
    let isAgentWorking: Bool
    let hasPendingPermission: Bool
    let content: MessageTurnView

    nonisolated static func == (lhs: EquatableTurnWrapper, rhs: EquatableTurnWrapper) -> Bool {
        return lhs.turnId == rhs.turnId &&
               lhs.intermediateCount == rhs.intermediateCount &&
               lhs.assistantText == rhs.assistantText &&
               lhs.isLastTurn == rhs.isLastTurn &&
               lhs.isAgentWorking == rhs.isAgentWorking &&
               lhs.hasPendingPermission == rhs.hasPendingPermission
    }

    var body: some View {
        content
    }
}

private struct MessageTurnView: View {
    let turn: MessageTurn
    let isLastTurn: Bool
    @Environment(SettingsStore.self) private var settings
    let isAgentWorking: Bool
    let workspaceCwd: String?
    let agentProvider: String?
    let agentModel: String?
    let agentCapabilities: AgentCapabilityFlags?
    let pendingPermission: PermissionRequestPayload?
    let resolvedPermissionIds: Set<String>
    let segmentCopyTexts: [String: String]
    var availableHeight: CGFloat = 500
    var onApprovePermission: (() -> Void)? = nil
    var onDenyPermission: (() -> Void)? = nil
    var onSubmitQuestionAnswers: (([String: String]) -> Void)? = nil
    var onRewind: ((String, AgentRewindMode, String) -> Void)? = nil
    var onToggleExpanded: (() -> Void)? = nil

    @State private var turnExpanded: Bool = false
    @State private var hasManuallyToggled: Bool = false
    @State private var windowStartIndex: Int = -1
    @State private var windowEndIndex: Int = -1
    @State private var expansionSessionId: UUID = UUID()
    /// 折叠区域（含 header + 展开/预览内容）在 ScrollView 坐标系里的实时位置，
    /// 用来判断这次展开/折叠是否已经完全落在当前可见范围内。2026.07.13 Naron
    @State private var foldFrame_claudecode_20260713: CGRect = .zero

    private var isRunning: Bool {
        isAgentWorking && isLastTurn
    }

    private var isProcessActive: Bool {
        isRunning && turn.assistantMessage == nil
    }

    private var isExpandedEffective: Bool {
        if hasManuallyToggled {
            return turnExpanded
        }
        if isLastTurn {
            if pendingPermission != nil { return true }
            let hasUnresolvedPermission = turn.intermediateMessages.contains { gm in
                guard gm.group.kind == "permission" || gm.group.kind == "attention",
                      let reqId = gm.group.permissionRequestId else { return false }
                return !resolvedPermissionIds.contains(reqId)
            }
            if hasUnresolvedPermission { return true }
        }
        return false
    }

    private func compactStepLines() -> [String] {
        var lines: [String] = []
        for gm in turn.intermediateMessages {
            switch gm.group.kind {
            case "tool_cluster":
                for info in gm.group.toolCluster {
                    let name = cleanToolNameForSummary(info.name)
                    let target = (info.target ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    lines.append(target.isEmpty ? name : "\(name) \(target)")
                }
            case "reasoning", "assistant":
                let first = cleanTextForSummary(gm.group.text)
                if !first.isEmpty { lines.append(first) }
            case "compaction":
                if !gm.group.text.isEmpty { lines.append(gm.group.text) }
            case "permission", "attention":
                let first = cleanTextForSummary(gm.group.text)
                lines.append("! " + (first.isEmpty ? "Needs your input" : first))
            default:
                break
            }
        }
        return lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let userMsg = turn.userMessage {
                MessageBubble(
                    group: userMsg.group,
                    showConnector: userMsg.showConnector,
                    isStreaming: false,
                    isGroupStreaming: false,
                    workspaceCwd: workspaceCwd,
                    agentProvider: agentProvider,
                    agentModel: agentModel,
                    agentCapabilities: agentCapabilities,
                    pendingPermission: pendingPermission,
                    isPermissionResolved: userMsg.group.permissionRequestId
                        .map { resolvedPermissionIds.contains($0) } ?? false,
                    turnCopyText: segmentCopyTexts[userMsg.id],
                    onApprovePermission: onApprovePermission,
                    onDenyPermission: onDenyPermission,
                    onSubmitQuestionAnswers: onSubmitQuestionAnswers,
                    onRewind: onRewind
                )
                .id(userMsg.id)
                .transition(.opacity)
            }

            if !turn.intermediateMessages.isEmpty {
                let showLine = turn.assistantMessage != nil || isAgentWorking
                let isRunning = isAgentWorking && isLastTurn

                FlowStep(showLine: showLine) {
                    let icon = isRunning ? "cpu" : (isExpandedEffective ? "cpu" : "checkmark.circle")
                    let color: AnyShapeStyle = (isRunning || isExpandedEffective) ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.green)
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .medium))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(color)
                        .frame(width: 22, height: 16, alignment: .top)
                } content: {
                    VStack(alignment: .leading, spacing: 0) {
                        let isCollapsedIdle = !isRunning && !isExpandedEffective
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if !hasManuallyToggled {
                                    turnExpanded = !isExpandedEffective
                                    hasManuallyToggled = true
                                } else {
                                    turnExpanded.toggle()
                                }
                            }
                            Task {
                                try? await Task.sleep(nanoseconds: 100_000_000)
                                let frame = foldFrame_claudecode_20260713
                                let fullyVisible = frame != .zero && frame.minY >= 0 && frame.maxY <= availableHeight
                                guard !fullyVisible else { return }
                                onToggleExpanded?()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                if isCollapsedIdle {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.green)
                                }
                                Text(turnSummaryText)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .font(.callout.weight(.medium))
                                    .foregroundStyle(isRunning ? settings.themeAccentColor : Color.secondary)
                                Spacer()
                                Image(systemName: isExpandedEffective ? "chevron.down" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                isCollapsedIdle ? Markdown.inlineCodeBackground : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Group {
                            if !isExpandedEffective && isRunning {
                                let previewContent = turn.intermediateMessages.last
                                    .flatMap { getActiveStepPreview($0.group) } ?? ""
                                VStack(alignment: .leading, spacing: 0) {
                                    Divider()
                                        .foregroundStyle(Color.secondary.opacity(0.12))
                                    Text(previewContent.isEmpty ? " " : previewContent)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineSpacing(2)
                                        .lineLimit(5)
                                        .multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, minHeight: 90, maxHeight: 90, alignment: .topLeading)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.primary.opacity(0.015))
                                }
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }
                        }
                        .animation(.easeInOut(duration: 0.22), value: isRunning)

                        if isExpandedEffective {
                            Divider()
                                .foregroundStyle(Color.secondary.opacity(0.15))
                            
                            VStack(alignment: .leading, spacing: 12) {
                                let totalSteps = turn.intermediateMessages.count
                                let effStartIndex = windowStartIndex == -1 ? max(0, totalSteps - 10) : min(totalSteps, windowStartIndex)
                                let effEndIndex = windowEndIndex == -1 ? totalSteps : min(totalSteps, windowEndIndex)
                                
                                let displayedSteps = Array(turn.intermediateMessages[effStartIndex..<effEndIndex])
                                
                                // Top "Show older steps" button
                                if effStartIndex > 0 {
                                    Button {
                                        let newEnd = effStartIndex
                                        let newStart = max(0, newEnd - 15)
                                        windowStartIndex = newStart
                                        windowEndIndex = newEnd
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.up")
                                                .font(.caption2)
                                            Text("Show older steps (\(effStartIndex) steps hidden)")
                                                .font(.caption2.weight(.medium))
                                        }
                                        .foregroundStyle(settings.themeAccentColor)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 6)
                                        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 12)
                                }
                                
                                ForEach(displayedSteps) { gm in
                                    MessageBubble(
                                        group: gm.group,
                                        showConnector: false,
                                        isStreaming: false,
                                        isGroupStreaming: isAgentWorking && isLastTurn && gm.id == turn.intermediateMessages.last?.id,
                                        workspaceCwd: workspaceCwd,
                                        agentProvider: agentProvider,
                                        agentModel: agentModel,
                                        agentCapabilities: agentCapabilities,
                                        pendingPermission: pendingPermission,
                                        isPermissionResolved: gm.group.permissionRequestId
                                            .map { resolvedPermissionIds.contains($0) } ?? false,
                                        turnCopyText: segmentCopyTexts[gm.id],
                                        hideTimelineConnector: true,
                                        onApprovePermission: onApprovePermission,
                                        onDenyPermission: onDenyPermission,
                                        onSubmitQuestionAnswers: onSubmitQuestionAnswers,
                                        onRewind: onRewind
                                    )
                                    .id("\(gm.id)-\(expansionSessionId)")
                                    .transition(.opacity)
                                }
                                
                                // Bottom "Show newer steps" button
                                if effEndIndex < totalSteps {
                                    Button {
                                        let newStart = effEndIndex
                                        let newEnd = min(totalSteps, newStart + 15)
                                        windowStartIndex = newStart
                                        windowEndIndex = newEnd
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.down")
                                                .font(.caption2)
                                            Text("Show newer steps (\(totalSteps - effEndIndex) steps hidden)")
                                                .font(.caption2.weight(.medium))
                                        }
                                        .foregroundStyle(settings.themeAccentColor)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 6)
                                        .background(Color.secondary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.horizontal, 12)
                                }
                                
                                Divider()
                                    .foregroundStyle(Color.secondary.opacity(0.12))
                                
                                Button {
                                    Task {
                                        try? await Task.sleep(nanoseconds: 120_000_000)
                                        await MainActor.run {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                if !hasManuallyToggled {
                                                    turnExpanded = false
                                                    hasManuallyToggled = true
                                                } else {
                                                    turnExpanded = false
                                                }
                                            }
                                        }

                                        try? await Task.sleep(nanoseconds: 100_000_000)
                                        let frame = foldFrame_claudecode_20260713
                                        let fullyVisible = frame != .zero && frame.minY >= 0 && frame.maxY <= availableHeight
                                        guard !fullyVisible else { return }
                                        onToggleExpanded?()
                                    }
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "chevron.up")
                                        Text("Collapse")
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(12)
                        }
                    }
                    #if os(iOS)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    #else
                    .background(Color.secondary.opacity(0.04))
                    .cornerRadius(8)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
                    )
                    #endif
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("ScrollViewSpace")) }) { newValue in
                        foldFrame_claudecode_20260713 = newValue
                    }
                }
                .id("\(turn.id)-intermediates")
                .transition(.opacity)
            }

            if let assistantMsg = turn.assistantMessage {
                MessageBubble(
                    group: assistantMsg.group,
                    showConnector: assistantMsg.showConnector,
                    isStreaming: isAgentWorking && isLastTurn,
                    isGroupStreaming: isAgentWorking && isLastTurn,
                    workspaceCwd: workspaceCwd,
                    agentProvider: agentProvider,
                    agentModel: agentModel,
                    agentCapabilities: agentCapabilities,
                    pendingPermission: pendingPermission,
                    isPermissionResolved: assistantMsg.group.permissionRequestId
                        .map { resolvedPermissionIds.contains($0) } ?? false,
                    turnCopyText: segmentCopyTexts[assistantMsg.id],
                    onApprovePermission: onApprovePermission,
                    onDenyPermission: onDenyPermission,
                    onSubmitQuestionAnswers: onSubmitQuestionAnswers,
                    onRewind: onRewind
                )
                .id(assistantMsg.id)
                .transition(.opacity)
            }
        }
        .onChange(of: isExpandedEffective) { oldValue, newValue in
            if newValue {
                expansionSessionId = UUID()
            } else {
                windowStartIndex = -1
                windowEndIndex = -1
            }
        }
    }

    private func cleanToolNameForSummary(_ name: String) -> String {
        let firstLine = name.split(separator: "\n").first.map(String.init) ?? name
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 20 {
            return String(trimmed.prefix(17)) + "..."
        }
        return trimmed
    }

    private func cleanTextForSummary(_ text: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for line in lines {
            if line.isEmpty { continue }
            if isDividerLine(line) { continue }
            return line
        }
        return ""
    }

    private func isDividerLine(_ line: String) -> Bool {
        guard !line.isEmpty else { return true }
        let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "-*_~ "))
        return trimmed.isEmpty
    }

    private func getActiveStepPreview(_ group: BubbleGroup) -> String? {
        if group.kind == "tool_cluster", let lastTool = group.toolCluster.last {
            return formatToolPreview(lastTool)
        } else if group.kind == "tool", let tool = group.tool {
            return formatToolPreview(tool)
        } else if group.kind == "reasoning" {
            return formatTextPreview(group.text)
        } else if group.kind == "assistant" {
            return formatTextPreview(group.text)
        } else if group.kind == "compaction" {
            return group.text
        }
        return nil
    }

    private func formatToolPreview(_ tool: ConversationViewModel.ToolInfo) -> String? {
        var lines: [String] = []
        if let target = tool.target, !target.isEmpty {
            lines.append("> " + target.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let detail = tool.detailPlain.trimmingCharacters(in: .whitespacesAndNewlines)
        if !detail.isEmpty {
            let detailLines = detail.split(separator: "\n", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            lines.append(contentsOf: detailLines.suffix(5))
        }
        return lines.isEmpty ? nil : lines.suffix(5).joined(separator: "\n")
    }

    private func formatTextPreview(_ text: String) -> String? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }
        // 过滤掉空行/段落间的空白行——Markdown 正文常有段落空行，之前连着
        // split 都保留下来，5 行预算里混进好几行空白，视觉上就是"行间距
        // 特别大"。只留有内容的行，同样的高度能看到更多真实内容。
        // 2026.07.16 Naron
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(5).joined(separator: "\n")
    }

    private var turnSummaryText: String {
        // 1. If agent is currently active on the last turn, show the details of the active tool or reply state
        if isAgentWorking && isLastTurn {
            if let lastMsg = turn.intermediateMessages.last {
                if lastMsg.group.kind == "tool_cluster",
                   let lastTool = lastMsg.group.toolCluster.last {
                    if lastTool.status == "running" {
                        let name = cleanToolNameForSummary(lastTool.name)
                        let targetText = lastTool.target.map { s in
                            let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            return " (\(clean.count > 24 ? String(clean.prefix(24)) + "..." : clean))"
                        } ?? ""
                        return "Running: \(name)\(targetText)..."
                    }
                } else if lastMsg.group.kind == "tool", let lastTool = lastMsg.group.tool {
                    if lastTool.status == "running" {
                        let name = cleanToolNameForSummary(lastTool.name)
                        let targetText = lastTool.target.map { s in
                            let clean = s.trimmingCharacters(in: .whitespacesAndNewlines)
                            return " (\(clean.count > 24 ? String(clean.prefix(24)) + "..." : clean))"
                        } ?? ""
                        return "Running: \(name)\(targetText)..."
                    }
                } else if lastMsg.group.kind == "reasoning" {
                    return "Thinking..."
                } else if lastMsg.group.kind == "assistant" {
                    return "Replying..."
                } else if lastMsg.group.kind == "compaction" {
                    return "Compacting..."
                } else if lastMsg.group.kind == "permission" || lastMsg.group.kind == "attention" {
                    return "Waiting for authorization..."
                }
            }
            return "Thinking..."
        }

        // 2. Normal / Idle summary: prefer duration if available
        if let d = turn.assistantMessage?.group.durationSec {
            return "Worked for \(formatDurationLabel(d))"
        }
        if let lastMsg = turn.intermediateMessages.last, let d = lastMsg.group.durationSec {
            return "Worked for \(formatDurationLabel(d))"
        }

        var allTools: [ConversationViewModel.ToolInfo] = []
        for im in turn.intermediateMessages {
            if im.group.kind == "tool_cluster" {
                allTools.append(contentsOf: im.group.toolCluster)
            } else if im.group.kind == "tool", let t = im.group.tool {
                allTools.append(t)
            }
        }

        if !allTools.isEmpty {
            return "Worked for \(allTools.count) step\(allTools.count == 1 ? "" : "s")"
        }

        return "Worked"
    }
}

enum ExpandState_claudecode_20260716 {
    case collapsed
    case showTail
    case showFull
}

private struct MessageBubble: View {
    let group: BubbleGroup
    let showConnector: Bool
    @Environment(AppViewModel.self) private var app
    @Environment(SettingsStore.self) private var settings
    var isStreaming: Bool = false
    var isGroupStreaming: Bool = false
    var turnStartedAt: Date? = nil
    var workspaceCwd: String? = nil
    var agentProvider: String? = nil
    var agentModel: String? = nil
    var agentCapabilities: AgentCapabilityFlags? = nil
    var pendingPermission: PermissionRequestPayload? = nil
    var isPermissionResolved: Bool = false
    /// Combined text of all assistant bubbles in the same response segment.
    /// Non-nil only on the LAST assistant bubble of a segment — that's the
    /// only one that shows the Copy button.
    var turnCopyText: String? = nil
    var hideTimelineConnector: Bool = false
    var onApprovePermission: (() -> Void)? = nil
    var onDenyPermission: (() -> Void)? = nil
    var onSubmitQuestionAnswers: (([String: String]) -> Void)? = nil
    var onRewind: ((String, AgentRewindMode, String) -> Void)? = nil
    @State private var reasoningExpanded: Bool = false
    @State private var expandState: ExpandState_claudecode_20260716 = .collapsed
    @State private var didCopy: Bool = false
    @State private var attachmentExpandStates: [UUID: ExpandState_claudecode_20260716] = [:]
    @State private var chatHistoryExpanded: Bool = false

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
        let parsed = parseUserMessage(group.text)
        return HStack(alignment: .top) {
            // iOS 去掉右侧常驻的会话节点竖条后腾出了空间，气泡可以更贴右边缘；
            // macOS 保留原来的 48pt（右侧仍有节点竖条要让位）。2026.07.13 Naron
            #if os(iOS)
            Spacer(minLength: 28)
            #else
            Spacer(minLength: 48)
            #endif
            VStack(alignment: .trailing, spacing: 4) {
                if !group.images.isEmpty {
                    UserBubbleImages(images: group.images)
                }
                if !group.text.isEmpty {
                    VStack(alignment: .trailing, spacing: 6) {
                        if let history = parsed.chatHistory {
                            VStack(alignment: .trailing, spacing: 6) {
                                ChatHistoryAttachmentChip(isExpanded: $chatHistoryExpanded)
                                if chatHistoryExpanded {
                                    MarkdownBodyView(text: history, workspaceCwd: workspaceCwd)
                                        .padding(8)
                                        .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                        .frame(maxWidth: 500)
                                }
                            }
                        }

                        if !parsed.mainText.isEmpty {
                            let textIsLong = parsed.mainText.count > 150 || parsed.mainText.split(separator: "\n").count > 10
                            let lines = parsed.mainText.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                            let headText = parsed.mainText.split(separator: "\n").count > 10
                                ? lines.prefix(10).joined(separator: "\n") + "\n..."
                                : String(parsed.mainText.prefix(120)) + "..."
                            
                            Group {
                                if textIsLong {
                                    switch expandState {
                                    case .collapsed:
                                        if parsed.mainText.split(separator: "\n").count > 10 {
                                            MarkdownBodyView(text: headText, workspaceCwd: workspaceCwd)
                                                .frame(maxHeight: 160, alignment: .top)
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
                                            MarkdownBodyView(text: headText, workspaceCwd: workspaceCwd)
                                        }
                                    case .showTail:
                                        VStack(alignment: .leading, spacing: 8) {
                                            Button {
                                                withAnimation(.easeInOut(duration: 0.18)) {
                                                    expandState = .showFull
                                                }
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: "chevron.down.circle")
                                                    Text("Show full content (\(lines.count - 20) lines hidden)")
                                                }
                                                .font(.caption2)
                                                .foregroundStyle(settings.themeAccentColor)
                                            }
                                            .buttonStyle(.plain)
                                            .padding(.vertical, 4)
                                            
                                            let tailText = "...\n" + lines.suffix(20).joined(separator: "\n")
                                            MarkdownBodyView(text: tailText, workspaceCwd: workspaceCwd)
                                        }
                                    case .showFull:
                                        MarkdownBodyView(text: parsed.mainText, workspaceCwd: workspaceCwd)
                                    }
                                } else {
                                    MarkdownBodyView(text: parsed.mainText, workspaceCwd: workspaceCwd)
                                }
                            }
                            
                            if textIsLong {
                                HStack(spacing: 12) {
                                    if expandState == .collapsed {
                                        Button("Show more ↓") {
                                            withAnimation(.easeInOut(duration: 0.18)) {
                                                expandState = lines.count > 10 ? .showTail : .showFull
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(settings.themeAccentColor)
                                        .buttonStyle(.plain)
                                    } else {
                                        Button("Show less ↑") {
                                            withAnimation(.easeInOut(duration: 0.18)) {
                                                expandState = .collapsed
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(settings.themeAccentColor)
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }

                        if !parsed.attachments.isEmpty {
                            VStack(alignment: .trailing, spacing: 8) {
                                ForEach(parsed.attachments) { att in
                                    let attExpandState = attachmentExpandStates[att.id] ?? .collapsed
                                    VStack(alignment: .trailing, spacing: 6) {
                                        TextFileAttachmentChip(
                                            name: att.name,
                                            charCount: att.content.count,
                                            isExpanded: Binding(
                                                get: { attExpandState != .collapsed },
                                                set: { val in
                                                    if val {
                                                        attachmentExpandStates[att.id] = .showTail
                                                    } else {
                                                        attachmentExpandStates[att.id] = .collapsed
                                                    }
                                                }
                                            )
                                        )
                                        if attExpandState != .collapsed {
                                            let attLines = att.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                                            let isAttLong = attLines.count > 25 || att.content.count > 1000
                                            
                                            VStack(alignment: .leading, spacing: 8) {
                                                if isAttLong {
                                                    if attExpandState == .showTail {
                                                        Button {
                                                            withAnimation(.easeInOut(duration: 0.18)) {
                                                                attachmentExpandStates[att.id] = .showFull
                                                            }
                                                        } label: {
                                                            HStack(spacing: 4) {
                                                                Image(systemName: "chevron.down.circle")
                                                                Text("Show full content (\(attLines.count - 20) lines hidden)")
                                                            }
                                                            .font(.caption2)
                                                            .foregroundStyle(settings.themeAccentColor)
                                                        }
                                                        .buttonStyle(.plain)
                                                        .padding(.vertical, 4)
                                                        
                                                        let tailContent = "...\n" + attLines.suffix(20).joined(separator: "\n")
                                                        MarkdownBodyView(
                                                            text: "```\(att.language ?? "")\n\(tailContent)\n```",
                                                            workspaceCwd: workspaceCwd
                                                        )
                                                    } else {
                                                        MarkdownBodyView(
                                                            text: "```\(att.language ?? "")\n\(att.content)\n```",
                                                            workspaceCwd: workspaceCwd
                                                        )
                                                    }
                                                } else {
                                                    MarkdownBodyView(
                                                        text: "```\(att.language ?? "")\n\(att.content)\n```",
                                                        workspaceCwd: workspaceCwd
                                                    )
                                                }
                                            }
                                            .padding(8)
                                            .background(Color.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                                            .frame(maxWidth: 500)
                                        }
                                    }
                                }
                            }
                            .padding(.top, (parsed.mainText.isEmpty && parsed.chatHistory == nil) ? 0 : 4)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    #if os(iOS)
                    // 跟折叠区域同一套淡红渲染底色，视觉上统一成"这是当前主题的
                    // 强调色系"，不再用系统灰。2026.07.13 Naron
                    .background(Markdown.inlineCodeBackground, in: RoundedRectangle(cornerRadius: 18))
                    #else
                    .background(settings.userBubbleBackgroundColor, in: RoundedRectangle(cornerRadius: 12))
                    #endif
                    .contextMenu {
                        Button("Copy text") {
                            PaseoPasteboard.copyText(group.text)
                        }
                        if let messageId = group.messageId,
                           let onRewind,
                           !rewindModes.isEmpty {
                            Divider()
                            Menu("Rewind") {
                                ForEach(rewindModes, id: \.self) { mode in
                                    Button(rewindLabel(mode)) {
                                        onRewind(messageId, mode, group.text)
                                    }
                                }
                            }
                        }
                    }
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
                   turnCopyText != nil && !isStreaming {
                    TurnMetaChip(
                        model: chipLabel,
                        durationSec: group.durationSec,
                        timestamp: group.timestamp
                    )
                }
                if !isStreaming, let copyText = turnCopyText {
                    Button {
                        PaseoPasteboard.copyText(copyText)
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
                    .padding(.top, 2)
                    .animation(.easeInOut(duration: 0.15), value: didCopy)
                }
            }
            .contextMenu {
                Button("Copy text") {
                    PaseoPasteboard.copyText(group.text)
                }
            }
        }
    }

    // MARK: Reasoning — clock icon, collapsible thinking block

    private var reasoningTimelineItem: some View {
        let content = VStack(alignment: .leading, spacing: 6) {
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
        .onAppear {
            if isGroupStreaming {
                reasoningExpanded = true
            }
        }
        .onChange(of: isGroupStreaming) { oldValue, newValue in
            if newValue {
                withAnimation(.easeInOut(duration: 0.2)) {
                    reasoningExpanded = true
                }
            } else if oldValue && !newValue {
                withAnimation(.easeInOut(duration: 0.2)) {
                    reasoningExpanded = false
                }
            }
        }

        return Group {
            if hideTimelineConnector {
                content
            } else {
                FlowStep(iconName: "clock", showLine: showConnector) {
                    content
                }
            }
        }
    }

    // MARK: Tool cluster — terminal icon, minimal label rows

    private var toolTimelineItem: some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(group.toolCluster.enumerated()), id: \.offset) { _, info in
                ToolRowTimeline(info: info, workspaceCwd: workspaceCwd)
            }
        }

        return Group {
            if hideTimelineConnector {
                content
            } else {
                FlowStep(iconName: "bolt", showLine: showConnector) {
                    content
                }
            }
        }
    }

    // MARK: Fallback (todo / error / system)

    private var sideTimelineItem: some View {
        let content = Text(group.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(sideTextColor)
            .font(group.kind == "compaction" ? .callout.italic() : .body)

        return Group {
            if hideTimelineConnector {
                content
            } else {
                FlowStep(iconName: sideIcon, showLine: showConnector) {
                    content
                }
            }
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
            EmptyView()
        } else if let aq = pendingPermission?.askUserQuestion {
            let content = AskUserQuestionView(
                questions: aq.questions,
                onSubmit: { onSubmitQuestionAnswers?($0) },
                onCancel: { onDenyPermission?() }
            )
            if hideTimelineConnector {
                content
            } else {
                FlowStep(iconName: "questionmark.bubble.fill", showLine: showConnector) {
                    content
                }
            }
        } else {
            // 原来只有一行泛泛的 "Permission Required" + 两个小按钮，看不出
            // 到底在请求什么权限。改成贴近 Claude Code CLI 的样式：工具图标 +
            // 名称 + 具体请求内容的卡片，橙色系跟列表页 "Needs approval" 徽章
            // 保持同一套语义色，按钮也放大到常规触控尺寸。2026.07.13 Naron
            let toolName = pendingPermission?.name
            let hasToolName = toolName?.isEmpty == false && toolName != "AskUserQuestion"
            let content = VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: permissionCardIcon_claudecode_20260713(toolName))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 18, alignment: .center)
                    Text(pendingPermission?.title?.isEmpty == false ? pendingPermission!.title! : "Permission Required")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    if hasToolName {
                        Text(toolName!)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }
                if let desc = pendingPermission?.description, !desc.isEmpty {
                    Text(desc)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(6)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                HStack(spacing: 8) {
                    Button("Allow") { onApprovePermission?() }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                    Button("Deny") { onDenyPermission?() }
                        .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.orange.opacity(0.25), lineWidth: 1))
            if hideTimelineConnector {
                content
            } else {
                FlowStep(iconName: "exclamationmark.shield.fill", showLine: showConnector) {
                    content
                }
            }
        }
    }

    /// 权限卡片的工具图标，跟 ToolRowTimeline/ToolInfo 用的是同一套图标
    /// 词汇（terminal/pencil/doc.text 等），只是权限请求阶段还没有解析出
    /// 结构化的 ToolDetail，只能按工具名字符串粗匹配。2026.07.13 Naron
    private func permissionCardIcon_claudecode_20260713(_ toolName: String?) -> String {
        switch (toolName ?? "").lowercased() {
        case "bash", "shell", "terminal": return "terminal"
        case "edit": return "pencil"
        case "write": return "square.and.pencil"
        case "read": return "doc.text"
        case "search", "grep", "glob": return "magnifyingglass"
        case "fetch", "webfetch": return "arrow.down.circle"
        default: return "exclamationmark.shield.fill"
        }
    }

    // MARK: Attention required — informational banner

    @ViewBuilder
    private var attentionTimelineItem: some View {
        if isPermissionResolved {
            EmptyView()
        } else {
            let content = VStack(alignment: .leading, spacing: 4) {
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
            if hideTimelineConnector {
                content
            } else {
                FlowStep(iconName: "exclamationmark.circle.fill", showLine: showConnector) {
                    content
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

    private func getModelLabelFromDefinitions(_ modelId: String) -> String? {
        let normalizedId = modelId.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for provider in app.providers {
            if let models = provider.models {
                if let match = models.first(where: { $0.id.lowercased() == normalizedId }) {
                    return match.label
                }
            }
        }
        return nil
    }

    private func formatModelName(_ raw: String) -> String {
        // 1. First, check if there is an exact match in the app's provider model definitions
        if let matchLabel = getModelLabelFromDefinitions(raw) {
            return matchLabel
        }
        
        let normalized = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return raw }
        
        // 2. Claude models mapping to user-facing terms
        if normalized == "claude" {
            if let defaultLabel = getModelLabelFromDefinitions("sonnet-5") {
                return defaultLabel
            }
            return "Sonnet 5"
        }
        if normalized.contains("3-5-sonnet") || normalized.contains("3.5-sonnet") {
            if let defaultLabel = getModelLabelFromDefinitions("sonnet-5") {
                return defaultLabel
            }
            return "Sonnet 5"
        }
        if normalized.contains("3-5-haiku") || normalized.contains("3.5-haiku") {
            return "Haiku 5"
        }
        if normalized.contains("3-opus") {
            return "Opus 3"
        }
        if normalized.contains("3-sonnet") {
            return "Sonnet 3"
        }
        if normalized.contains("3-haiku") {
            return "Haiku 3"
        }
        
        // 3. Gemini models
        if normalized.contains("gemini-2.5-pro") {
             return "Gemini 2.5 Pro"
        }
        if normalized.contains("gemini-2.0-flash") {
            return "Gemini 2.0 Flash"
        }
        if normalized.contains("gemini-2.0-pro") {
            return "Gemini 2.0 Pro"
        }
        if normalized.contains("gemini-1.5-pro") {
            return "Gemini 1.5 Pro"
        }
        if normalized.contains("gemini-1.5-flash") {
            return "Gemini 1.5 Flash"
        }
        if normalized.starts(with: "gemini") {
            return "Gemini"
        }
        
        // 4. GPT / OpenAI models
        if normalized.contains("gpt-4o-mini") {
            return "GPT-4o Mini"
        }
        if normalized.contains("gpt-4o") {
            return "GPT-4o"
        }
        if normalized.contains("gpt-4-turbo") {
            return "GPT-4 Turbo"
        }
        
        let parts = raw.split(separator: "-").map { $0.capitalized }
        return parts.joined(separator: " ")
    }

    private func displayProviderModel(provider: String?, model: String?) -> String? {
        var resolvedModel = model
        if isStreaming {
            if let m = resolvedModel, m.lowercased() == "claude", let detailed = agentModel {
                resolvedModel = detailed
            } else if resolvedModel == nil || resolvedModel!.isEmpty {
                resolvedModel = agentModel
            }
        }

        if resolvedModel == nil || resolvedModel!.isEmpty {
            resolvedModel = agentModel
        }

        if let m = resolvedModel, !m.isEmpty {
            return formatModelName(m)
        }

        if let p = provider {
            if p.lowercased() == "claude" {
                if let defaultLabel = getModelLabelFromDefinitions("sonnet-5") {
                    return defaultLabel
                }
                return "Sonnet 5"
            }
            return formatModelName(p)
        }
        
        return nil
    }

    private func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

// MARK: - Timeline connector wrapper

/// Wraps assistant-side content in the Claude.ai-style timeline layout:
/// a small icon on the left, optional thin connector line running downward
/// to the next item, and content to the right.
private struct FlowStep<Content: View, Icon: View>: View {
    let showLine: Bool
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let content: () -> Content

    init(showLine: Bool, @ViewBuilder icon: @escaping () -> Icon, @ViewBuilder content: @escaping () -> Content) {
        self.showLine = showLine
        self.icon = icon
        self.content = content
    }

    var body: some View {
        #if os(iOS)
        content()
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, 4)
            .padding(.bottom, showLine ? 14 : 8)
        #else
        HStack(alignment: .top, spacing: 10) {
            icon()
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
        #endif
    }
}

extension FlowStep where Icon == AnyView {
    init(iconName: String, showLine: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.showLine = showLine
        self.icon = {
            AnyView(
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            )
        }
        self.content = content
    }
}

// MARK: - Tool row (timeline style)

/// One tool invocation in the timeline. Collapsed: name + target + badge.
/// Tap to expand the detail payload (script output, diff, etc.).
private struct ToolRowTimeline: View {
    let info: ConversationViewModel.ToolInfo
    var workspaceCwd: String? = nil
    @Environment(AppViewModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @Environment(SettingsStore.self) private var settings
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
                            #if os(macOS)
                            openWindow(value: route)
                            #elseif os(iOS)
                            app.activeWorkspaceRoute = route
                            #endif
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
            if mono {
                TerminalConsoleView(text: text, title: info.name)
            } else {
                Text(text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
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
        case "running": settings.themeAccentColor
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
    @MainActor
    static func open(_ loc: FileLocation) {
        let url = URL(fileURLWithPath: loc.path)
        guard let line = loc.lineStart else {
            openConversationURL_claudecode_20260709(url)
            return
        }
        #if os(macOS)
        // Try a few known editor CLIs in order of how common they are on
        // dev machines. Each one accepts `<path>:<line>:<col>` (subl style)
        // or `-g <path>:<line>:<col>` (vscode/cursor style).
        let target = loc.lineEnd != nil ? "\(loc.path):\(line):1" : "\(loc.path):\(line)"
        for cli in ["cursor", "code", "subl"] {
            if runCLI(cli, args: cli == "subl" ? [target] : ["-g", target]) { return }
        }
        // Final fallback: plain open. The line hint is lost but the file
        // still opens in whatever the user's "Open With" default is.
        openConversationURL_claudecode_20260709(url)
        #elseif os(iOS)
        openConversationURL_claudecode_20260709(url)
        #endif
    }

    private static func runCLI(_ command: String, args: [String]) -> Bool {
        #if os(macOS)
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
        #elseif os(iOS)
        return false
        #endif
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
                if let platformImage = PlatformImage(contentsOf: img.fileURL) {
                    Image(platformImage: platformImage)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFill()          // fills frame, crops surplus
                        .frame(width: cellSize, height: cellSize)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                        .onTapGesture { zoomed = img }
                } else {
                    // fileURL 指向本机的图片缓存（~/Library/Caches/PaseoMac/images/），
                    // 只有"在这台设备上composer 里附加过"的图片才会有这份本地文件。
                    // 如果这条用户消息是从别的设备（比如 Mac 端）发过来的，daemon
                    // 回显的只是图片的宽高/mimeType 元数据，原始字节从来没同步到
                    // 这台设备——之前这里直接什么都不渲染，空出一块看不出原因的
                    // 空白。改成一个占位符：明确告诉用户"这里有张图，但当前设备
                    // 看不到"，不用等一个永远不会成功的本地加载。2026.07.13 Naron
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.secondary.opacity(0.12))
                        .frame(width: cellSize, height: cellSize)
                        .overlay {
                            Image(systemName: "photo")
                                .font(.system(size: cellSize * 0.32))
                                .foregroundStyle(.secondary)
                        }
                }
            }
        }
        .sheet(item: $zoomed) { img in
            if let platformImage = PlatformImage(contentsOf: img.fileURL) {
                ZStack(alignment: .topTrailing) {
                    Image(platformImage: platformImage)
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
    if Calendar.current.isDateInToday(date) {
        return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
    return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
}

// MARK: - Per-bubble model + duration chip

private func formatDurationLabel(_ t: TimeInterval) -> String {
    if t < 60 { return String(format: "%ds", Int(t.rounded())) }
    return String(format: "%dm %ds", Int(t) / 60, Int(t) % 60)
}

private struct TurnMetaChip: View {
    let model: String
    let durationSec: TimeInterval?
    let timestamp: String?

    var body: some View {
        HStack(spacing: 4) {
            Text(prettyModel(model))
            if let ts = timestamp, let label = formatTimestamp(ts) {
                Text("·")
                    .foregroundStyle(.quaternary)
                Text(label)
            }
            if let d = durationSec {
                Text("·")
                    .foregroundStyle(.quaternary)
                Text(formatDurationLabel(d))
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
            Capsule().fill(PlatformColor.controlBackground)
        )
        .overlay(
            Capsule().stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        #if os(iOS)
        .padding(.leading, 0)
        #else
        .padding(.leading, 58)
        #endif
        .padding(.trailing, 16)
        .padding(.top, -14)
        .padding(.bottom, 6)
        .task(id: startedAt) {
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
        let t: TimeInterval
        if isWorking {
            if let start = startedAt {
                t = max(0, Date().timeIntervalSince(start))
            } else {
                t = elapsed
            }
        } else {
            t = duration ?? elapsed
        }
        if t < 60 { return String(format: "%ds", Int(t.rounded())) }
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

// MARK: - User message jump affordance (platform split)

/// macOS 保留右侧节点竖条（hover 预览很好用）；iOS 屏幕窄，同一条常驻在
/// 右边缘会盖住正文最后几个字——改成头部按钮打开的小 sheet，按需查看。
/// 2026.07.13 Naron
private struct UserMessageJumpAffordance_claudecode_20260713: ViewModifier {
    let grouped: [GroupedMessage]
    let proxy: ScrollViewProxy
    let vm: ConversationViewModel
    /// 当前最靠上那一轮的 id——从跳转小窗口触发"加载更早"时用同一套锚点
    /// 逻辑，跟主列表里的按钮保持一致，不会因为触发入口不同而表现不一样。
    /// 2026.07.13 Naron
    let firstTurnId: String?
    var jumpListPresented: Binding<Bool>?
    @Binding var suppressAutoScroll: Bool
    @Binding var isNearBottom: Bool
    @Binding var isAtBottom: Bool

    private var items: [UserMessageTimeline.Item] {
        grouped.filter { $0.group.kind == "user" && ($0.group.text.trimmingCharacters(in: .whitespacesAndNewlines).count > 2 || !$0.group.images.isEmpty) }
            .map { UserMessageTimeline.Item(id: $0.id, text: $0.group.text, hasImages: !$0.group.images.isEmpty, timestamp: $0.group.timestamp) }
    }

    func body(content: Content) -> some View {
        #if os(macOS)
        content.overlay(alignment: .trailing) {
            if !items.isEmpty {
                UserMessageTimeline(
                    items: items, proxy: proxy,
                    hasOlderMessages: vm.hasOlderMessages,
                    isLoadingMore: vm.isLoading,
                    onLoadMore: {
                        let anchorId = firstTurnId
                        suppressAutoScroll = true
                        isNearBottom = false
                        isAtBottom = false
                        Task {
                            await vm.loadOlderMessages()
                            if let anchorId {
                                withTransaction(Transaction(animation: nil)) {
                                    proxy.scrollTo(anchorId, anchor: .top)
                                }
                            }
                            suppressAutoScroll = false
                        }
                    },
                    onNavigate: {
                        suppressAutoScroll = true
                        isNearBottom = false
                        isAtBottom = false
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
        #else
        content.sheet(isPresented: Binding(
            get: { jumpListPresented?.wrappedValue ?? false },
            set: { jumpListPresented?.wrappedValue = $0 }
        )) {
            IOSMessageJumpList_claudecode_20260713(
                items: items,
                hasOlderMessages: vm.hasOlderMessages,
                isLoadingMore: vm.isLoading,
                onLoadMore: {
                    let anchorId = firstTurnId
                    suppressAutoScroll = true
                    isNearBottom = false
                    isAtBottom = false
                    Task {
                        await vm.loadOlderMessages()
                        if let anchorId {
                            withTransaction(Transaction(animation: nil)) {
                                proxy.scrollTo(anchorId, anchor: .top)
                            }
                        }
                        suppressAutoScroll = false
                    }
                },
                onSelect: { id in
                    suppressAutoScroll = true
                    isNearBottom = false
                    isAtBottom = false
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .top)
                    }
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        suppressAutoScroll = false
                    }
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        #endif
    }
}

#if os(iOS)
private struct IOSMessageJumpList_claudecode_20260713: View {
    let items: [UserMessageTimeline.Item]
    var hasOlderMessages: Bool = false
    var isLoadingMore: Bool = false
    var onLoadMore: (() -> Void)? = nil
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    // 最新消息放最上面：跳转多半是想找"最近说了什么"，不用先滚到列表
    // 底部。"加载更早"点了以后新追加的更老消息接在列表最后面（往下延伸），
    // 顺序上下都成立。2026.07.13 Naron
    private var reversedItems_claudecode_20260713: [UserMessageTimeline.Item] {
        items.reversed()
    }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty && !hasOlderMessages {
                    ContentUnavailableView("No messages yet", systemImage: "bubble.left")
                } else {
                    List {
                        ForEach(reversedItems_claudecode_20260713) { item in
                            Button {
                                onSelect(item.id)
                                dismiss()
                            } label: {
                                HStack(spacing: 8) {
                                    if item.hasImages {
                                        Image(systemName: "photo")
                                            .foregroundStyle(.secondary)
                                    }
                                    Text(item.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Spacer(minLength: 8)
                                    if let ts = item.timestamp, let formatted = formatTimestamp(ts) {
                                        Text(formatted)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                            .fixedSize()
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        // "加载更早消息"只保留左上角工具栏那一个固定入口
                        // （见下面 .toolbar），列表里不再重复放一份。
                        // 2026.07.13 Naron
                    }
                }
            }
            .navigationTitle("Jump to Message")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // "固定在左上角"——挪到导航栏工具栏而不是列表第一行，
                // 这样不管列表滚到哪都够得到，而不是跟着内容一起滚走。
                // 2026.07.13 Naron
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        onLoadMore?()
                    } label: {
                        if isLoadingMore {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.up.circle")
                        }
                    }
                    .disabled(isLoadingMore || !hasOlderMessages)
                    .opacity(hasOlderMessages ? 1 : 0.35)
                    .accessibilityLabel("Load earlier messages")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
#endif

// MARK: - User message timeline (right rail)

private struct UserMessageTimeline: View {
    struct Item: Identifiable { let id: String; let text: String; var hasImages: Bool = false; var timestamp: String? = nil }
    @Environment(SettingsStore.self) private var settings
    let items: [Item]
    let proxy: ScrollViewProxy
    var hasOlderMessages: Bool = false
    var isLoadingMore: Bool = false
    var onLoadMore: (() -> Void)? = nil
    var onNavigate: (() -> Void)? = nil
    @State private var hoveredId: String? = nil

    private let nodeH: CGFloat = 28
    // 2026.07.14 Naron: 消息一多，这条竖条之前是按 items.count 无限长高，
    // 撑满甚至溢出整个窗口高度，完全不是设计要的"小胶囊"观感（用户给的
    // 参考图：固定高度、圆角胶囊、居中悬浮）。改成给内容区域封顶一个最大
    // 高度，超出的部分放进内部 ScrollView 里滚动查看，外层胶囊形状和位置
    // 保持稳定，不再随消息数量疯长。
    private let maxVisibleHeight: CGFloat = 300

    private var loadMoreHeader: some View {
        Group {
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
                                .foregroundStyle(settings.themeAccentColor)
                        }
                    }
                    .frame(width: 22, height: 20)
                }
                .buttonStyle(.plain)
                .help("Load earlier messages")
                Rectangle()
                    .fill(settings.themeAccentColor.opacity(0.18))
                    .frame(width: 1.5, height: 4)
            }
        }
    }

    private var nodesList: some View {
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
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(item.id, anchor: .top)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            loadMoreHeader
            let contentHeight = CGFloat(items.count) * nodeH
            if contentHeight > maxVisibleHeight {
                // 2026.07.14 Naron: 最新消息永远在最下面——默认锚点给
                // .bottom，胶囊内部一打开就是最新的那几个点，不是老消息
                // 那一端，跟主对话区"跟着最新走"的直觉保持一致。
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) { nodesList }
                }
                .defaultScrollAnchor(.bottom)
                .frame(height: maxVisibleHeight)
            } else {
                VStack(spacing: 0) { nodesList }
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
    @Environment(SettingsStore.self) private var settings
    private let dot: CGFloat = 6

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(settings.themeAccentColor.opacity(isFirst ? 0 : 0.18))
                .frame(width: 1.5, height: (height - dot) / 2)
            Circle()
                .fill(isHovered ? settings.themeAccentColor : settings.themeAccentColor.opacity(0.38))
                .frame(width: dot, height: dot)
            .scaleEffect(isHovered ? 1.65 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.6), value: isHovered)
            Rectangle()
                .fill(settings.themeAccentColor.opacity(isLast ? 0 : 0.18))
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let prefixText = trimmed.count > 300 ? String(trimmed.prefix(300)) : trimmed
        let cleaned = prefixText
            .replacingOccurrences(of: #"```[\s\S]*?```"#, with: "…", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`#>]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = cleaned.isEmpty ? trimmed : cleaned
        return result.count > 130 ? String(result.prefix(130)) + "…" : result
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
private func getActiveStatusText(_ rows: [ConversationViewModel.Row]) -> String {
    if let last = rows.last {
        if last.kind == "compaction" {
            return "Compacting context"
        }
    }
    return "Thinking"
}

private struct ThinkingIndicator: View {
    let statusText: String
    @State private var phase: Int = 0

    var body: some View {
        FlowStep(iconName: "clock", showLine: false) {
            HStack(spacing: 4) {
                Text(statusText)
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

struct PendingCreatingView: View {
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
    @Environment(SettingsStore.self) private var settings

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
                        .background(settings.userBubbleBackgroundColor, in: RoundedRectangle(cornerRadius: 12))
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundStyle(.orange)
                Text("Question from Agent")
                    .font(.subheadline.bold())
                    .foregroundStyle(.orange)
            }

            ForEach(questions) { q in
                questionRow(q)
            }

            Divider()
                .opacity(0.3)

            HStack(spacing: 8) {
                Spacer()
                Button("Skip") { onCancel() }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                Button("Submit") { onSubmit(draft) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(!canSubmit)
            }
        }
        .padding(16)
        .background(PlatformColor.controlBackground.opacity(0.5))
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 4)
    }

    @ViewBuilder
    private func questionRow(_ q: AskUserQuestion.Question) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if !q.header.isEmpty {
                Text(q.header)
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }
            Text(q.question)
                .font(.body)
                .textSelection(.enabled)
                .padding(.bottom, 4)

            // Options as a vertical stack of rows
            if !q.options.isEmpty {
                VStack(spacing: 8) {
                    ForEach(q.options) { opt in
                        let selected = (draft[q.header] ?? "") == opt.label

                        Button {
                            draft[q.header] = opt.label
                        } label: {
                            HStack(alignment: opt.description != nil ? .top : .center, spacing: 10) {
                                // Custom native radio button
                                Circle()
                                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.5), lineWidth: selected ? 4.5 : 1.5)
                                    .background(selected ? Color.accentColor.opacity(0.1) : Color.clear, in: Circle())
                                    .frame(width: 14, height: 14)
                                    .padding(.top, opt.description != nil ? 3 : 0)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(opt.label)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.85))

                                    if let desc = opt.description, !desc.isEmpty {
                                        Text(desc)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .background(
                                selected
                                ? Color.accentColor.opacity(0.06)
                                : Color.primary.opacity(0.01),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.06), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 4)
            }

            // Custom text input
            TextField(
                "Or type a custom answer...",
                text: Binding(
                    get: { draft[q.header] ?? "" },
                    set: { draft[q.header] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .controlSize(.regular)
            .onSubmit {
                if canSubmit { onSubmit(draft) }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct TerminalConsoleView: View {
    let text: String
    let title: String
    @State private var copied: Bool = false
    @State private var showAll: Bool = false

    private var lines: [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    private var hasTooManyLines: Bool {
        lines.count > 25
    }

    private var displayedText: String {
        if hasTooManyLines && !showAll {
            return lines.suffix(15).joined(separator: "\n")
        }
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header Bar
            HStack(spacing: 8) {
                // macOS window dots
                HStack(spacing: 5) {
                    Circle().fill(Color.red.opacity(0.8)).frame(width: 8, height: 8)
                    Circle().fill(Color.yellow.opacity(0.8)).frame(width: 8, height: 8)
                    Circle().fill(Color.green.opacity(0.8)).frame(width: 8, height: 8)
                }
                .padding(.leading, 8)

                Spacer()

                Text(title)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)

                Spacer()

                Button {
                    PaseoPasteboard.copyText(text)
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark.circle.fill" : "doc.onclipboard")
                        .font(.caption2)
                        .foregroundStyle(copied ? .green : .secondary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
            }
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06))

            Divider()

            // Console output
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    if hasTooManyLines {
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                showAll.toggle()
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showAll ? "chevron.up.circle" : "chevron.down.circle")
                                Text(showAll ? "Collapse older logs" : "Show older logs (\(lines.count - 15) lines hidden)")
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.3).opacity(0.8))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 10)
                        .padding(.top, 8)
                    }

                    Text(displayedText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Color(red: 0.3, green: 0.85, blue: 0.3)) // classic terminal green
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: 220)
            .background(Color.black)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        )
    }
}

// MARK: - Parsed Text Attachments for user messages

struct ParsedTextAttachment: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let content: String
    let language: String?
}

struct ParsedUserMessage {
    let mainText: String
    let attachments: [ParsedTextAttachment]
    let chatHistory: String?
}

func parseUserMessage(_ text: String) -> ParsedUserMessage {
    var mainText = text
    var chatHistory: String? = nil

    // 1. Extract branched chat history bootstrap if present
    let historyPattern = "\\[Continuing a prior conversation[\\s\\S]*?\\[End of prior context\\..*?\\]"
    if let regex = try? NSRegularExpression(pattern: historyPattern, options: []) {
        let nsString = mainText as NSString
        if let match = regex.firstMatch(in: mainText, options: [], range: NSRange(location: 0, length: nsString.length)) {
            chatHistory = nsString.substring(with: match.range)
            if let textRange = Range(match.range, in: mainText) {
                mainText.removeSubrange(textRange)
            }
        }
    }

    // 2. Extract standard file attachments
    let filePattern = "\\*\\*([^\\n]+?)\\*\\*\\r?\\n`{3}([a-zA-Z0-9_-]*)\\r?\\n([\\s\\S]*?)\\r?\\n`{3}"
    guard let regex = try? NSRegularExpression(pattern: filePattern, options: []) else {
        return ParsedUserMessage(
            mainText: mainText.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: [],
            chatHistory: chatHistory
        )
    }

    let nsString = mainText as NSString
    let matches = regex.matches(in: mainText, options: [], range: NSRange(location: 0, length: nsString.length))

    var attachments: [ParsedTextAttachment] = []
    var rangesToRemove: [NSRange] = []

    for match in matches {
        if match.numberOfRanges >= 4 {
            let name = nsString.substring(with: match.range(at: 1))
            let lang = nsString.substring(with: match.range(at: 2))
            let content = nsString.substring(with: match.range(at: 3))

            attachments.append(ParsedTextAttachment(
                name: name,
                content: content,
                language: lang.isEmpty ? nil : lang
            ))
            rangesToRemove.append(match.range)
        }
    }

    for range in rangesToRemove.reversed() {
        if let textRange = Range(range, in: mainText) {
            mainText.removeSubrange(textRange)
        }
    }

    mainText = mainText.trimmingCharacters(in: .whitespacesAndNewlines)
    return ParsedUserMessage(
        mainText: mainText,
        attachments: attachments,
        chatHistory: chatHistory
    )
}

struct TextFileAttachmentChip: View {
    let name: String
    let charCount: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(charCount) chars")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 180, height: 42)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

struct ChatHistoryAttachmentChip: View {
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "doc.text.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Chat history")
                        .font(.caption.weight(.medium))
                    Text("Previous conversation")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: 180, height: 42)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
