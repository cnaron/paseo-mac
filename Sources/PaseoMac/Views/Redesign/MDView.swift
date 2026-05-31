import SwiftUI
import AppKit

// MARK: - Design-styled markdown (prototype `.md`)
//
// Reuses the proven `Markdown.parse` + `Markdown.renderInline` (inline
// bold/italic/code, auto-links, green file-path links) and `SyntaxHighlighter`,
// re-skinned to the design tokens with a settings-driven body size.

struct MDView: View {
    let text: String
    var isStreaming: Bool = false
    var workspaceCwd: String? = nil
    var onOpenFile: (String) -> Void = { _ in }

    @Environment(SettingsStore.self) private var settings
    private var fs: CGFloat { CGFloat(settings.fontSize) }
    private var lead: CGFloat { fs * 0.30 } // ≈ line-height 1.62 minus default leading

    var body: some View {
        let display = isStreaming ? Markdown.cleanForStreaming(text) : text
        let blocks = Markdown.parse(display)
        VStack(alignment: .leading, spacing: 11) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            if let raw = WorkspaceFilePreviewRouting.parseRawLocation(from: url) {
                onOpenFile(raw)
                return .handled
            }
            return .systemAction(url)
        })
    }

    @ViewBuilder
    private func blockView(_ block: Markdown.Block) -> some View {
        switch block {
        case .heading(let level, let t):
            VStack(alignment: .leading, spacing: 8) {
                Text(Markdown.renderInline(t))
                    .font(.system(size: headingSize(level), weight: .semibold))
                    .foregroundStyle(DS.text)
                if level <= 2 { Rectangle().fill(DS.divider).frame(height: 1) }
            }
            .padding(.top, level <= 2 ? 9 : 5)

        case .paragraph(let t):
            Text(Markdown.renderInline(t))
                .font(.system(size: fs)).foregroundStyle(DS.text)
                .lineSpacing(lead).fixedSize(horizontal: false, vertical: true)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").font(.system(size: fs)).foregroundStyle(DS.text3)
                        Text(Markdown.renderInline(item)).font(.system(size: fs)).foregroundStyle(DS.text)
                            .lineSpacing(lead).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(start + i).").font(.system(size: fs)).foregroundStyle(DS.text3)
                            .frame(minWidth: 20, alignment: .trailing)
                        Text(Markdown.renderInline(item)).font(.system(size: fs)).foregroundStyle(DS.text)
                            .lineSpacing(lead).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .blockquote(let t):
            Text(Markdown.renderInline(Markdown.normalizeBlockquoteText(t)))
                .font(.system(size: fs)).foregroundStyle(DS.text2)
                .lineSpacing(lead).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6).padding(.leading, 14).padding(.trailing, 12)
                .background(Color.black.opacity(0.025))
                .overlay(alignment: .leading) {
                    Rectangle().fill(settings.accentPalette.ring).frame(width: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))

        case .horizontalRule:
            Rectangle().fill(DS.divider).frame(height: 1).padding(.vertical, 7)

        case .table(let headers, let rows):
            MDTable(headers: headers, rows: rows)

        case .code(let lang, let content):
            MDCodeBlock(language: lang, content: content)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: return fs * 1.32
        case 2: return fs * 1.16
        case 3: return fs * 1.04
        default: return fs
        }
    }
}

// MARK: - Code block (.codeblock)

private struct MDCodeBlock: View {
    let language: String?
    let content: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "").font(.system(size: 11.5)).foregroundStyle(DS.text3)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                } label: {
                    HStack(spacing: 5) {
                        DSIcon(name: copied ? "check-sm" : "copy", size: 13)
                        Text(copied ? "Copied" : "Copy").font(.system(size: 11.5))
                    }
                    .foregroundStyle(DS.text3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 11).padding(.vertical, 6)
            .background(Color(hex: 0xF6F6F4))
            Rectangle().fill(DS.divider).frame(height: 1)
            ScrollView(.horizontal, showsIndicators: false) {
                Text(SyntaxHighlighter.highlight(content, language: language))
                    .font(.system(size: 12.5, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color(hex: 0xFBFBFA))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(DS.divider, lineWidth: 1))
    }
}

// MARK: - Table (.md table)

private struct MDTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        VStack(spacing: 0) {
            tableRow(cells: headers, cols: cols, header: true, alt: false)
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                Rectangle().fill(DS.divider).frame(height: 1)
                tableRow(cells: r, cols: cols, header: false, alt: i % 2 == 1)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DS.divider, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func tableRow(cells: [String], cols: Int, header: Bool, alt: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<cols, id: \.self) { c in
                Text(Markdown.renderInline(c < cells.count ? cells[c] : ""))
                    .font(.system(size: 14, weight: header ? .semibold : .regular))
                    .foregroundStyle(DS.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 11).padding(.vertical, 7)
                if c < cols - 1 { Rectangle().fill(DS.divider).frame(width: 1) }
            }
        }
        .background(header ? Color(hex: 0xF6F6F4) : (alt ? Color(hex: 0xFAFAFA) : Color.clear))
    }
}
