import SwiftUI

/// Very small block-level markdown renderer tailored to Paseo chat output.
///
/// Inline syntax (`**bold**`, `*italic*`, `` `code` ``, `[link](url)`) is handled
/// by SwiftUI's built-in `AttributedString(markdown:)` — it covers the common
/// cases we see. Block-level, we detect:
///   - fenced code blocks (```lang ... ```)
///   - ATX headings (`#`, `##`, ..., up to `######`)
///   - everything else is a paragraph
///
/// Deliberate non-goals for MVP: tables, block quotes, nested lists, math.
/// These degrade to plain paragraphs — good enough, never crashes.
enum Markdown {

    enum Block: Hashable {
        case heading(level: Int, text: String)
        case code(language: String?, content: String)
        case paragraph(String)
    }

    /// Splits `text` into an ordered list of blocks. Consecutive non-code,
    /// non-heading lines are joined into a single paragraph block so the inline
    /// renderer can apply markdown across line breaks.
    static func parse(_ text: String) -> [Block] {
        var out: [Block] = []
        var paragraphBuffer: [String] = []

        func flushParagraph() {
            guard !paragraphBuffer.isEmpty else { return }
            let joined = paragraphBuffer.joined(separator: "\n")
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty {
                out.append(.paragraph(joined))
            }
            paragraphBuffer.removeAll(keepingCapacity: true)
        }

        let lines = text.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]

            // Fenced code block opener.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flushParagraph()
                let opener = line.trimmingCharacters(in: .whitespaces)
                let lang: String? = {
                    let trimmed = String(opener.dropFirst(3))
                        .trimmingCharacters(in: .whitespaces)
                    return trimmed.isEmpty ? nil : trimmed
                }()
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        i += 1
                        break
                    }
                    codeLines.append(l)
                    i += 1
                }
                out.append(.code(language: lang, content: codeLines.joined(separator: "\n")))
                continue
            }

            // ATX heading.
            if let (level, content) = parseAtxHeading(line) {
                flushParagraph()
                out.append(.heading(level: level, text: content))
                i += 1
                continue
            }

            // Blank line separates paragraphs.
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flushParagraph()
                i += 1
                continue
            }

            paragraphBuffer.append(line)
            i += 1
        }
        flushParagraph()
        return out
    }

    private static func parseAtxHeading(_ line: String) -> (Int, String)? {
        var count = 0
        for ch in line {
            if ch == "#" { count += 1; if count > 6 { return nil } }
            else { break }
        }
        guard count >= 1, count <= 6 else { return nil }
        let afterHashes = line.dropFirst(count)
        guard afterHashes.first == " " else { return nil }
        let text = afterHashes.drop(while: { $0 == " " }).trimmingCharacters(in: .whitespaces)
        return (count, String(text))
    }

    /// Renders one paragraph (or heading body) as SwiftUI-friendly AttributedString.
    /// Falls back to plain text if `AttributedString(markdown:)` fails.
    static func renderInline(_ s: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let parsed = try? AttributedString(markdown: s, options: options) {
            return parsed
        }
        return AttributedString(s)
    }
}

/// Renders parsed markdown blocks as a vertical stack suitable for a chat bubble.
struct MarkdownBodyView: View {
    let text: String

    var body: some View {
        let blocks = Markdown.parse(text)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(Markdown.renderInline(text))
                        .font(headingFont(level: level))
                        .bold()
                        .textSelection(.enabled)
                case .code(let lang, let content):
                    CodeBlockView(language: lang, content: content)
                case .paragraph(let text):
                    Text(Markdown.renderInline(text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func headingFont(level: Int) -> Font {
        switch level {
        case 1: return .title2
        case 2: return .title3
        case 3: return .headline
        default: return .subheadline
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let lang = language, !lang.isEmpty {
                Text(lang)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(content)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
