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
            // Subagents linked to this parent agent. Surfaces above the
            // composer so users can pivot between the main agent and its
            // children without leaving the conversation.
            SubagentSection(parentAgentId: vm.agentId)
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
                forceUpdate: vm.composerForceUpdate,
                onFileDrop: { urls in handleFileURLDrop(urls) },
                onImageDrop: { images in handleImageDrop(images) },
                onLargeTextPaste: { text in handleLargeTextPaste(text) }
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

            // Inline context window bar for the active agent. Toolbar
            // already has a chip, but the composer is what the user is
            // actually looking at while typing — so the same data lives
            // here too, in a slimmer form.
            if let agent = app.agents.first(where: { $0.id == vm.agentId }),
               let used = agent.lastUsage?.contextWindowUsedTokens,
               let max = agent.lastUsage?.contextWindowMaxTokens, max > 0 {
                ComposerContextBar(used: used, max: max)
            }

            Spacer()

            // Model + thinking + mode pickers (right-aligned text)
            HStack(spacing: 2) {
                if app.pendingNewAgentCwd != nil {
                    PendingWorktreeToggle()
                    PendingModePicker()
                    PendingModelPicker()
                    PendingThinkingPicker()
                    PendingProviderPicker()
                } else if let agent = app.agents.first(where: { $0.id == vm.agentId }) {
                    ModePicker(agent: agent)
                    ModelPicker(agent: agent)
                    ThinkingPicker(agent: agent)
                }
            }
            .font(.callout)

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
                Image(systemName: vm.turnLooksStuck ? "exclamationmark.triangle.fill" : "clock.arrow.circlepath")
                    .font(.caption2)
                    .foregroundStyle(vm.turnLooksStuck ? .orange : .secondary)
                Text(vm.turnLooksStuck
                     ? "Previous turn looks stuck — daemon hasn't said it's done"
                     : "Queued · click to edit")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                // Always-available escape hatch. Cancels any in-flight
                // turn, clears the local working flag, and flushes the
                // whole queue. The "looks stuck" copy above and a
                // contrastier button color make it discoverable when the
                // turn has actually gone stale, but the button works
                // regardless so a user who just changed their mind can
                // also use it.
                Button {
                    Task { await vm.forceSendAnyway() }
                } label: {
                    Text("Send anyway")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            (vm.turnLooksStuck ? Color.orange : Color.accentColor).opacity(0.85),
                            in: Capsule()
                        )
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Cancel any stuck turn, then send everything in the queue")
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
            let images = vm.pendingImages
            vm.composerText = ""
            vm.pendingImages = []
            vm.pendingTextFiles = []
            Task { await app.submitPendingAgent(text: text, images: images) }
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

    private func handleLargeTextPaste(_ text: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HHmmss"
        let name = "Pasted-\(formatter.string(from: Date())).txt"
        let file = PendingTextFile(
            id: UUID(),
            name: name,
            content: text,
            languageHint: nil
        )
        vm.addTextFile(file)
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
        case "bypassPermissions", "full-access": return .red
        case "acceptEdits", "auto": return .orange
        case "plan": return .blue
        case "auto-review": return .green
        default: return .secondary
        }
    }
    private func iconFor(mode: AgentMode?) -> String {
        switch mode?.id {
        case "bypassPermissions", "full-access": return "shield.slash"
        case "acceptEdits": return "checkmark.shield"
        case "plan": return "list.bullet.rectangle"
        case "auto": return "shield.lefthalf.filled"
        case "auto-review": return "eye.trianglebadge.exclamationmark"
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
        // Filter out models the user has been gated out of (e.g. [1m]
        // variants that need extra usage enabled at claude.ai/settings/usage).
        // If the current agent.model is blocked, keep it visible so the
        // picker can still show "checked" and let them switch away.
        return snapshot.models?.filter { m in
            m.id == agent.model || !app.isModelBlocked(provider: prov, modelId: m.id)
        }
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
        return model.thinkingOptions?.filter { !brokenThinkingOptionIds.contains($0.id) }
    }
    private func currentLabel(options: [SelectOption]) -> String {
        options.first(where: { $0.id == agent.effectiveThinkingOptionId })?.label ?? "Thinking"
    }
}

// MARK: - Pending-agent pickers (used before a new conversation is created)

/// Toggle that requests the daemon spin up a fresh git worktree for the
/// pending agent and auto-archive it (pruning the worktree) when the run
/// ends. Only meaningful on daemon ≥ 0.1.79; on older daemons the field
/// is ignored and the agent runs in `cwd` like any other.
private struct PendingWorktreeToggle: View {
    @Environment(AppViewModel.self) private var app

