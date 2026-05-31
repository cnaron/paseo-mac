import SwiftUI
import AppKit

enum Markdown {
    static let fileLinkColor = dynamicColor(
        light: NSColor(red: 0x23 / 255.0, green: 0x99 / 255.0, blue: 0x56 / 255.0, alpha: 1),
        dark: NSColor(red: 0x7c / 255.0, green: 0xcb / 255.0, blue: 0xa0 / 255.0, alpha: 1)
    )
    static let fileSelectionColor = dynamicColor(
        light: NSColor(red: 0xec / 255.0, green: 0xec / 255.0, blue: 0xf1 / 255.0, alpha: 1),
        dark: NSColor(red: 0x2f / 255.0, green: 0x35 / 255.0, blue: 0x34 / 255.0, alpha: 1)
    )
    static let inlineCodeForeground = Color.primary.opacity(0.9)
    static let inlineCodeBackground = Color.secondary.opacity(0.14)

    enum Block: Hashable {
        case heading(level: Int, text: String)
        case code(language: String?, content: String)
        case table(headers: [String], rows: [[String]])
        case paragraph(String)
        case bulletList([String])
        case orderedList(start: Int, items: [String])
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
                out.append(.blockquote(normalizeBlockquoteText(quoteLines.joined(separator: "\n"))))
                continue
            }

