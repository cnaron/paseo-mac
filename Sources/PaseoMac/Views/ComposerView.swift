import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var vm: ConversationViewModel
    @Environment(AppViewModel.self) private var app
    @FocusState private var focused: Bool
    @State private var isDropTargeted: Bool = false
    @State private var dropError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !vm.pendingImages.isEmpty || !vm.pendingTextFiles.isEmpty {
                attachmentStrip
            }
            if let err = dropError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            inputRow
                .overlay(alignment: .topLeading) {
                    if isDropTargeted {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                            .allowsHitTesting(false)
                            .padding(.horizontal, 6)
                    }
                }
            pickerRow
        }
        .padding(12)
        .onPasteCommand(of: supportedPasteTypes, perform: handlePaste)
        .onDrop(of: [.image, .fileURL, .plainText], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    // MARK: - Attachment strip (images + text files)

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.pendingImages) { att in
                    ImageChip(attachment: att) { vm.removeImage(id: att.id) }
                }
                ForEach(vm.pendingTextFiles) { f in
                    TextFileChip(file: f) { vm.removeTextFile(id: f.id) }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var inputRow: some View {
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
            .disabled(isSendDisabled)
            .help("Send (⌘↩)")
        }
    }

    // MARK: - Picker row (mode / model / thinking)

    @ViewBuilder
    private var pickerRow: some View {
        if let agent = app.agents.first(where: { $0.id == vm.agentId }) {
            HStack(spacing: 12) {
                ModePicker(agent: agent)
                ModelPicker(agent: agent)
                ThinkingPicker(agent: agent)
                Spacer()
            }
            .font(.caption)
        }
    }

    // MARK: - Send gating

    private var isSendDisabled: Bool {
        vm.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && vm.pendingImages.isEmpty
            && vm.pendingTextFiles.isEmpty
    }

    private func submit() {
        Task { await vm.sendComposer() }
    }

    // MARK: - Paste

    private var supportedPasteTypes: [UTType] {
        [.image, .png, .jpeg, .tiff, .gif, .bmp, .fileURL]
    }

    private func handlePaste(_: [NSItemProvider]) {
        let images = PasteboardHelper.extractImages(from: NSPasteboard.general)
        if !images.isEmpty {
            vm.addImages(images)
        }
    }

    // MARK: - Drop

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        dropError = nil
        var consumed = false
        for provider in providers {
            if provider.canLoadObject(ofClass: NSImage.self) {
                consumed = true
                _ = provider.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let image = obj as? NSImage,
                          let att = PendingImageAttachment.from(image: image) else { return }
                    Task { @MainActor in vm.addImages([att]) }
                }
                continue
            }
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                consumed = true
                _ = provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier,
                    options: nil
                ) { item, _ in
                    guard let url = resolveFileURLNonIsolated(from: item) else { return }
                    // 1) Image path stays dedicated.
                    if let imgAtt = PendingImageAttachment.fromFileURL(url) {
                        Task { @MainActor in vm.addImages([imgAtt]) }
                        return
                    }
                    // 2) Otherwise try to slurp as a text file.
                    do {
                        let file = try PendingTextFile.fromFileURL(url)
                        Task { @MainActor in vm.addTextFile(file) }
                    } catch {
                        let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                        Task { @MainActor in dropError = msg }
                    }
                }
            }
        }
        return consumed
    }
}

// MARK: - Pickers

private struct ModePicker: View {
    let agent: AgentSnapshot
    @Environment(AppViewModel.self) private var app