    var body: some View {
        Button {
            app.pendingNewAgentAutoArchiveWorktree.toggle()
        } label: {
            Image(systemName: app.pendingNewAgentAutoArchiveWorktree
                  ? "arrow.triangle.branch"
                  : "arrow.triangle.branch")
                .foregroundStyle(app.pendingNewAgentAutoArchiveWorktree ? Color.accentColor : .secondary)
                .font(.callout)
                .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .help(app.pendingNewAgentAutoArchiveWorktree
              ? "Create a fresh worktree and auto-archive when the agent finishes (daemon ≥ 0.1.79)"
              : "Run in current working directory")
    }
}

private struct PendingProviderPicker: View {
    @Environment(AppViewModel.self) private var app

    var body: some View {
        // Show the picker whenever the daemon has reported any provider at
        // all. Even with one ready provider, surfacing the picker (with
        // unavailable entries disabled) tells the user which others exist
        // and why they're not yet usable — instead of silently hiding them.
        let allProviders = orderedProviders()
        let ready = allProviders.filter { $0.status == "ready" }
        if allProviders.count > 1 || (ready.count == 1 && ready[0].provider != app.pendingNewAgentProvider) {
            Menu {
                ForEach(ready) { prov in
                    Button {
                        if prov.provider != app.pendingNewAgentProvider {
                            app.pendingNewAgentProvider = prov.provider
                            app.pendingNewAgentModel = nil
                            app.pendingNewAgentModeId = nil
                            app.pendingNewAgentThinkingOptionId = nil
                        }
                    } label: {
                        Text((prov.label ?? prov.provider.capitalized) + (prov.provider == app.pendingNewAgentProvider ? "  ✓" : ""))
                    }
                }
                let notReady = allProviders.filter { $0.status != "ready" }
                if !notReady.isEmpty {
                    Divider()
                    ForEach(notReady) { prov in
                        Button {
                            // No-op: disabled providers aren't selectable. SwiftUI's
                            // Menu has no .disabled per-row, so we render them as
                            // buttons that toast the reason on click.
                            EventLogger.shared.log("provider", "unavailable_clicked", [
                                "provider": prov.provider,
                                "status": prov.status,
                                "error": prov.error ?? "<none>",
                            ])
                        } label: {
                            Text("\(prov.label ?? prov.provider.capitalized) — \(prov.status)")
                        }
                        .disabled(true)
                    }
                }
            } label: {
                Text(currentProviderLabel(allProviders))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Provider")
        }
    }

    private func orderedProviders() -> [ProviderSnapshot] {
        // Stable, intentional order. Anything not in the list falls in
        // alphabetical order at the end so newer ACP catalog entries still
        // appear without code changes.
        let priority = ["claude", "codex", "antigravity", "gemini", "opencode", "copilot", "pi"]
        let known = priority.compactMap { id in
            app.providers.first(where: { $0.provider == id })
        }
        let extras = app.providers
            .filter { p in !priority.contains(p.provider) }
            .sorted { ($0.label ?? $0.provider) < ($1.label ?? $1.provider) }
        return known + extras
    }

    private func currentProviderLabel(_ providers: [ProviderSnapshot]) -> String {
        providers.first(where: { $0.provider == app.pendingNewAgentProvider })?.label
            ?? app.pendingNewAgentProvider.capitalized
    }
}

private struct PendingModelPicker: View {
    @Environment(AppViewModel.self) private var app

