import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Composer (prototype `Composer`)
//
// Reuses the existing `ComposerTextView` (NSTextView input: IME, paste, drop)
// and the ConversationViewModel send pipeline. Restyled to the design with
// model / permission-mode (risk-colored) / thinking pickers, attachments,
// queue strip, context+cost bar, and send → queue+interrupt.

struct ComposerCard: View {
    let vm: ConversationViewModel
    @Environment(AppViewModel.self) private var app
    @Environment(SettingsStore.self) private var settings
    @Environment(\.accent) private var accent
    @State private var focused = false
    @State private var textHeight: Double = 88
    @State private var dropError: String? = nil
    @State private var dragStart: Double? = nil

    private var agent: AgentSnapshot? { app.agents.first { $0.id == vm.agentId } }
    private var pending: Bool { app.pendingNewAgentCwd != nil }

    var body: some View {
        VStack(spacing: 0) {
            if !vm.queued.isEmpty { queueStrip.padding(.bottom, 8) }
            card
        }
        .frame(maxWidth: DS.transcriptMaxW)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
        .padding(.bottom, 14)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            resizeGrip
            if !vm.pendingImages.isEmpty || !vm.pendingTextFiles.isEmpty { attachments.padding(.horizontal, 14).padding(.bottom, 2) }
            if let e = dropError { Text(e).font(.system(size: 12)).foregroundStyle(DS.red).padding(.horizontal, 14) }

            ComposerTextView(
                text: Binding(get: { vm.composerText }, set: { vm.composerText = $0; vm.saveDraft() }),
                height: $textHeight,
                font: .systemFont(ofSize: CGFloat(settings.fontSize)),
                sentHistory: vm.rows.filter { $0.kind == "user" && !$0.text.isEmpty }.map(\.text).reversed(),
                forceUpdate: vm.composerForceUpdate,
                onFileDrop: handleFileDrop,
                onImageDrop: handleImageDrop,
                onLargeTextPaste: handleLargePaste
            )
            .frame(height: CGFloat(settings.composerHeight))
            .padding(.horizontal, 14).padding(.top, 8).padding(.bottom, 4)

            actionRow
        }
        .background(DS.contentBG, in: RoundedRectangle(cornerRadius: DS.R.composer))
        .overlay(RoundedRectangle(cornerRadius: DS.R.composer).strokeBorder(focused ? accent.ring : DS.dividerStrong, lineWidth: focused ? 2 : 1))
        .dsShadow((color: Color.black.opacity(0.05), radius: 3, y: 1))
    }

    private var resizeGrip: some View {
        Color.clear.frame(maxWidth: .infinity).frame(height: 8)
            .overlay(Capsule().fill(DS.dividerStrong.opacity(0.6)).frame(width: 26, height: 3))
            .contentShape(Rectangle())
            .onHover { $0 ? NSCursor.resizeUpDown.push() : NSCursor.pop() }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    let start = dragStart ?? settings.composerHeight
                    if dragStart == nil { dragStart = start }
                    let r = SettingsStore.composerHeightRange
                    settings.composerHeight = min(max(start - Double(v.translation.height), r.lowerBound), r.upperBound)
                }
                .onEnded { _ in dragStart = nil })
            .onTapGesture(count: 2) { settings.composerHeight = 88 }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            IconButton(icon: "plus", box: 28, glyph: 18, help: "添加附件", action: openPicker)
            ModelPickerPill(agent: agent)
            ModePickerPill(agent: agent)
            ThinkingPickerPill(agent: agent)
            Spacer(minLength: 6)
            contextBar
            IconButton(icon: "image", box: 28, glyph: 18, help: "附加图片", action: openPicker)
            sendButton
        }
        .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 11)
    }

    @ViewBuilder private var contextBar: some View {
        if let u = agent?.lastUsage, let used = u.contextWindowUsedTokens, let max = u.contextWindowMaxTokens, max > 0 {
            let ratio = min(1.0, Double(used) / Double(max))
            HStack(spacing: 8) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.dividerStrong)
                        Capsule().fill(accent.accent).frame(width: geo.size.width * ratio)
                    }
                }
                .frame(width: 64, height: 4)
                Text("\(Int(ratio * 100))%\(u.totalCostUsd.map { $0 > 0 ? " · " + formatCost($0) : "" } ?? "")")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.text3)
            }
        }
    }

    @ViewBuilder private var sendButton: some View {
        if vm.isAgentWorking {
            HStack(spacing: 6) {
                circleSend(disabled: isSendDisabled, fill: accent.send, glyph: accent.accent, action: submit, help: "排队 (⌘↩)")
                Button { Task { await vm.sendInterrupting() } } label: {
                    ZStack { Circle().fill(DS.red).frame(width: 34, height: 34); DSIcon(name: "stop", size: 13).foregroundStyle(.white) }
                }.buttonStyle(.plain).help("中断 (⌘⇧↩)").keyboardShortcut(.return, modifiers: [.command, .shift])
            }
        } else {
            Button(action: submit) {
                ZStack {
                    Circle().fill(isSendDisabled ? DS.dividerStrong.opacity(0.5) : accent.accent).frame(width: 34, height: 34)
                    DSIcon(name: "arrow-up", size: 17, weight: .bold).foregroundStyle(isSendDisabled ? DS.text3 : .white)
                }
            }
            .buttonStyle(.plain).disabled(isSendDisabled).keyboardShortcut(.return, modifiers: [.command]).help("发送 (⌘↩)")
        }
    }

    private func circleSend(disabled: Bool, fill: Color, glyph: Color, action: @escaping () -> Void, help: String) -> some View {
        Button(action: action) {
            ZStack { Circle().fill(disabled ? DS.dividerStrong.opacity(0.5) : fill).frame(width: 34, height: 34)
                DSIcon(name: "arrow-up", size: 16, weight: .bold).foregroundStyle(disabled ? DS.text3 : glyph) }
        }.buttonStyle(.plain).disabled(disabled).keyboardShortcut(.return, modifiers: [.command]).help(help)
    }

    // MARK: attachments

    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(vm.pendingImages) { att in
                    ZStack(alignment: .topTrailing) {
                        if let ns = NSImage(contentsOf: att.fileURL) {
                            Image(nsImage: ns).resizable().interpolation(.high).scaledToFill().frame(width: 66, height: 66)
                                .clipShape(RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.divider, lineWidth: 1))
                        }
                        removeBadge { vm.removeImage(id: att.id) }
                    }
                }
                ForEach(vm.pendingTextFiles) { f in
                    ZStack(alignment: .topTrailing) {
                        HStack(spacing: 9) {
                            RoundedRectangle(cornerRadius: 7).fill(accent.tint).frame(width: 30, height: 30)
                                .overlay(DSIcon(name: "file-text", size: 16).foregroundStyle(accent.accent))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.text).lineLimit(1)
                                Text("\(f.content.count) chars").font(.system(size: 11)).foregroundStyle(DS.text3)
                            }
                        }
                        .padding(.horizontal, 11).padding(.vertical, 8).frame(maxWidth: 230)
                        .background(Color(hex: 0xF7F7F5), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.divider, lineWidth: 1))
                        removeBadge { vm.removeTextFile(id: f.id) }
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }

    private func removeBadge(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            DSIcon(name: "x", size: 11).foregroundStyle(.white).frame(width: 18, height: 18).background(Color.black.opacity(0.62), in: Circle())
        }.buttonStyle(.plain).padding(3)
    }

    // MARK: queue

    private var queueStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                DSIcon(name: vm.turnLooksStuck ? "alert" : "clock", size: 13).foregroundStyle(vm.turnLooksStuck ? DS.orange : DS.text2)
                Text(vm.turnLooksStuck ? "上一回合似乎卡住了" : "Queued · 点击编辑").font(.system(size: 12.5)).foregroundStyle(DS.text2)
                Spacer()
                Button { Task { await vm.forceSendAnyway() } } label: {
                    Text("Send anyway").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 4).background((vm.turnLooksStuck ? DS.orange : accent.accent), in: Capsule())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .overlay(alignment: .bottom) { Rectangle().fill(DS.divider).frame(height: 1) }
            ForEach(vm.queued) { q in
                HStack(spacing: 9) {
                    Text(q.preview).font(.system(size: 13)).foregroundStyle(DS.text2).lineLimit(1)
                    if !q.images.isEmpty { DSIcon(name: "image", size: 12).foregroundStyle(DS.text3) }
                    Spacer()
                    IconButton(icon: "edit", box: 22, glyph: 13) { vm.editQueued(id: q.id) }
                    IconButton(icon: "x", box: 22, glyph: 13) { vm.removeQueued(id: q.id) }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .frame(maxWidth: DS.transcriptMaxW)
        .background(Color(hex: 0xFAF9F7), in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(DS.divider, lineWidth: 1))
    }

    // MARK: actions

    private var isSendDisabled: Bool {
        vm.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && vm.pendingImages.isEmpty && vm.pendingTextFiles.isEmpty
    }

    private func submit() {
        if pending {
            let text = vm.composerText.trimmingCharacters(in: .whitespacesAndNewlines)
            let images = vm.pendingImages
            vm.composerText = ""; vm.pendingImages = []; vm.pendingTextFiles = []
            Task { await app.submitPendingAgent(text: text, images: images) }
        } else {
            Task { await vm.sendComposer() }
        }
    }

    private func openPicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .text, .sourceCode, .json, .xml, .commaSeparatedText, .shellScript]
        panel.begin { if $0 == .OK { handleFileDrop(panel.urls) } }
    }

    private func handleFileDrop(_ urls: [URL]) {
        dropError = nil
        for url in urls {
            if let img = PendingImageAttachment.fromFileURL(url) { vm.addImages([img]); continue }
            do { vm.addTextFile(try PendingTextFile.fromFileURL(url)) }
            catch { dropError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription }
        }
    }
    private func handleImageDrop(_ images: [NSImage]) {
        let atts = images.compactMap { PendingImageAttachment.from(image: $0) }
        if !atts.isEmpty { vm.addImages(atts) }
    }
    private func handleLargePaste(_ text: String) {
        let f = DateFormatter(); f.dateFormat = "HHmmss"
        vm.addTextFile(PendingTextFile(id: UUID(), name: "Pasted-\(f.string(from: Date())).txt", content: text, languageHint: nil))
    }
}

