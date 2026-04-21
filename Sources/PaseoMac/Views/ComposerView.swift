import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ComposerView: View {
    @Bindable var vm: ConversationViewModel
    @FocusState private var focused: Bool
    @State private var isDropTargeted: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !vm.pendingImages.isEmpty {
                thumbnailStrip
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
        }
        .padding(12)
        .onPasteCommand(of: supportedPasteTypes, perform: handlePaste)
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
    }

    // MARK: - Subviews

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(vm.pendingImages) { att in
                    AttachmentChip(
                        attachment: att,
                        onRemove: { vm.removeImage(id: att.id) }
                    )
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

    // MARK: - Actions

    private var isSendDisabled: Bool {
        vm.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && vm.pendingImages.isEmpty
    }

    private func submit() {
        Task { await vm.sendComposer() }
    }

    private var supportedPasteTypes: [UTType] {
        [.image, .png, .jpeg, .tiff, .gif, .bmp, .fileURL]
    }

    /// Called by SwiftUI when ⌘V is pressed while the composer has focus.
    /// We inspect NSPasteboard.general directly because the `providers`
    /// array gives item-provider wrappers that are painful for AppKit image types.
    private func handlePaste(_: [NSItemProvider]) {
        let images = PasteboardHelper.extractImages(from: NSPasteboard.general)
        if !images.isEmpty {
            vm.addImages(images)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
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
                    if let att = PendingImageAttachment.fromFileURL(url) {
                        Task { @MainActor in vm.addImages([att]) }
                    }
                }
            }
        }
        return consumed
    }

}

/// Free function (non-isolated) so it can be called from provider callbacks
/// that run off the main actor without triggering Swift-6 data-race errors.
private func resolveFileURLNonIsolated(from item: NSSecureCoding?) -> URL? {
    if let url = item as? URL { return url }
    if let data = item as? Data {
        return URL(dataRepresentation: data, relativeTo: nil)
    }
    return nil
}

private struct AttachmentChip: View {
    let attachment: PendingImageAttachment
    let onRemove: () -> Void

    @State private var thumbImage: NSImage? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let thumb = thumbImage {
                    Image(nsImage: thumb)
                        .resizable()
                        .scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.2))
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.white, .black.opacity(0.6))
            }
            .buttonStyle(.plain)
            .padding(2)
            .help("Remove attachment")
        }
        .task {
            thumbImage = attachment.thumbnail()
        }
    }
}