    var body: some View {
        if let models = availableModels, !models.isEmpty {
            let split = Self.partition(models, provider: app.pendingNewAgentProvider)
            Menu {
                ForEach(split.primary) { m in
                    Button {
                        app.pendingNewAgentModel = m.id
                        app.pendingNewAgentThinkingOptionId = nil
                    } label: {
                        Text(m.label + (m.id == effectiveModelId ? "  ✓" : ""))
                    }
                }
                if !split.secondary.isEmpty {
                    Divider()
                    ForEach(split.secondary) { m in
                        Button {
                            app.pendingNewAgentModel = m.id
                            app.pendingNewAgentThinkingOptionId = nil
                        } label: {
                            Text(m.label + (m.id == effectiveModelId ? "  ✓" : ""))
                        }
                    }
                }
            } label: {
                Text(currentModelLabel)
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Model")
        }
    }

    private var availableModels: [ModelDefinition]? {
        guard let snap = app.providers.first(where: { $0.provider == app.pendingNewAgentProvider }) else { return nil }
        return snap.models?.filter { !app.isModelBlocked(provider: snap.provider, modelId: $0.id) }
    }
    private var effectiveModelId: String? {
        app.pendingNewAgentModel ?? availableModels?.first(where: { $0.isDefault == true })?.id ?? availableModels?.first?.id
    }
    private var currentModelLabel: String {
        guard let models = availableModels else { return "Model" }
        let id = effectiveModelId
        return models.first(where: { $0.id == id })?.label ?? "Model"
    }

    /// Split models into a primary section (most useful: default model
    /// plus any provider-specific "favored" variants) and a secondary
    /// section (everything else: mini/older/etc.). Codex returns 5
    /// models and the picker becomes tedious to scan; this brings the
    /// likely picks to the top without hiding the rest.
    private struct ModelSplit {
        var primary: [ModelDefinition]
        var secondary: [ModelDefinition]
    }

    private static func partition(_ models: [ModelDefinition], provider: String) -> ModelSplit {
        var primary: [ModelDefinition] = []
        var secondary: [ModelDefinition] = []
        for m in models {
            if isPrimary(m, provider: provider) { primary.append(m) }
            else { secondary.append(m) }
        }
        // Only split if both sides are non-trivial. Otherwise show one flat list.
        if primary.isEmpty || secondary.isEmpty {
            return ModelSplit(primary: models, secondary: [])
        }
        return ModelSplit(primary: primary, secondary: secondary)
    }

    private static func isPrimary(_ m: ModelDefinition, provider: String) -> Bool {
        if m.isDefault == true { return true }
        let id = m.id.lowercased()
        switch provider {
        case "codex":
            // Codex catalog includes -mini and older versions that most
            // users rarely pick — keep the coding-tuned variant at the top.
            return id.contains("codex")
        case "claude":
            // 1M-context Opus variants and the newest Opus are the
            // common Claude picks. Push Sonnet / Haiku to the secondary list.
            return id.contains("opus")
        default:
            return false
        }
    }
}

private struct PendingModePicker: View {
    @Environment(AppViewModel.self) private var app