// MARK: - Pickers (design pill style)

private struct ModelPickerPill: View {
    let agent: AgentSnapshot?
    @Environment(AppViewModel.self) private var app

    var body: some View {
        if let agent, let snap = app.providers.first(where: { $0.provider == agent.provider }), let models = snap.models, !models.isEmpty {
            Menu {
                ForEach(models) { m in
                    Button { Task { await app.setAgentModel(agentId: agent.id, modelId: m.id) } } label: {
                        Text(m.label + (m.id == agent.model ? "  ✓" : ""))
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    ProviderGlyph(provider: agent.provider, size: 15).frame(width: 15, height: 15)
                    Text(snap.label ?? "Claude Code").font(.system(size: 13)).foregroundStyle(DS.text)
                    DSIcon(name: "chevron-down", size: 13).foregroundStyle(DS.text3)
                }
                .pillSurface()
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
}

private struct ModePickerPill: View {
    let agent: AgentSnapshot?
    @Environment(AppViewModel.self) private var app

    var body: some View {
        if let agent, let modes = agent.availableModes, !modes.isEmpty {
            Menu {
                ForEach(modes) { m in
                    Button { Task { await app.setAgentMode(agentId: agent.id, modeId: m.id) } } label: {
                        Text(m.label + (m.id == agent.currentModeId ? "  ✓" : ""))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    DSIcon(name: modeIcon, size: 13).foregroundStyle(riskColor)
                    Text(currentLabel(modes)).font(.system(size: 13)).foregroundStyle(riskColor)
                    DSIcon(name: "chevron-down", size: 13).foregroundStyle(DS.text3)
                }
                .pillSurface()
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private func currentLabel(_ modes: [AgentMode]) -> String { modes.first { $0.id == agent?.currentModeId }?.label ?? "Mode" }
    private var modeIcon: String {
        switch agent?.currentModeId {
        case "bypassPermissions", "full-access": return "lock-open"
        case "acceptEdits", "auto": return "shield-check"
        case "plan": return "shield"
        default: return "shield-check"
        }
    }
    private var riskColor: Color {
        switch agent?.currentModeId {
        case "bypassPermissions", "full-access": return DS.red
        case "acceptEdits", "auto": return DS.orange
        case "plan": return AccentPalette.terracotta.accent
        case "auto-review": return DS.greenSoftTX
        default: return DS.greenSoftTX
        }
    }
}

private struct ThinkingPickerPill: View {
    let agent: AgentSnapshot?
    @Environment(AppViewModel.self) private var app

    private var options: [SelectOption]? {
        guard let agent, let snap = app.providers.first(where: { $0.provider == agent.provider }),
              let model = snap.models?.first(where: { $0.id == agent.model }) else { return nil }
        return model.thinkingOptions
    }

    var body: some View {
        if let agent, let options, !options.isEmpty {
            Menu {
                ForEach(options) { o in
                    Button { Task { await app.setAgentThinking(agentId: agent.id, thinkingOptionId: o.id) } } label: {
                        Text(o.label + (o.id == agent.effectiveThinkingOptionId ? "  ✓" : ""))
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text("Thinking: \(currentLabel(options))").font(.system(size: 13)).foregroundStyle(DS.text)
                    DSIcon(name: "chevron-down", size: 13).foregroundStyle(DS.text3)
                }
                .pillSurface()
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }
    private func currentLabel(_ options: [SelectOption]) -> String {
        options.first { $0.id == agent?.effectiveThinkingOptionId }?.label ?? "off"
    }
}