            // Bullet list: - / * / +. Keep lazy continuation lines inside the
            // item so "title + URL + description" renders as one list entry.
            if let item = parseBulletItem(trimmed) {
                flushParagraph()
                var items: [String] = [item]
                i += 1
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let next = parseBulletItem(l) {
                        items.append(next)
                        i += 1
                    } else if l.isEmpty, i + 1 < lines.count,
                              parseBulletItem(lines[i + 1].trimmingCharacters(in: .whitespaces)) != nil {
                        i += 1  // skip blank line between loose-list items
                    } else if appendListContinuation(lines, index: &i, items: &items, marker: parseBulletItem) {
                        continue
                    } else { break }
                }
                out.append(.bulletList(items))
                continue
            }

            // Ordered list: 1. / 1)
            if let item = parseOrderedItem(trimmed) {
                flushParagraph()
                let start = item.number
                var items: [String] = [item.text]
                i += 1
                while i < lines.count {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let next = parseOrderedItem(l) { items.append(next.text); i += 1 }
                    else if l.isEmpty, i + 1 < lines.count,
                            parseOrderedItem(lines[i + 1].trimmingCharacters(in: .whitespaces)) != nil {
                        i += 1
                    } else if appendListContinuation(lines, index: &i, items: &items, marker: { parseOrderedItem($0)?.text }) {
                        continue
                    } else { break }
                }
                out.append(.orderedList(start: start, items: items))
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

    static func normalizeBlockquoteText(_ text: String) -> String {
        var normalized: [String] = []
        var previousWasBlank = false

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !normalized.isEmpty && !previousWasBlank {
                    normalized.append("")
                }
                previousWasBlank = true
                continue
            }
            normalized.append(line)
            previousWasBlank = false
        }

        while normalized.last?.isEmpty == true {
            normalized.removeLast()
        }
        return normalized.joined(separator: "\n")
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

    private static func appendListContinuation(
        _ lines: [String],
        index i: inout Int,
        items: inout [String],
        marker: (String) -> String?
    ) -> Bool {
        guard !items.isEmpty, i < lines.count else { return false }
        let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty { return false }

        guard marker(trimmed) == nil,
              parseBulletItem(trimmed) == nil,
              parseOrderedItem(trimmed) == nil,
              !startsStandaloneBlock(lines, at: i) else {
            return false
        }

        items[items.count - 1] += "\n" + trimmed
        i += 1
        return true
    }

    private static func startsStandaloneBlock(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("```") { return true }
        if parseAtxHeading(line) != nil { return true }
        if isHorizontalRule(trimmed) { return true }
        if trimmed.hasPrefix("> ") || trimmed == ">" { return true }
        if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
            return true
        }
        return false
    }

    private static func parseOrderedItem(_ trimmed: String) -> (number: Int, text: String)? {
        var idx = trimmed.startIndex
        while idx < trimmed.endIndex && trimmed[idx].isNumber { idx = trimmed.index(after: idx) }
        guard idx > trimmed.startIndex, idx < trimmed.endIndex else { return nil }
        let sep = trimmed[idx]
        guard sep == "." || sep == ")" else { return nil }
        let after = trimmed.index(after: idx)
        guard after < trimmed.endIndex, trimmed[after] == " " else { return nil }
        let number = Int(trimmed[..<idx]) ?? 1
        return (number, String(trimmed[trimmed.index(after: after)...]))
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


    /// Closes a dangling fenced code block at the end so streaming partial
    /// text parses as a (still-growing) code block instead of being hidden.
    ///
    /// Previous behaviour stripped everything from the opening ``` to the
    /// end — visually the surrounding paragraphs would stream normally,
    /// then the entire code block popped into view at once when the closing
    /// fence finally arrived. For a long block (ASCII art, big diff) this
    /// looked like the message had stalled mid-stream. Synthesizing a
    /// closing fence lets the partial content render in real time; the
    /// fake fence is naturally replaced when the real one arrives in a
    /// later chunk.
    static func cleanForStreaming(_ text: String) -> String {
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
            }
        }
        guard inFence else { return text }
        let suffix = text.hasSuffix("\n") ? "```" : "\n```"
        return text + suffix
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
        // Style inline `code` spans: neutral foreground on subtle gray tint.
        for run in parsed.runs {
            guard let intent = run.inlinePresentationIntent,
                  intent.contains(.code) else { continue }
            var container = AttributeContainer()
            container.foregroundColor = inlineCodeForeground
            container.backgroundColor = inlineCodeBackground
            parsed[run.range].mergeAttributes(container)
        }
        // Auto-link plain URLs that markdown didn't already turn into links.
        // Runs NSDataDetector on the rendered plain text and stamps .link +
        // .underlineStyle onto any URL span not already carrying a link attribute.
        autoLinkURLs(in: &parsed)
        // Detect absolute file references in assistant output so users can
        // click directly into the workspace file preview pane.
        autoLinkFileLocations(in: &parsed)
        styleLinks(in: &parsed)
        return parsed
    }

    private static func autoLinkURLs(in str: inout AttributedString) {
        let plain = String(str.characters)
        guard !plain.isEmpty,
              let detector = try? NSDataDetector(
                types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let nsRange = NSRange(plain.startIndex..., in: plain)
        let matches = detector.matches(in: plain, range: nsRange)
        for match in matches {
            guard let url = match.url,
                  let strRange = Range(match.range, in: plain) else { continue }
            let startOff = plain.distance(from: plain.startIndex, to: strRange.lowerBound)
            let endOff   = plain.distance(from: plain.startIndex, to: strRange.upperBound)
            let charStart = str.characters.index(str.characters.startIndex, offsetBy: startOff)
            let charEnd   = str.characters.index(str.characters.startIndex, offsetBy: endOff)
            let attrRange = charStart..<charEnd
            if str[attrRange].link == nil {
                str[attrRange].link = url
                str[attrRange].underlineStyle = .single
            }
        }
    }

    /// Turns absolute file references like `/repo/README.md:42` into
    /// tappable custom-scheme links. We intentionally scope this to absolute
    /// paths to avoid over-linking normal prose.
    private static func autoLinkFileLocations(in str: inout AttributedString) {
        let plain = String(str.characters)
        guard !plain.isEmpty else { return }

        let pattern = #"(?<![\w~])/(?:[^\s`:<>()\[\]{}"']+/)*[^\s`:<>()\[\]{}"']+(?::\d+(?:-\d+)?)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsRange = NSRange(plain.startIndex..., in: plain)
        let matches = regex.matches(in: plain, range: nsRange)

        for match in matches {
            guard let strRange = Range(match.range, in: plain) else { continue }
            let raw = String(plain[strRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }

            let startOff = plain.distance(from: plain.startIndex, to: strRange.lowerBound)
            let endOff = plain.distance(from: plain.startIndex, to: strRange.upperBound)
            let charStart = str.characters.index(str.characters.startIndex, offsetBy: startOff)
            let charEnd = str.characters.index(str.characters.startIndex, offsetBy: endOff)
            let attrRange = charStart..<charEnd
            guard str[attrRange].link == nil else { continue }
            guard let url = WorkspaceFilePreviewRouting.makeLinkURL(rawLocation: raw) else { continue }
            str[attrRange].link = url
            str[attrRange].underlineStyle = .single
            str[attrRange].foregroundColor = fileLinkColor
        }
    }

    private static func styleLinks(in str: inout AttributedString) {
        for run in str.runs {
            guard let link = run.link, isFileLink(link) else { continue }
            str[run.range].foregroundColor = fileLinkColor
            str[run.range].underlineStyle = .single
        }
    }

    private static func isFileLink(_ url: URL) -> Bool {
        if url.scheme?.lowercased() == WorkspaceFilePreviewRouting.linkScheme {
            return true
        }
        if url.isFileURL {
            return true
        }
        if let scheme = url.scheme, !scheme.isEmpty {
            return false
        }
        let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        return raw.hasPrefix("/") || raw.hasPrefix("./") || raw.hasPrefix("../")
    }

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return isDark ? dark : light
        })
    }
}

