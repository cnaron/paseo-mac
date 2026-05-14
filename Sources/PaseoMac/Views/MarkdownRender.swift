import SwiftUI

enum Markdown {

    enum Block: Hashable {
        case heading(level: Int, text: String)
        case code(language: String?, content: String)
        case table(headers: [String], rows: [[String]])
        case paragraph(String)
        case bulletList([String])
        case orderedList([String])
        case blockquote(String)
        case horizontalRule
    }

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
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block opener.
            if trimmed.hasPrefix("```") {
                flushParagraph()
                let lang: String? = {
                    let t = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                    return t.isEmpty ? nil : t
                }()
                var codeLines: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { i += 1; break }
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

            // Horizontal rule: --- *** ___ (3+ same chars, optional spaces between).
            if isHorizontalRule(trimmed) {
                flushParagraph()
                out.append(.horizontalRule)
                i += 1
                continue
            }

            // GFM pipe table.
            if trimmed.hasPrefix("|"),
               i + 1 < lines.count,
               isTableSeparator(lines[i + 1]) {
                flushParagraph()
                let headers = parseTableRow(line)
                var rows: [[String]] = []
                i += 2
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(parseTableRow(lines[i]))
                    i += 1
                }
                out.append(.table(headers: headers, rows: rows))
                continue
            }

            // Blockquote.
            if trimmed.hasPrefix("> ") || trimmed == ">" {
                flushParagraph()
                var quoteLines: [String] = []
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("> ") { quoteLines.append(String(l.dropFirst(2))); i += 1 }
                    else if l == ">" { quoteLines.append(""); i += 1 }
                    else { break }
                }
                out.append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            // Bullet list: - / * / +
            if let item = parseBulletItem(trimmed) {
                flushParagraph()
                var items: [String] = [item]
                i += 1
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let next = parseBulletItem(l) { items.append(next); i += 1 }
                    else if l.isEmpty, i + 1 < lines.count,
                            parseBulletItem(lines[i + 1].trimmingCharacters(in: .whitespaces)) != nil {
                        i += 1  // skip blank line inside loose list
                    } else { break }
                }
                out.append(.bulletList(items))
                continue
            }

            // Ordered list: 1. / 1)
            if let item = parseOrderedItem(trimmed) {
                flushParagraph()
                var items: [String] = [item]
                i += 1
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let next = parseOrderedItem(l) { items.append(next); i += 1 }
                    else if l.isEmpty, i + 1 < lines.count,
                            parseOrderedItem(lines[i + 1].trimmingCharacters(in: .whitespaces)) != nil {
                        i += 1
                    } else { break }
                }
                out.append(.orderedList(items))
                continue
            }

            // Blank line separates paragraphs.
            if trimmed.isEmpty {
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

    // MARK: - Line classifiers

    private static func isHorizontalRule(_ line: String) -> Bool {
        let stripped = line.filter { !$0.isWhitespace }
        guard stripped.count >= 3 else { return false }
        let unique = Set(stripped)
        return unique.count == 1 && (unique.contains("-") || unique.contains("*") || unique.contains("_"))
    }

    private static func parseBulletItem(_ trimmed: String) -> String? {
        for prefix in ["- ", "* ", "+ "] {
            if trimmed.hasPrefix(prefix) { return String(trimmed.dropFirst(2)) }
        }
        return nil
    }

    private static func parseOrderedItem(_ trimmed: String) -> String? {
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex && trimmed[idx].isNumber { idx = trimmed.index(after: idx) }
        guard idx > trimmed.startIndex, idx < trimmed.endIndex else { return nil }
        let sep = trimmed[idx]
        guard sep == "." || sep == ")" else { return nil }
        let after = trimmed.index(after: idx)
        guard after < trimmed.endIndex, trimmed[after] == " " else { return nil }
        return String(trimmed[trimmed.index(after: after)...])
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
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


    /// Strips an unclosed fenced code block at the end so streaming partial text parses cleanly.
    static func cleanForStreaming(_ text: String) -> String {
        var fenceCount = 0
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                inFence = !inFence
                fenceCount += inFence ? 1 : 0
            }
        }
        if inFence {
            if let r = text.range(of: "\n```", options: .backwards) {
                return String(text[..<r.lowerBound])
            }
            if let r = text.range(of: "```", options: .backwards) {
                return String(text[..<r.lowerBound])
            }
        }
        return text
    }

    /// Renders inline markdown. Converts GFM ~~strikethrough~~ to Apple ~strikethrough~
    /// before passing to SwiftUI's AttributedString parser.
    static func renderInline(_ s: String) -> AttributedString {
        let processed = s.replacingOccurrences(
            of: #"~~([^~\n]+)~~"#, with: "~$1~", options: .regularExpression
        )
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        guard var parsed = try? AttributedString(markdown: processed, options: options) else {
            return AttributedString(s)
        }
        // Style inline `code` spans the way claude.ai does: warm orange foreground
        // on a subtle gray tint. AttributedString's backgroundColor renders as a
        // flat rectangle (no rounded corners) — the closest native approximation.
        for run in parsed.runs {
            guard let intent = run.inlinePresentationIntent,
                  intent.contains(.code) else { continue }
            var container = AttributeContainer()
            container.foregroundColor = Color.blue
            container.backgroundColor = Color.secondary.opacity(0.15)
            parsed[run.range].mergeAttributes(container)
        }
        return parsed
    }
}

