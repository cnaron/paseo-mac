import SwiftUI

struct ComposerView: View {
    @Bindable var vm: ConversationViewModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextEditor(text: $vm.composerText)
                .font(.body)
                .frame(minHeight: 38, maxHeight: 160)
                .padding(6)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit { submit() }

            Button {
                submit()
            } label: {
                Label("Send", systemImage: "arrow.up.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title2)
            }
            .keyboardShortcut(.return, modifiers: [.command])
            .disabled(vm.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("Send (⌘↩)")
        }
        .padding(12)
    }

    private func submit() {
        Task { await vm.sendComposer() }
    }
}
