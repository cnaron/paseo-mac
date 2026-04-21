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
}

private func groupRows(_ rows: [ConversationViewModel.Row]) -> [BubbleGroup] {
    var out: [BubbleGroup] = []
    let mergeable: Set<String> = ["user", "assistant", "reasoning"]

    for row in rows {
        if let last = out.last,
           last.kind == row.kind,
           mergeable.contains(row.kind) {
            // Join with an empty separator: the daemon splits mid-sentence during
            // streaming, so forcing newlines would insert false paragraph breaks.
            // Block-level parsing (code fences, headings) runs later on the joined text.
            let merged = last.text + row.text
            out.removeLast()
            out.append(BubbleGroup(
                id: last.id,           // keep the first row's id so SwiftUI keeps animation identity
                kind: last.kind,
                text: merged,
                timestamp: last.timestamp
            ))
        } else {
            out.append(BubbleGroup(
                id: row.id,
                kind: row.kind,
                text: row.text,
                timestamp: row.timestamp
            ))
        }
    }
    return out
}

// MARK: - Message list

private struct MessageList: View {
    @Bindable var vm: ConversationViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
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
                .padding(.vertical, 12)
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
        HStack(alignment: .top) {
            if group.kind == "user" { Spacer(minLength: 48) }
            VStack(alignment: alignment, spacing: 4) {
                if showKindHeader {
                    Text(headerLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                bubbleContent
                    .padding(10)
                    .background(background, in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: 640, alignment: .leading)
                    .foregroundStyle(foreground)
            }
            if group.kind != "user" { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var bubbleContent: some View {
        switch group.kind {
        case "user", "assistant", "reasoning":
            MarkdownBodyView(text: group.text)
        case "tool", "todo", "error", "system":
            Text(group.text)
                .font(.system(.body, design: group.kind == "tool" ? .monospaced : .default))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        default:
            Text(group.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var alignment: HorizontalAlignment { group.kind == "user" ? .trailing : .leading }

    private var showKindHeader: Bool {
        group.kind != "user" && group.kind != "assistant"
    }

    private var headerLabel: String {
        switch group.kind {
        case "reasoning": "thinking"
        case "tool": "tool call"
        case "todo": "todo"
        case "error": "error"
        case "system": "system"
        default: group.kind
        }
    }

    private var background: Color {
        switch group.kind {
        case "user": Color.accentColor.opacity(0.18)
        case "assistant": Color.secondary.opacity(0.12)
        case "reasoning": Color.secondary.opacity(0.08)
        case "tool": Color.indigo.opacity(0.15)
        case "todo": Color.orange.opacity(0.12)
        case "error": Color.red.opacity(0.15)
        default: Color.secondary.opacity(0.1)
        }
    }

    private var foreground: Color {
        switch group.kind {
        case "reasoning": .secondary
        case "error": .red
        default: .primary
        }
    }
}
