import SwiftUI
import AppKit

/// Single-file workspace preview pane.
///
/// Mirrors the upstream behavior:
/// - markdown renders only when no line selection is requested
/// - otherwise render line-numbered text with optional highlighted range
/// - file links can target specific lines (lineStart/lineEnd)
struct WorkspaceFilePreviewWindow: View {
    let route: WorkspaceFilePreviewRoute
    var onClose: (() -> Void)? = nil

    @Environment(AppViewModel.self) private var app

    @State private var cwd: String = ""
    @State private var selectedPath: String? = nil
    @State private var selectedLineStart: Int? = nil
    @State private var selectedLineEnd: Int? = nil

    @State private var selectedFile: FileExplorerFile? = nil
    @State private var selectedImageData: Data? = nil
    @State private var isLoadingFile = false
    @State private var fileError: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            content
        }
        .task(id: route.nonce) {
            await bootstrap(from: route)
        }
    }

    private var headerBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text")
                .foregroundStyle(.secondary)

            Text(headerTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

            if let s = selectedLineStart {
                Text(selectedLineEnd.map { "line \(s)-\($0)" } ?? "line \(s)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }

            Spacer()

            if let file = selectedFile {
                Text(byteCount(file.size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                if let path = selectedPath {
                    Task { await loadFile(path: path) }
                }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .disabled(selectedPath == nil)
            .help("Refresh file")

            Button {
                openCurrentInDefaultApp()
            } label: {
                Image(systemName: "arrow.up.right.square")
            }
            .buttonStyle(.plain)
            .disabled(selectedPath == nil)
            .help("Open in default app")

            if let onClose {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close file preview")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        if let fileError {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "exclamationmark.triangle")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text(fileError)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if let path = selectedPath {
                    Button("Retry") {
                        Task { await loadFile(path: path) }
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else if isLoadingFile {
            VStack(spacing: 8) {
                Spacer()
                ProgressView()
                Text("Loading file…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else if let file = selectedFile {
            fileBody(file)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        } else {
            ContentUnavailableView(
                "No file selected",
                systemImage: "doc.text",
                description: Text("Click a file link from the conversation to preview it here.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func fileBody(_ file: FileExplorerFile) -> some View {
        if file.kind == "image", let data = selectedImageData, let nsImage = NSImage(data: data) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            }
        } else if file.kind == "text", let content = file.content {
            if isMarkdownFile(file.path), selectedLineStart == nil {
                ScrollView {
                    MarkdownBodyView(text: content, workspaceCwd: cwd)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
            } else {
                WorkspaceCodePreview(
                    content: content,
                    filePath: file.path,
                    revisionToken: "\(file.modifiedAt)|\(file.size)",
                    lineStart: selectedLineStart,
                    lineEnd: selectedLineEnd
                )
            }
        } else {
            ContentUnavailableView(
                "Binary file",
                systemImage: "doc.fill",
                description: Text("This file can't be rendered as text.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var headerTitle: String {
        if let selectedPath, !selectedPath.isEmpty {
            return selectedPath
        }
        if !cwd.isEmpty {
            return cwd
        }
        return "File Preview"
    }

    private func bootstrap(from route: WorkspaceFilePreviewRoute) async {
        cwd = route.cwd
        selectedPath = route.path
        selectedLineStart = route.lineStart
        selectedLineEnd = route.lineEnd
        selectedFile = nil
        selectedImageData = nil
        fileError = nil

        guard let path = route.path, !path.isEmpty, path != "." else {
            isLoadingFile = false
            return
        }
        await loadFile(path: path)
    }

    private func loadFile(path: String) async {
        guard !cwd.isEmpty else { return }
        isLoadingFile = true
        fileError = nil
        defer { isLoadingFile = false }

        do {
            let readPath = WorkspaceFilePreviewRouting.normalizePathForWorkspace(path, cwd: cwd) ?? path
            let file = try await app.readWorkspaceFile(cwd: cwd, path: readPath)
            selectedFile = file
            if file.kind == "image", file.encoding == "base64", let content = file.content {
                selectedImageData = Data(base64Encoded: content)
            } else {
                selectedImageData = nil
            }
        } catch {
            selectedFile = nil
            selectedImageData = nil
            fileError = error.localizedDescription
        }
    }

    private func openCurrentInDefaultApp() {
        guard let selectedPath else { return }
        let path = absolutePath(for: selectedPath)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func absolutePath(for relativePath: String) -> String {
        if relativePath == "." { return cwd }
        return URL(fileURLWithPath: cwd)
            .appendingPathComponent(relativePath)
            .standardizedFileURL
            .path
    }

    private func byteCount(_ size: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    private func isMarkdownFile(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".md") || lower.hasSuffix(".markdown")
    }
}

private struct WorkspaceCodePreview: NSViewRepresentable {
    let content: String
    let filePath: String
    let revisionToken: String
    let lineStart: Int?
    let lineEnd: Int?

    final class Coordinator {
        var lastRenderKey: String = ""
        var lastScrolledLine: Int? = nil
        var lineStartOffsets: [Int] = []
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false

        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true

        if let container = textView.textContainer {
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        let key = renderKey
        let targetLine = clampLineSelection(
            lineStart: lineStart,
            lineEnd: lineEnd,
            lineCount: lineCount
        )?.lowerBound

        if context.coordinator.lastRenderKey != key {
            let rendered = renderDocument()
            textView.textStorage?.setAttributedString(rendered.text)
            context.coordinator.lineStartOffsets = rendered.lineStartOffsets
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            context.coordinator.lastRenderKey = key
            context.coordinator.lastScrolledLine = nil

            if let targetLine,
               targetLine > 0,
               targetLine <= context.coordinator.lineStartOffsets.count {
                let offset = context.coordinator.lineStartOffsets[targetLine - 1]
                DispatchQueue.main.async {
                    textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
                }
                context.coordinator.lastScrolledLine = targetLine
            }
            return
        }

        if let targetLine, context.coordinator.lastScrolledLine != targetLine {
            let offsets = context.coordinator.lineStartOffsets
            if targetLine > 0, targetLine <= offsets.count {
                let offset = offsets[targetLine - 1]
                DispatchQueue.main.async {
                    textView.scrollRangeToVisible(NSRange(location: offset, length: 0))
                }
                context.coordinator.lastScrolledLine = targetLine
            }
        }
    }

    private var renderKey: String {
        "\(filePath)|\(revisionToken)|\(lineStart ?? 0)|\(lineEnd ?? 0)"
    }

    private var lineCount: Int {
        content.split(separator: "\n", omittingEmptySubsequences: false).count.clamped(min: 1)
    }

    private func renderDocument() -> (text: NSAttributedString, lineStartOffsets: [Int]) {
        let rawLines = content
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let lines = rawLines.isEmpty ? [""] : rawLines

        let digits = max(2, String(lines.count).count)
        let lineSelection = clampLineSelection(
            lineStart: lineStart,
            lineEnd: lineEnd,
            lineCount: lines.count
        )

        let codeFont = NSFont.monospacedSystemFont(
            ofSize: NSFont.systemFontSize(for: .small),
            weight: .regular
        )
        let gutterColor = NSColor.secondaryLabelColor
        let textColor = NSColor.labelColor
        let selectedBackground = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark
                ? NSColor(red: 0x2f / 255.0, green: 0x35 / 255.0, blue: 0x34 / 255.0, alpha: 1)
                : NSColor(red: 0xec / 255.0, green: 0xec / 255.0, blue: 0xf1 / 255.0, alpha: 1)
        }

        let out = NSMutableAttributedString()
        var lineStartOffsets: [Int] = []
        var cursor = 0

        for (index, line) in lines.enumerated() {
            let lineNo = index + 1
            let gutter = String(format: "%\(digits)d  ", lineNo)
            let fullLine = gutter + line + (index < lines.count - 1 ? "\n" : "")

            lineStartOffsets.append(cursor)

            let segment = NSMutableAttributedString(
                string: fullLine,
                attributes: [
                    .font: codeFont,
                    .foregroundColor: textColor,
                ]
            )

            segment.addAttributes(
                [.foregroundColor: gutterColor],
                range: NSRange(location: 0, length: gutter.utf16.count)
            )

            if let lineSelection, lineSelection.contains(lineNo) {
                segment.addAttributes(
                    [.backgroundColor: selectedBackground],
                    range: NSRange(location: 0, length: fullLine.utf16.count)
                )
            }

            out.append(segment)
            cursor += fullLine.utf16.count
        }

        return (out, lineStartOffsets)
    }

    private func clampLineSelection(
        lineStart: Int?,
        lineEnd: Int?,
        lineCount: Int
    ) -> ClosedRange<Int>? {
        guard let lineStart, lineStart > 0, lineCount > 0 else { return nil }
        let start = min(lineStart, lineCount)
        let rawEnd = (lineEnd != nil && lineEnd! >= start) ? lineEnd! : start
        let end = min(rawEnd, lineCount)
        return start...max(start, end)
    }
}

private extension Int {
    func clamped(min minValue: Int) -> Int {
        Swift.max(self, minValue)
    }
}
