import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Custom NSTextView wrapper that intercepts file/image drops and routes them
/// to the composer's attachment handler instead of inserting paths as text.
struct ComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: Double
    var font: NSFont = .systemFont(ofSize: NSFont.systemFontSize)
    var onFileDrop: ([URL]) -> Void = { _ in }
    var onImageDrop: ([NSImage]) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = DropInterceptingTextView()
        textView.delegate = context.coordinator
        textView.fileDrop = onFileDrop
        textView.imageDrop = onImageDrop
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = font
        textView.textColor = .labelColor
        textView.drawsBackground = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 4
        textView.autoresizingMask = [.width]
        textView.registerForDraggedTypes([
            .fileURL, .png, .tiff, .string
        ])

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        textView.placeholder = "Reply…"
        context.coordinator.textView = textView
        // Become first responder so ⌘V reaches paste(_:) immediately
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? DropInterceptingTextView else { return }
        if textView.string != text {
            let sel = textView.selectedRange()
            textView.string = text
            let safe = NSRange(
                location: min(sel.location, textView.string.count),
                length: 0
            )
            textView.setSelectedRange(safe)
        }
        textView.font = font
        textView.fileDrop = onFileDrop
        textView.imageDrop = onImageDrop
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: ComposerTextView
        weak var textView: NSTextView?

        init(_ parent: ComposerTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            tv.needsDisplay = true  // redraw placeholder
            if let lm = tv.layoutManager, let tc = tv.textContainer {
                lm.ensureLayout(for: tc)
                let fitted = lm.usedRect(for: tc).height + 8
                parent.height = Double(max(44, fitted))
            }
        }
    }
}

// MARK: - Custom NSTextView with drop interception

final class DropInterceptingTextView: NSTextView {
    var fileDrop: ([URL]) -> Void = { _ in }
    var imageDrop: ([NSImage]) -> Void = { _ in }
    var placeholder: String = "Reply…"

    // Draw placeholder when text + marked-text are both empty (IME-safe)
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, markedRange().length == 0 else { return }
        let x = textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 4)
        let y = textContainerOrigin.y
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.placeholderTextColor,
            .font: self.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        ]
        (placeholder as NSString).draw(
            in: NSRect(x: x, y: y, width: dirtyRect.width - x, height: dirtyRect.height),
            withAttributes: attrs
        )
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pb = sender.draggingPasteboard
        if pb.canReadObject(forClasses: [NSURL.self], options: fileOnlyOptions)
            || hasImageData(pb) {
            return .copy
        }
        return super.draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        // 1) File URLs — route to attachment handler
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: fileOnlyOptions) as? [URL],
           !urls.isEmpty {
            fileDrop(urls)
            return true
        }

        // 2) Image data (e.g. dragged from browser)
        if let images = pb.readObjects(forClasses: [NSImage.self]) as? [NSImage],
           !images.isEmpty {
            imageDrop(images)
            return true
        }

        // 3) Plain text — let NSTextView handle normally
        return super.performDragOperation(sender)
    }

    // MARK: - Paste interception

    /// Intercept ⌘V at the key-event level before SwiftUI or AppKit menus
    /// can route it elsewhere. Calls our own paste(_:) directly.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if cmd == .command && event.charactersIgnoringModifiers == "v" {
            paste(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general

        // 1) File URLs from Finder (⌘C on a file). Finder also puts an image
        //    thumbnail on the pasteboard, so check URL first.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: fileOnlyOptions) as? [URL],
           !urls.isEmpty {
            fileDrop(urls)
            return
        }

        // 2) Raw image data: screenshots (⌘⇧4), Copy Image from browser.
        //    Try multiple paths: NSImage(pasteboard:), then explicit TIFF/PNG reads.
        if let image = NSImage(pasteboard: pb) {
            imageDrop([image])
            return
        }
        if let data = pb.data(forType: .tiff) ?? pb.data(forType: .png),
           let image = NSImage(data: data) {
            imageDrop([image])
            return
        }

        // 3) Regular text — default NSTextView behavior
        super.paste(sender)
    }

    private var fileOnlyOptions: [NSPasteboard.ReadingOptionKey: Any] {
        [.urlReadingFileURLsOnly: true]
    }

    private func hasImageData(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }
}
