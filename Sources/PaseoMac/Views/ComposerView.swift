import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var vm: ConversationViewModel
    @Environment(AppViewModel.self) private var app
    @Environment(SettingsStore.self) private var settings
    @FocusState private var focused: Bool
    @State private var dropError: String? = nil
    /// Height of the composer at the moment a drag began. Snapshot so we can
    /// compute `start - delta.height` without compounding.
    @State private var dragStartHeight: Double? = nil
    @State private var textFitHeight: Double = 44.0
    @State private var sentHistory: [String] = []

    var body: some View {
        VStack(spacing: 0) {
            // Queued messages above the card
            if !vm.queued.isEmpty {
                queuedStrip
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial,
                                in: RoundedRectangle(cornerRadius: 14))
                    .shadow(color: .black.opacity(0.08), radius: 8, y: -2)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 6)
            }
            composerCard
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)

        }
    }

    // MARK: - Composer card

    private var composerCard: some View {
        @Bindable var settings = settings
        return VStack(alignment: .leading, spacing: 0) {
            // Invisible resize zone — drag upward to expand text area
            Color.clear
                .frame(maxWidth: .infinity).frame(height: 8)
                .contentShape(Rectangle())
                .onHover { if $0 { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let start = dragStartHeight ?? settings.composerHeight
                            if dragStartHeight == nil { dragStartHeight = start }
                            let proposed = start - Double(value.translation.height)
                            let r = SettingsStore.composerHeightRange
                            settings.composerHeight = min(max(proposed, r.lowerBound), r.upperBound)
                        }
                        .onEnded { _ in dragStartHeight = nil }
                )
                .help("Drag to resize · double-click to reset")
                .onTapGesture(count: 2) { settings.composerHeight = 44 }

            // Attachment chips
            if !vm.pendingImages.isEmpty || !vm.pendingTextFiles.isEmpty {
                attachmentStrip
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }
            if let err = dropError {
                Text(err).font(.caption).foregroundStyle(.red)
                    .padding(.horizontal, 12)
            }

            // Text input (placeholder drawn natively by DropInterceptingTextView)
            ComposerTextView(
                text: $vm.composerText,
                height: $textFitHeight,
                font: .systemFont(ofSize: NSFont.systemFontSize),
                sentHistory: sentHistory,
                onFileDrop: { urls in handleFileURLDrop(urls) },
                onImageDrop: { images in handleImageDrop(images) }
            )
            .frame(height: CGFloat(settings.composerHeight))
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            // Bottom action row
            bottomActionRow
        }
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.secondary.opacity(0.15), lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .frame(maxWidth: 720)
        .onChange(of: vm.composerText) { vm.saveDraft() }
        .onChange(of: vm.rows.count) { updateSentHistory() }
        .onAppear { updateSentHistory() }
    }

    private func updateSentHistory() {
        sentHistory = vm.rows.filter { $0.kind == "user" && !$0.text.isEmpty }
            .map { $0.text }.reversed()
    }

    // MARK: - Bottom action row

    private var bottomActionRow: some View {
        HStack(alignment: .center, spacing: 8) {
            // + attachment button
            Button { openAttachmentPicker() } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Color.secondary.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .help("Add attachment")

            Spacer()

            // Model + thinking + mode pickers (right-aligned text)
            if let agent = app.agents.first(where: { $0.id == vm.agentId }) {
                HStack(spacing: 2) {
                    ModePicker(agent: agent)
                    ModelPicker(agent: agent)
                    ThinkingPicker(agent: agent)
                }
                .font(.callout)
            }

            // Send / interrupt button (circle style)
            sendButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var sendButton: some View {
        if vm.isAgentWorking {
            HStack(spacing: 6) {
                Button { submit() } label: {
                    ZStack {
                        Circle()
                            .fill(isSendDisabled
                                  ? Color.secondary.opacity(0.12)
                                  : Color.accentColor.opacity(0.18))
                            .frame(width: 28, height: 28)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(
                                isSendDisabled
                                ? Color.secondary.opacity(0.4)
                                : Color.accentColor
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(isSendDisabled)
                .keyboardShortcut(.return, modifiers: [.command])
                .help("Queue (⌘↩)")

                Button { interrupt() } label: {
                    ZStack {
                        Circle().fill(Color.primary).frame(width: 28, height: 28)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(NSColor.controlBackgroundColor))
                            .frame(width: 10, height: 10)
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.return, modifiers: [.command, .shift])
                .help("Interrupt (⌘⇧↩)")
            }
        } else {
            Button { submit() } label: {
                ZStack {
                    Circle()
                        .fill(isSendDisabled ? Color.secondary.opacity(0.12) : Color.primary)
                        .frame(width: 28, height: 28)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(
                            isSendDisabled
                            ? Color.secondary.opacity(0.4)
                            : Color(NSColor.controlBackgroundColor)
                        )
                }
            }
            .buttonStyle(.plain)
            .disabled(isSendDisabled)
            .keyboardShortcut(.return, modifiers: [.command])
            .help("Send (⌘↩)")
        }
    }

    private func openAttachmentPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        // Only types Claude Code can actually consume: images (vision) and text/source (inlined)
        panel.allowedContentTypes = [
            .image, .text, .sourceCode, .json, .xml, .commaSeparatedText, .shellScript,
        ]
        panel.begin { response in
            guard response == .OK else { return }
            handleFileURLDrop(panel.urls)
        }
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

    // MARK: - Queued-message strip

    private var queuedStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Queued · click to edit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(vm.queued) { q in
                HStack(spacing: 6) {
                    Text(q.preview)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(.primary)
                    if !q.images.isEmpty {
                        Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        vm.editQueued(id: q.id)
                    } label: {
                        Image(systemName: "pencil.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Edit this message")
                    Button {
                        vm.removeQueued(id: q.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from queue")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                .onTapGesture { vm.editQueued(id: q.id) }
            }
        }
    }

    private func interrupt() {
        Task { await vm.sendInterrupting() }
    }

    // MARK: - Send gating

    private var isSendDisabled: Bool {
        vm.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && vm.pendingImages.isEmpty
            && vm.pendingTextFiles.isEmpty
    }

    private func submit() {
        if app.pendingNewAgentCwd != nil {
            let text = vm.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
            vm.composerText = ""
            vm.pendingImages = []
            vm.pendingTextFiles = []
            Task { await app.submitPendingAgent(text: text) }
        } else {
            Task { await vm.sendComposer() }
        }
    }

    // MARK: - Drop handlers (from ComposerTextView)

    private func handleFileURLDrop(_ urls: [URL]) {
        dropError = nil
        for url in urls {
            if let imgAtt = PendingImageAttachment.fromFileURL(url) {
                vm.addImages([imgAtt])
                continue
            }
            do {
                let file = try PendingTextFile.fromFileURL(url)
                vm.addTextFile(file)
            } catch {
                dropError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }

    private func handleImageDrop(_ images: [NSImage]) {
        let attachments = images.compactMap { PendingImageAttachment.from(image: $0) }
        if !attachments.isEmpty { vm.addImages(attachments) }
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
                    // 2) Text files only — binary files are not readable by Claude Code.
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
                Image(systemName: currentIcon(modes: modes))
                    .font(.system(size: 12))
                    .foregroundStyle(modeColor)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Permission mode: \(currentLabel(modes: modes))")
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
                Text(currentLabel)
                    .foregroundStyle(.secondary)
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
                HStack(spacing: 3) {
                    Text(currentLabel(options: options))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
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

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let ns = NSImage(data: attachment.pngData) {
                    Image(nsImage: ns)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
                        )
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.ultraThinMaterial)
                        .frame(width: 64, height: 64)
                }
            }
            .shadow(color: .black.opacity(0.12), radius: 4, y: 2)

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .padding(3)
            .help("Remove")
        }
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

private struct FileChip: View {
    let file: PendingFileAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: file.iconName)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                Text(file.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(formatSize(file.data.count))
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

    private func formatSize(_ bytes: Int) -> String {
        if bytes >= 1_048_576 { return String(format: "%.1f MB", Double(bytes) / 1_048_576) }
        if bytes >= 1024 { return "\(bytes / 1024) KB" }
        return "\(bytes) B"
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