    var body: some View {
        if let modes = agent.availableModes, !modes.isEmpty {
            Menu {
                ForEach(modes) { mode in
                    Button {
                        Task { await app.setAgentMode(agentId: agent.id, modeId: mode.id) }
                    } label: {
                        Label(
                            mode.label + (mode.id == agent.currentModeId ? "  ✓" : ""),
                            systemImage: iconFor(mode: mode)
                        )
                    }
                }
            } label: {
                Label(
                    currentLabel(modes: modes),
                    systemImage: currentIcon(modes: modes)
                )
                .foregroundStyle(modeColor)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Permission mode")
        }
    }

    private func currentLabel(modes: [AgentMode]) -> String {
        modes.first(where: { $0.id == agent.currentModeId })?.label ?? "Mode"
    }
    private func currentIcon(modes: [AgentMode]) -> String {
        iconFor(mode: modes.first { $0.id == agent.currentModeId })
    }
    private var modeColor: Color {
        switch agent.currentModeId {
        case "bypassPermissions": return .red
        case "acceptEdits": return .orange
        case "plan": return .blue
        default: return .secondary
        }
    }
    private func iconFor(mode: AgentMode?) -> String {
        switch mode?.id {
        case "bypassPermissions": return "shield.slash"
        case "acceptEdits": return "checkmark.shield"
        case "plan": return "list.bullet.rectangle"
        default: return "shield"
        }
    }
}

private struct ModelPicker: View {
    let agent: AgentSnapshot
    @Environment(AppViewModel.self) private var app

    var body: some View {
        if let models = availableModels, !models.isEmpty {
            Menu {
                ForEach(models) { m in
                    Button {
                        Task { await app.setAgentModel(agentId: agent.id, modelId: m.id) }
                    } label: {
                        let checkmark = m.id == agent.model ? "  ✓" : ""
                        Text(m.label + checkmark)
                    }
                }
            } label: {
                Label(currentLabel, systemImage: "sparkles")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Model")
        }
    }

    private var availableModels: [ModelDefinition]? {
        guard let prov = agent.provider,
              let snapshot = app.providers.first(where: { $0.provider == prov }) else { return nil }
        return snapshot.models
    }
    private var currentLabel: String {
        if let models = availableModels,
           let current = models.first(where: { $0.id == agent.model }) {
            return current.label
        }
        return agent.model ?? "Model"
    }
}

private struct ThinkingPicker: View {
    let agent: AgentSnapshot
    @Environment(AppViewModel.self) private var app

    var body: some View {
        if let options = thinkingOptions, !options.isEmpty {
            Menu {
                ForEach(options) { opt in
                    Button {
                        Task { await app.setAgentThinking(agentId: agent.id, thinkingOptionId: opt.id) }
                    } label: {
                        Text(opt.label + (opt.id == agent.effectiveThinkingOptionId ? "  ✓" : ""))
                    }
                }
            } label: {
                Label(currentLabel(options: options), systemImage: "brain")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Thinking level")
        }
    }

    private var thinkingOptions: [SelectOption]? {
        guard let prov = agent.provider,
              let snapshot = app.providers.first(where: { $0.provider == prov }),
              let models = snapshot.models,
              let model = models.first(where: { $0.id == agent.model })
        else { return nil }
        return model.thinkingOptions
    }
    private func currentLabel(options: [SelectOption]) -> String {
        options.first(where: { $0.id == agent.effectiveThinkingOptionId })?.label ?? "Thinking"
    }
}

// MARK: - Chips

private struct ImageChip: View {
    let attachment: PendingImageAttachment
    let onRemove: () -> Void
    @State private var thumbImage: NSImage? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumb = thumbImage {
                    Image(nsImage: thumb).resizable().scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.2))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            removeButton
        }
        .task { thumbImage = attachment.thumbnail() }
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(.white, .black.opacity(0.6))
        }
        .buttonStyle(.plain)
        .padding(2)
        .help("Remove attachment")
    }
}

private struct TextFileChip: View {
    let file: PendingTextFile
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.secondary)
                Text(file.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(file.content.count) chars")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .frame(width: 140, height: 64, alignment: .topLeading)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(2)
            .help("Remove file")
        }
    }
}

/// Non-isolated so it can be called from provider callbacks that run off
/// the main actor without tripping Swift-6 data-race checking.
private func resolveFileURLNonIsolated(from item: NSSecureCoding?) -> URL? {
    if let url = item as? URL { return url }
    if let data = item as? Data {
        return URL(dataRepresentation: data, relativeTo: nil)
    }
    return nil
}