// MARK: - Block renderer


struct MarkdownBodyView: View {
    let text: String
    var isStreaming: Bool = false
    var workspaceCwd: String? = nil
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var shownBlockCount: Int = 0

    var body: some View {
        let displayText = isStreaming ? Markdown.cleanForStreaming(text) : text
        let blocks = Markdown.parse(displayText)
        // Spacing values mirror the original Paseo web client
        // (packages/app/src/styles/markdown-styles.ts). Their `spacing` scale:
        // 1=4, 2=8, 3=12, 4=16, 6=24. SwiftUI VStack spacing doesn't merge
        // adjacent margins like CSS, so heading padding.top is set to
        // (original marginTop − VStack spacing) to land at the same total.
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, block in
                Group { switch block {
                case .heading(let level, let text):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(Markdown.renderInline(text))
                            .font(.system(size: settings.scaled(headingPoints(level: level)), weight: .semibold))
                            .textSelection(.enabled)
                        if level == 1 || level == 2 {
                            Divider()
                        }
                    }
                    .padding(.top, level <= 2 ? 12 : 4)

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
                    // Paseo web's list_item marginBottom is spacing[1]=4, but
                    // that reads too dense for CJK multi-line items on a Mac
                    // desktop; bumped to 10 by visual feedback.
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 4) {
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

                case .orderedList(let start, let items):
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                            HStack(alignment: .top, spacing: 4) {
                                Text("\(start + idx).")
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
                    QuoteBlockView(text: text)

                case .horizontalRule:
                    Divider().padding(.vertical, 12)
                } }
                .opacity(i < shownBlockCount ? 1 : 0)
                .offset(y: i < shownBlockCount ? 0 : 6)
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            let rawLocation = WorkspaceFilePreviewRouting.parseRawLocation(from: url)
                ?? inferFileLocationCandidate(from: url)
            guard let rawLocation else {
                return .systemAction(url)
            }
            if let cwd = workspaceCwd, !cwd.isEmpty {
                let route = WorkspaceFilePreviewRouting.forceRoute(cwd: cwd, rawLocation: rawLocation)
                openWindow(value: route)
            } else {
                FileLocationOpener.open(FileLocation.parse(rawLocation))
            }
            return .handled
        })
        .onAppear { shownBlockCount = blocks.count }
        .onChange(of: blocks.count) { _, newCount in
            guard newCount > shownBlockCount else { return }
            // During streaming, sync immediately — the spring animation
            // delays each new block by 0.32s, which is fine for a final
            // reveal but stutters badly when chunks arrive faster than
            // the animation completes. A 1-char paragraph (e.g. just
            // arrived "现") would stay near-invisible for 300ms while
            // the next chunk has already updated its text, producing
            // the "disconnected single character" the user reported.
            if isStreaming {
                shownBlockCount = newCount
            } else {
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

    private func inferFileLocationCandidate(from url: URL) -> String? {
        if url.isFileURL {
            return url.path
        }
        if let scheme = url.scheme, !scheme.isEmpty {
            return nil
        }
        let raw = url.absoluteString.removingPercentEncoding ?? url.absoluteString
        guard !raw.isEmpty,
              !raw.hasPrefix("#"),
              !raw.contains("://") else { return nil }
        return raw
    }
}

private struct QuoteBlockView: View {
    let text: String
    @Environment(SettingsStore.self) private var settings

    private var normalizedText: String {
        Markdown.normalizeBlockquoteText(text)
    }

    var body: some View {
        if !normalizedText.isEmpty {
            Text(Markdown.renderInline(normalizedText))
                .font(.system(size: settings.scaled(13)))
                .foregroundStyle(.primary.opacity(0.82))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(CGFloat(settings.paragraphLineSpacing))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 9)
                .padding(.leading, 18)
                .padding(.trailing, 12)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.primary.opacity(0.82))
                        .frame(width: 4)
                }
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
            Text(SyntaxHighlighter.highlight(content, language: language))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Syntax highlighting

/// Minimal token-coloring highlighter. Not a real parser — covers strings,
/// comments, numbers, and a per-language keyword set. Built specifically
/// for chat code blocks where readability matters more than precision; a
/// real Lezer/TreeSitter port would be overkill here. Returns an
/// `AttributedString` built by appending colored substrings, which avoids
/// the index-mismatch pitfalls between NSString and AttributedString.
enum SyntaxHighlighter {
    enum TokenKind { case plain, keyword, string, number, comment }

    static func highlight(_ source: String, language: String?) -> AttributedString {
        let lang = (language ?? "").lowercased()
        let palette = Palette.dynamic
        let keywords = keywordSet(for: lang)
        let lineComment = lineCommentToken(for: lang)
        let blockDelims = blockCommentDelims(for: lang)
        let stringDelimiters: Set<Character> = ["\"", "'", "`"]

        let chars = Array(source)
        let n = chars.count
        var i = 0
        var tokens: [(TokenKind, String)] = []
        var buffer = ""

        func flushPlain() {
            if !buffer.isEmpty {
                tokens.append((.plain, buffer))
                buffer = ""
            }
        }

        while i < n {
            let ch = chars[i]

            // Block comment
            if let (open, close) = blockDelims, matches(chars, i, open) {
                flushPlain()
                let start = i
                i += open.count
                while i < n, !matches(chars, i, close) { i += 1 }
                if i < n { i += close.count }
                tokens.append((.comment, String(chars[start..<i])))
                continue
            }
            // Line comment
            if let token = lineComment, matches(chars, i, token) {
                flushPlain()
                let start = i
                while i < n, chars[i] != "\n" { i += 1 }
                tokens.append((.comment, String(chars[start..<i])))
                continue
            }
            // String literal
            if stringDelimiters.contains(ch) {
                flushPlain()
                let start = i
                let quote = ch
                i += 1
                while i < n {
                    let c = chars[i]
                    if c == "\\", i + 1 < n { i += 2; continue }
                    if c == quote { i += 1; break }
                    if c == "\n" { break }
                    i += 1
                }
                tokens.append((.string, String(chars[start..<i])))
                continue
            }
            // Number
            if ch.isASCII && ch.isNumber {
                flushPlain()
                let start = i
                i += 1
                while i < n {
                    let c = chars[i]
                    if c.isNumber || c == "." || c == "_" || c == "x" || c == "X" || (c.isLetter && c.isHexDigit) {
                        i += 1
                    } else { break }
                }
                tokens.append((.number, String(chars[start..<i])))
                continue
            }
            // Identifier / keyword
            if ch.isLetter || ch == "_" {
                let start = i
                i += 1
                while i < n {
                    let c = chars[i]
                    if c.isLetter || c.isNumber || c == "_" { i += 1 } else { break }
                }
                let word = String(chars[start..<i])
                if keywords.contains(word) {
                    flushPlain()
                    tokens.append((.keyword, word))
                } else {
                    buffer.append(word)
                }
                continue
            }
            buffer.append(ch)
            i += 1
        }
        flushPlain()

        var out = AttributedString()
        for (kind, piece) in tokens {
            var seg = AttributedString(piece)
            switch kind {
            case .plain: break
            case .keyword: seg.foregroundColor = palette.keyword
            case .string: seg.foregroundColor = palette.string
            case .number: seg.foregroundColor = palette.number
            case .comment: seg.foregroundColor = palette.comment
            }
            out += seg
        }
        return out
    }

    private static func matches(_ chars: [Character], _ start: Int, _ token: String) -> Bool {
        let t = Array(token)
        guard start + t.count <= chars.count else { return false }
        for k in 0..<t.count where chars[start + k] != t[k] { return false }
        return true
    }

    private struct Palette {
        let keyword: Color
        let string: Color
        let number: Color
        let comment: Color

        static var dynamic: Palette {
            // Design v1 code palette (prototype .tok-* tokens).
            Palette(
                keyword: DS.tokKey,
                string: DS.tokStr,
                number: DS.tokNum,
                comment: DS.tokCom
            )
        }
    }

    private static func keywordSet(for lang: String) -> Set<String> {
        switch lang {
        case "swift":
            return Set("class struct enum protocol extension func var let return if else for in while do try catch throw throws guard switch case break continue defer where as is import public private fileprivate internal open static final true false nil self Self async await actor".split(separator: " ").map(String.init))
        case "ts", "tsx", "typescript":
            return Set("class function const let var return if else for in of while do try catch throw new import export from default async await yield extends implements interface type enum public private protected readonly true false null undefined this super as".split(separator: " ").map(String.init))
        case "js", "jsx", "javascript":
            return Set("class function const let var return if else for in of while do try catch throw new import export from default async await yield extends true false null undefined this super".split(separator: " ").map(String.init))
        case "py", "python":
            return Set("def class return if elif else for in while try except raise import from as with pass break continue lambda global nonlocal yield True False None and or not is".split(separator: " ").map(String.init))
        case "go":
            return Set("func var const type struct interface package import return if else for switch case defer go chan map range break continue fallthrough goto select true false nil".split(separator: " ").map(String.init))
        case "rust", "rs":
            return Set("fn let mut const struct enum trait impl pub use mod return if else for in while loop match break continue as where async await self Self true false unsafe move ref dyn".split(separator: " ").map(String.init))
        case "java", "kotlin", "kt":
            return Set("class interface enum public private protected static final void return if else for while do try catch throw throws new this super extends implements import package true false null var val fun".split(separator: " ").map(String.init))
        case "c", "cpp", "c++", "objc", "objective-c":
            return Set("int char short long float double void if else for while do return struct enum union typedef sizeof const static extern volatile inline class public private protected virtual override new delete try catch throw true false nullptr NULL".split(separator: " ").map(String.init))
        case "sh", "bash", "zsh":
            return Set("if then elif else fi for in do done while case esac function return export local readonly true false".split(separator: " ").map(String.init))
        case "json":
            return Set(["true", "false", "null"])
        default:
            return []
        }
    }

    private static func lineCommentToken(for lang: String) -> String? {
        switch lang {
        case "py", "python", "sh", "bash", "zsh", "yaml", "yml", "toml", "ruby", "rb":
            return "#"
        case "lisp", "clojure", "scheme":
            return ";"
        case "sql":
            return "--"
        case "":
            return nil
        default:
            return "//"
        }
    }

    private static func blockCommentDelims(for lang: String) -> (String, String)? {
        switch lang {
        case "py", "python":
            return (#"""""#, #"""""#)
        case "html", "xml":
            return ("<!--", "-->")
        case "py", "yaml", "yml", "toml", "sh", "bash", "zsh", "":
            return nil
        default:
            return ("/*", "*/")
        }
    }
}