// MARK: - Block renderer


struct MarkdownBodyView: View {
    let text: String
    var isStreaming: Bool = false
    @Environment(SettingsStore.self) private var settings
    @State private var shownBlockCount: Int = 0

    var body: some View {
        let displayText = isStreaming ? Markdown.cleanForStreaming(text) : text
        let blocks = Markdown.parse(displayText)
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                Group { switch block {
                case .heading(let level, let text):
                    Text(Markdown.renderInline(text))
                        .font(.system(size: settings.scaled(headingPoints(level: level)), weight: .semibold))
                        .textSelection(.enabled)
                        .padding(.top, 4)

                case .code(let lang, let content):
                    CodeBlockView(language: lang, content: content)

                case .table(let headers, let rows):
                    TableBlockView(headers: headers, rows: rows)

                case .paragraph(let text):
                    Text(Markdown.renderInline(text))
                        .font(.system(size: settings.scaled(13)))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(CGFloat(settings.paragraphLineSpacing))

                case .bulletList(let items):
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                    .font(.system(size: settings.scaled(13)))
                                    .foregroundStyle(.secondary)
                                Text(Markdown.renderInline(item))
                                    .font(.system(size: settings.scaled(13)))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineSpacing(CGFloat(settings.paragraphLineSpacing))
                            }
                        }
                    }

                case .orderedList(let items):
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("\(idx + 1).")
                                    .font(.system(size: settings.scaled(13)))
                                    .foregroundStyle(.secondary)
                                    .frame(minWidth: 20, alignment: .trailing)
                                Text(Markdown.renderInline(item))
                                    .font(.system(size: settings.scaled(13)))
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .lineSpacing(CGFloat(settings.paragraphLineSpacing))
                            }
                        }
                    }

                case .blockquote(let text):
                    HStack(alignment: .top, spacing: 10) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.35))
                            .frame(width: 3)
                            .clipShape(Capsule())
                        Text(Markdown.renderInline(text))
                            .font(.system(size: settings.scaled(13)))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineSpacing(CGFloat(settings.paragraphLineSpacing))
                    }
                    .padding(.leading, 2)

                case .horizontalRule:
                    Divider().padding(.vertical, 2)
                } }
                .opacity(i < shownBlockCount ? 1 : 0)
                .offset(y: i < shownBlockCount ? 0 : 6)
            }
        }
        .onAppear { shownBlockCount = blocks.count }
        .onChange(of: blocks.count) { _, newCount in
            if newCount > shownBlockCount {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) { shownBlockCount = newCount }
            }
        }
    }

    private func headingPoints(level: Int) -> CGFloat {
        switch level {
        case 1: return 22
        case 2: return 19
        case 3: return 16
        default: return 14
        }
    }
}

// MARK: - Table

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
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func headerRow(cols: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<cols, id: \.self) { c in
                cell(text: headers[safe: c] ?? "", isHeader: true)
                if c < cols - 1 { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1) }
            }
        }
        .background(Color.secondary.opacity(0.08))
    }

    private func bodyRow(row: [String], cols: Int, isAlt: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<cols, id: \.self) { c in
                cell(text: row[safe: c] ?? "", isHeader: false)
                if c < cols - 1 { Rectangle().fill(Color.secondary.opacity(0.3)).frame(width: 1) }
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

// MARK: - Code block

private struct CodeBlockView: View {
    let language: String?
    let content: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let lang = language, !lang.isEmpty {
                    Text(lang)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy code")
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