    var body: some View {
        if let modes = availableModes, !modes.isEmpty {
            Menu {
                ForEach(modes) { mode in
                    Button {
                        app.pendingNewAgentModeId = mode.id
                    } label: {
                        Label(
                            mode.label + (mode.id == effectiveModeId ? "  ✓" : ""),
                            systemImage: iconFor(mode: mode)
                        )
                    }
                }
            } label: {
                Image(systemName: currentIcon)
                    .font(.system(size: 12))
                    .foregroundStyle(modeColor)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Permission mode: \(currentModeLabel)")
        }
    }

    private var availableModes: [AgentMode]? {
        app.providers.first(where: { $0.provider == app.pendingNewAgentProvider })?.modes
    }
    private var effectiveModeId: String? {
        if let id = app.pendingNewAgentModeId { return id }
        let prov = app.providers.first(where: { $0.provider == app.pendingNewAgentProvider })
        return prov?.defaultModeId ?? availableModes?.first?.id
    }
    private var currentModeLabel: String {
        availableModes?.first(where: { $0.id == effectiveModeId })?.label ?? "Mode"
    }
    private var currentIcon: String {
        iconFor(mode: availableModes?.first { $0.id == effectiveModeId })
    }
    private var modeColor: Color {
        switch effectiveModeId {
        case "bypassPermissions", "full-access": return .red
        case "acceptEdits", "auto": return .orange
        case "plan": return .blue
        case "auto-review": return .green
        default: return .secondary
        }
    }
    private func iconFor(mode: AgentMode?) -> String {
        switch mode?.id {
        case "bypassPermissions", "full-access": return "shield.slash"
        case "acceptEdits": return "checkmark.shield"
        case "plan": return "list.bullet.rectangle"
        case "auto": return "shield.lefthalf.filled"
        case "auto-review": return "eye.trianglebadge.exclamationmark"
        default: return "shield"
        }
    }
}

// MARK: - Chips

private struct ImageChip: View {
    let attachment: PendingImageAttachment
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let ns = NSImage(contentsOf: attachment.fileURL) {
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



// MARK: - Known-broken thinking options
//
// Hook left here in case a future daemon regresses on a specific option
// (e.g. "max"). The actual turn-1 race that fails new conversations with
// "Cannot read properties of null (reading 'push')" was fixed in build 37
// by passing thinkingOptionId inside createAgent's config instead of
// firing set_agent_thinking_request after the agent exists. Both "max"
// and "xhigh" had reproduced under the post-create path on daemon 0.1.70.
let brokenThinkingOptionIds: Set<String> = []

// MARK: - Pending thinking picker (for new conversation)

private struct PendingThinkingPicker: View {
    @Environment(AppViewModel.self) private var app

    var body: some View {
        if let options = thinkingOptions, !options.isEmpty {
            Menu {
                ForEach(options) { opt in
                    Button {
                        app.pendingNewAgentThinkingOptionId = opt.id
                    } label: {
                        Text(opt.label + (opt.id == effectiveId ? "  ✓" : ""))
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(currentLabel)
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

    private var currentModel: ModelDefinition? {
        let prov = app.providers.first(where: { $0.provider == app.pendingNewAgentProvider })
        let modelId = app.pendingNewAgentModel
            ?? prov?.models?.first(where: { $0.isDefault == true })?.id
            ?? prov?.models?.first?.id
        return prov?.models?.first(where: { $0.id == modelId })
    }
    private var thinkingOptions: [SelectOption]? {
        currentModel?.thinkingOptions?.filter { !brokenThinkingOptionIds.contains($0.id) }
    }
    private var effectiveId: String? {
        app.pendingNewAgentThinkingOptionId ?? currentModel?.defaultThinkingOptionId
    }
    private var currentLabel: String {
        thinkingOptions?.first(where: { $0.id == effectiveId })?.label ?? "Thinking"
    }
}

// MARK: - Subagent section

/// Shows the subagents linked to the current parent agent above the
/// composer. Mirrors upstream `packages/app/src/subagents/section.tsx`:
/// collapsed pill (`N subagents · M running`) with chevron, expands into
/// a scrollable list with click-to-focus + archive button per row.
/// Hides entirely when the agent has no subagents — costs nothing
/// vertically in the common case.
private struct SubagentSection: View {
    let parentAgentId: String
    @Environment(AppViewModel.self) private var app
    @State private var expanded = false

    var body: some View {
        let kids = subagents
        if !kids.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header(kids)
                if expanded { listBody(kids) }
            }
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 20)
            .padding(.bottom, 6)
        }
    }

    private var subagents: [AgentSnapshot] {
        app.agents.filter { $0.parentAgentId == parentAgentId && $0.archivedAt == nil }
    }

    private func header(_ kids: [AgentSnapshot]) -> some View {
        let running = kids.filter { $0.status == "running" }.count
        return Button { withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() } } label: {
            HStack(spacing: 8) {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(kids.count) subagent\(kids.count == 1 ? "" : "s")")
                    .font(.callout)
                    .foregroundStyle(.primary)
                if running > 0 {
                    Text("· \(running) running")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func listBody(_ kids: [AgentSnapshot]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(kids) { kid in
                    SubagentRow(agent: kid)
                    if kid.id != kids.last?.id {
                        Divider().padding(.leading, 12)
                    }
                }
            }
            .padding(.bottom, 6)
        }
        .frame(maxHeight: 200)
    }
}

private struct SubagentRow: View {
    let agent: AgentSnapshot
    @Environment(AppViewModel.self) private var app

    var body: some View {
        Button { app.selectedAgentId = agent.id } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(agent.displayName)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let mode = agent.currentModeId {
                    Text(mode)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await app.archiveAgent(agentId: agent.id) }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Archive subagent")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var statusColor: Color {
        switch agent.status {
        case "running": return .green
        case "error", "failed": return .red
        case "idle": return .cyan
        default: return .gray
        }
    }
}

// MARK: - Composer context bar

/// Thin inline progress bar that mirrors the toolbar UsageChip but sits
/// inside the composer for at-a-glance "how full is my context" while
/// typing. Goes through the same color thresholds (orange at 70%,
/// red at 90%) so the user learns a single mental model. Tooltip carries
/// the exact numbers so we don't crowd the bottom row.
struct ComposerContextBar: View {
    let used: Int
    let max: Int

    var body: some View {
        let ratio = self.max > 0 ? min(1.0, Double(used) / Double(self.max)) : 0
        HStack(spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.18))
                    Capsule()
                        .fill(barColor(ratio))
                        .frame(width: geo.size.width * ratio)
                }
            }
            .frame(width: 36, height: 4)
            Text("\(Int(ratio * 100))%")
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .help("Context: \(used.formatted()) / \(self.max.formatted()) tokens (\(Int(ratio * 100))%)")
    }

    private func barColor(_ ratio: Double) -> Color {
        if ratio >= 0.9 { return .red }
        if ratio >= 0.7 { return .orange }
        return .accentColor
    }
}
