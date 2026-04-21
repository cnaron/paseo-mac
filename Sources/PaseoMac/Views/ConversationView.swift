import SwiftUI

struct ConversationView: View {
    @Environment(AppViewModel.self) private var app
    let agentId: String

    var body: some View {
        let vm = app.conversation(for: agentId)
        VStack(spacing: 0) {
            MessageList(vm: vm)
            Divider()
            ComposerView(vm: vm)
        }
        .navigationTitle(agent()?.displayName ?? "")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if vm.isAgentWorking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Working…").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
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
    /// Populated only when `kind == "tool_cluster"` — consecutive tool rows
    /// rendered together with tight internal spacing.
    let toolCluster: [ConversationViewModel.ToolInfo]
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
                toolCluster: cluster
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
                toolCluster: [info]
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
                id: last.id,           // keep the first row's id so SwiftUI keeps animation identity
                kind: last.kind,
                text: merged,
                timestamp: last.timestamp,
                tool: nil,
                toolCluster: []
            ))
        } else {
            out.append(BubbleGroup(
                id: row.id,
                kind: row.kind,
                text: row.text,
                timestamp: row.timestamp,
                tool: row.tool,
                toolCluster: []
            ))
        }
    }
    return out
}

// MARK: - Message list

private struct MessageList: View {
    @Bindable var vm: ConversationViewModel
    @Environment(SettingsStore.self) private var settings

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: CGFloat(settings.bubbleGap)) {
                    if let err = vm.lastError {
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 16)
                    }
                    ForEach(groupRows(vm.rows)) { group in
                        MessageBubble(group: group)
                            .id(group.id)
                    }
                    if vm.isLoading {
                        ProgressView().frame(maxWidth: .infinity).padding()
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.vertical, 16)
            }
            .onChange(of: vm.rows.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            // Also rescroll when the text inside the current bubble grows (streaming into
            // the same merged group). `rows.count` doesn't change in that case.
            .onChange(of: vm.rows.last?.text ?? "") { _, _ in
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}

private struct MessageBubble: View {
    let group: BubbleGroup

    var body: some View {
        switch group.kind {
        case "user":
            userBubble
        case "tool_cluster":
            toolCluster
        case "assistant":
            assistantBubble
        case "reasoning":
            reasoningView
        default:
            sideBubble
        }
    }

    // MARK: User (right-aligned bubble)
    //
    // Layout note: the `maxWidth` cap must come AFTER padding+background so
    // the bubble hugs its content for short messages. Putting it first creates
    // an invisible 560pt zone that the background expands to fill — the
    // "bubble always stretches edge-to-edge" bug.

    private var userBubble: some View {
        HStack(alignment: .top) {
            Spacer(minLength: 48)
            MarkdownBodyView(text: group.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 560, alignment: .trailing)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Assistant (spoken narrative + conclusion — left bubble)

    private var assistantBubble: some View {
        HStack(alignment: .top) {
            MarkdownBodyView(text: group.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: 680, alignment: .leading)
            Spacer(minLength: 48)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Reasoning (private thinking — left bar, italic, no bubble)

    private var reasoningView: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 3)
            MarkdownBodyView(text: group.text)
                .italic()
                .foregroundStyle(.secondary)
                .frame(maxWidth: 680, alignment: .leading)
            Spacer(minLength: 48)
        }
        .padding(.horizontal, 16)
    }

    // MARK: Tool cluster (consecutive tool rows, tight spacing)

    private var toolCluster: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(group.toolCluster.enumerated()), id: \.offset) { _, info in
                ToolRow(info: info)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }

    // MARK: Todo / error / system / other (fallback bubble)

    @ViewBuilder
    private var sideBubble: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                if showKindHeader {
                    Text(headerLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                bubbleBody
                    .frame(maxWidth: 680, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(background, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(foreground)
            }
            Spacer(minLength: 48)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var bubbleBody: some View {
        Text(group.text)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Styling shared by the left-aligned bubble

    private var showKindHeader: Bool {
        switch group.kind {
        case "todo", "error", "system": return true
        default: return false
        }
    }

    private var headerLabel: String {
        switch group.kind {
        case "todo": "todo"
        case "error": "error"
        case "system": "system"
        default: group.kind
        }
    }

    private var background: Color {
        switch group.kind {
        case "todo": Color.orange.opacity(0.12)
        case "error": Color.red.opacity(0.15)
        default: Color.secondary.opacity(0.1)
        }
    }

    private var foreground: Color {
        switch group.kind {
        case "error": .red
        default: .primary
        }
    }
}

// MARK: - Tool row

/// One tool invocation — name, target (file path / command / query), status.
/// Tap the row (or the chevron) to reveal the detail payload when there is one.
private struct ToolRow: View {
    let info: ConversationViewModel.ToolInfo
    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            summaryRow
            if expanded, info.hasDetail {
                detailView
                    .padding(.leading, 20)
            }
        }
    }

    private var summaryRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: info.iconName)
                .foregroundStyle(.secondary)
                .font(.caption)
                .frame(width: 14)

            Text(info.name)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.primary)

            if let target = info.target, !target.isEmpty {
                Text(truncate(target, max: 96))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let status = statusSuffix {
                Text("· \(status)")
                    .font(.caption)
                    .foregroundStyle(statusColor)
            }

            Spacer(minLength: 0)

            if info.hasDetail {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard info.hasDetail else { return }
            withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
        }
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

    /// Only surface the status when it's interesting — i.e. not a plain
    /// "completed" finish. "running", "failed", "canceled" all surface so the
    /// user knows something's in flight or went wrong.
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
