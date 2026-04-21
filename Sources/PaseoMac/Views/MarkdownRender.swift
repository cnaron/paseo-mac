import SwiftUI

/// Very small block-level markdown renderer tailored to Paseo chat output.
///
/// Inline syntax (`**bold**`, `*italic*`, `` `code` ``, `[link](url)`) is handled
/// by SwiftUI's built-in `AttributedString(markdown:)` — it covers the common
/// cases we see. Block-level, we detect:
///   - fenced code blocks (```lang ... ```)
///   - ATX headings (`#`, `##`, ..., up to `######`)
///   - GitHub-flavored pipe tables (`| a | b |` with a `|---|---|` separator)
///   - everything else is a paragraph
///
/// Deliberate non-goals for MVP: block quotes, nested lists, math. These
/// degrade to plain paragraphs — good enough, never crashes.
enum Markdown {

    enum Block: Hashable {
        case heading(level: Int, text: String)
        case code(language: String?, content: String)
        case table(headers: [String], rows: [[String]])
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

            // GFM pipe table: a pipe-line directly followed by a separator line.
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("|"),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let headers = parseTableRow(line)
                var rows: [[String]] = []
                i += 2    // skip header + separator
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(parseTableRow(lines[i]))
                    i += 1
                }
                out.append(.table(headers: headers, rows: rows))
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

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        // Every cell after splitting must only contain `-`, `:`, or whitespace.
        let cells = trimmed
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .split(separator: "|", omittingEmptySubsequences: false)
        guard !cells.isEmpty else { return false }
        let allowed: Set<Character> = ["-", ":", " "]
        for cell in cells {
            let stripped = cell.trimmingCharacters(in: .whitespaces)
            if stripped.isEmpty { return false }
            if !stripped.allSatisfy({ allowed.contains($0) }) { return false }
            if !stripped.contains("-") { return false }
        }
        return true
    }

    private static func parseTableRow(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        // Strip a single leading/trailing pipe if present, then split on |.
        var inner = trimmed
        if inner.hasPrefix("|") { inner.removeFirst() }
        if inner.hasSuffix("|") { inner.removeLast() }
        return inner
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
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
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let text):
                    Text(Markdown.renderInline(text))
                        .font(headingFont(level: level))
                        .bold()
                        .textSelection(.enabled)
                        .padding(.top, 4)
                case .code(let lang, let content):
                    CodeBlockView(language: lang, content: content)
                case .table(let headers, let rows):
                    TableBlockView(headers: headers, rows: rows)
                case .paragraph(let text):
                    Text(Markdown.renderInline(text))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(3)
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

private struct TableBlockView: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        let cols = max(headers.count, rows.map(\.count).max() ?? 0)
        VStack(spacing: 0) {
            headerRow(cols: cols)
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, row in
                Divider()
                bodyRow(row: row, cols: cols, isAlt: idx.isMultiple(of: 2) == false)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func headerRow(cols: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<cols, id: \.self) { c in
                cell(text: headers[safe: c] ?? "", isHeader: true)
                if c < cols - 1 {
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1)
                }
            }
        }
        .background(Color.secondary.opacity(0.08))
    }

    private func bodyRow(row: [String], cols: Int, isAlt: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<cols, id: \.self) { c in
                cell(text: row[safe: c] ?? "", isHeader: false)
                if c < cols - 1 {
                    Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1)
                }
            }
        }
        .background(isAlt ? Color.secondary.opacity(0.03) : Color.clear)
    }

    private func cell(text: String, isHeader: Bool) -> some View {
        Text(Markdown.renderInline(text))
            .font(isHeader ? .callout.bold() : .callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
