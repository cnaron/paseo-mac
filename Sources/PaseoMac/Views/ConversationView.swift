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
                    ForEach(vm.rows) { row in
                        MessageBubble(row: row)
                            .id(row.id)
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
        }
    }
}

private struct MessageBubble: View {
    let row: ConversationViewModel.Row

    var body: some View {
        HStack(alignment: .top) {
            if row.kind == "user" { Spacer(minLength: 48) }
            VStack(alignment: alignment, spacing: 4) {
                if showKindHeader {
                    Text(headerLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(row.text)
                    .textSelection(.enabled)
                    .font(.body)
                    .foregroundStyle(foreground)
                    .padding(10)
                    .background(background, in: RoundedRectangle(cornerRadius: 10))
                    .frame(maxWidth: 640, alignment: .leading)
            }
            if row.kind != "user" { Spacer(minLength: 48) }
        }
        .padding(.horizontal, 16)
    }

    private var alignment: HorizontalAlignment { row.kind == "user" ? .trailing : .leading }

    private var showKindHeader: Bool {
        row.kind != "user" && row.kind != "assistant"
    }

    private var headerLabel: String {
        switch row.kind {
        case "reasoning": "thinking"
        case "tool": "tool call"
        case "todo": "todo"
        case "error": "error"
        case "system": "system"
        default: row.kind
        }
    }

    private var background: Color {
        switch row.kind {
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
        switch row.kind {
        case "reasoning": .secondary
        case "error": .red
        default: .primary
        }
    }
}
