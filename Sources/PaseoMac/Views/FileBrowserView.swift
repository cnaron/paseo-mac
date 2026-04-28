import SwiftUI

// MARK: - Entry point

struct FileBrowserView: View {
    let rootPath: String
    @Environment(SettingsStore.self) private var settings
    @State private var selectedFile: String? = nil
    @State private var expandedDirs: Set<String> = []

    var body: some View {
        if let file = selectedFile {
            FileDetailView(
                path: file,
                rootPath: rootPath,
                settings: settings,
                onBack: { selectedFile = nil }
            )
        } else {
            fileTreeView
        }
    }

    private var fileTreeView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                Text(URL(fileURLWithPath: rootPath).lastPathComponent)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    DirectoryNode(
                        path: rootPath,
                        depth: 0,
                        expandedDirs: $expandedDirs,
                        selectedPath: Binding(
                            get: { selectedFile },
                            set: { selectedFile = $0 }
                        ),
                        onOpen: { selectedFile = $0 }
                    )
                }
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - File detail (content viewer with mode picker)

private struct FileDetailView: View {
    let path: String
    let rootPath: String
    let settings: SettingsStore
    let onBack: () -> Void

    enum ViewMode { case preview, source, diff }
    @State private var viewMode: ViewMode = .preview
    @State private var content: String = ""
    @State private var loadError: String? = nil

    private var filename: String { URL(fileURLWithPath: path).lastPathComponent }
    private var isMarkdown: Bool { (path as NSString).pathExtension.lowercased() == "md" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                contentArea
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task(id: path) {
            loadFile()
            viewMode = isMarkdown ? .preview : .source
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Text(filename)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            HStack(spacing: 2) {
                modeButton(.preview, icon: "doc.richtext",              tip: "Preview")
                modeButton(.source,  icon: "doc.text",                  tip: "Source")
                modeButton(.diff,    icon: "arrow.left.arrow.right",    tip: "Git diff")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
    }

    @ViewBuilder
    private var contentArea: some View {
        switch viewMode {
        case .preview:
            if let err = loadError {
                Text(err).foregroundStyle(.red).font(.caption)
            } else if isMarkdown {
                MarkdownBodyView(text: content)
                    .environment(settings)
            } else {
                Text(content)
                    .font(.system(size: settings.scaled(12), design: .monospaced))
                    .textSelection(.enabled)
            }
        case .source:
            if let err = loadError {
                Text(err).foregroundStyle(.red).font(.caption)
            } else {
                Text(content)
                    .font(.system(size: settings.scaled(12), design: .monospaced))
                    .textSelection(.enabled)
            }
        case .diff:
            GitDiffView(path: path, rootPath: rootPath)
        }
    }

    @ViewBuilder
    private func modeButton(_ mode: ViewMode, icon: String, tip: String) -> some View {
        let active = viewMode == mode
        Button { viewMode = mode } label: {
            Image(systemName: icon)
                .font(.system(size: 11))
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    active ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .foregroundStyle(active ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private func loadFile() {
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
            loadError = nil
        } catch {
            loadError = "Cannot read: \(error.localizedDescription)"
        }
    }
}

// MARK: - Git diff view

private struct GitDiffView: View {
    let path: String
    let rootPath: String

    enum DiffState {
        case loading
        case noGit
        case noChanges
        case changes([DiffLine])
        case error(String)
    }

    @State private var state: DiffState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                VStack {
                    Spacer(minLength: 40)
                    ProgressView("Running git diff…")
                    Spacer(minLength: 40)
                }
                .frame(maxWidth: .infinity)
            case .noGit:
                placeholder(icon: "questionmark.folder", msg: "Not a git repository")
            case .noChanges:
                placeholder(icon: "checkmark.circle", msg: "No local changes")
            case .changes(let lines):
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        DiffLineRow(line: line)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
            case .error(let msg):
                Text(msg).foregroundStyle(.red).font(.caption)
            }
        }
        .task(id: path) { await load() }
    }

    @ViewBuilder
    private func placeholder(icon: String, msg: String) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 40)
            Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.secondary)
            Text(msg).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity)
    }

    private func load() async {
        state = .loading
        let result = await Task.detached(priority: .userInitiated) {
            computeDiff(filePath: path, repoPath: rootPath)
        }.value
        state = result
    }
}

// MARK: - Diff model

private struct DiffLine {
    enum Kind { case fileHeader, hunk, added, removed, context }
    let kind: Kind
    let text: String
    let oldNum: Int?
    let newNum: Int?
}

private struct DiffLineRow: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            numCell(line.oldNum)
            numCell(line.newNum)
            Text(marker)
                .frame(width: 14)
                .foregroundStyle(markerColor)
            Text(line.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 8)
        }
        .background(rowBackground)
        .padding(.vertical, 0.5)
    }

    @ViewBuilder
    private func numCell(_ n: Int?) -> some View {
        Text(n.map { "\($0)" } ?? "")
            .foregroundStyle(.quaternary)
            .frame(width: 32, alignment: .trailing)
            .padding(.horizontal, 3)
    }

    private var rowBackground: Color {
        switch line.kind {
        case .added:        return .green.opacity(0.12)
        case .removed:      return .red.opacity(0.12)
        case .hunk:         return .accentColor.opacity(0.07)
        case .fileHeader:   return .secondary.opacity(0.06)
        case .context:      return .clear
        }
    }
    private var marker: String {
        switch line.kind { case .added: "+"; case .removed: "-"; default: " " }
    }
    private var markerColor: Color {
        switch line.kind { case .added: .green; case .removed: .red; default: .secondary }
    }
}

// MARK: - Git helpers (run on detached Task, no actor isolation needed)

private func computeDiff(filePath: String, repoPath: String) -> GitDiffView.DiffState {
    guard let gitRoot = gitRevParseRoot(from: repoPath) else { return .noGit }

    let rel = filePath.hasPrefix(gitRoot + "/")
        ? String(filePath.dropFirst(gitRoot.count + 1))
        : filePath

    // Staged + unstaged vs HEAD
    if let raw = runGit(["-C", gitRoot, "diff", "HEAD", "--", rel]), !raw.isEmpty {
        return .changes(parseDiff(raw))
    }
    // Staged-only (new file git-added but not committed yet)
    if let raw = runGit(["-C", gitRoot, "diff", "--cached", "--", rel]), !raw.isEmpty {
        return .changes(parseDiff(raw))
    }
    // Untracked file — show all lines as additions
    if let status = runGit(["-C", gitRoot, "status", "--porcelain", "--", rel]),
       status.hasPrefix("?") {
        let lines = (try? String(contentsOfFile: filePath, encoding: .utf8))?
            .components(separatedBy: "\n") ?? []
        return .changes(lines.enumerated().map {
            DiffLine(kind: .added, text: $0.element, oldNum: nil, newNum: $0.offset + 1)
        })
    }
    return .noChanges
}

private func gitRevParseRoot(from path: String) -> String? {
    guard let out = runGit(["-C", path, "rev-parse", "--show-toplevel"]) else { return nil }
    let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? nil : t
}

private func runGit(_ args: [String]) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["git"] + args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
}

private func parseDiff(_ raw: String) -> [DiffLine] {
    var result: [DiffLine] = []
    var oldLine = 0, newLine = 0

    for line in raw.components(separatedBy: "\n") {
        if line.hasPrefix("diff ") || line.hasPrefix("index ") ||
           line.hasPrefix("--- ")  || line.hasPrefix("+++ ") {
            result.append(DiffLine(kind: .fileHeader, text: line, oldNum: nil, newNum: nil))
        } else if line.hasPrefix("@@") {
            if let (o, n) = parseHunkHeader(line) { oldLine = o; newLine = n }
            result.append(DiffLine(kind: .hunk, text: line, oldNum: nil, newNum: nil))
        } else if line.hasPrefix("+") {
            result.append(DiffLine(kind: .added, text: String(line.dropFirst()), oldNum: nil, newNum: newLine))
            newLine += 1
        } else if line.hasPrefix("-") {
            result.append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldNum: oldLine, newNum: nil))
            oldLine += 1
        } else if !line.isEmpty {
            let text = line.hasPrefix(" ") ? String(line.dropFirst()) : line
            result.append(DiffLine(kind: .context, text: text, oldNum: oldLine, newNum: newLine))
            oldLine += 1; newLine += 1
        }
    }
    return result
}

private func parseHunkHeader(_ line: String) -> (Int, Int)? {
    let pat = #"^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@"#
    guard let re  = try? NSRegularExpression(pattern: pat),
          let m   = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
          let r1  = Range(m.range(at: 1), in: line),
          let r2  = Range(m.range(at: 2), in: line),
          let old = Int(line[r1]),
          let new = Int(line[r2]) else { return nil }
    return (old, new)
}

// MARK: - Directory tree node

private struct DirectoryNode: View {
    let path: String
    let depth: Int
    @Binding var expandedDirs: Set<String>
    @Binding var selectedPath: String?
    let onOpen: (String) -> Void

    @State private var children: [FSItem]? = nil
    @State private var isExpanded: Bool = false

    private var isDir: Bool {
        var isD: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isD) && isD.boolValue
    }

    var body: some View {
        if isDir {
            VStack(alignment: .leading, spacing: 0) {
                DirectoryRow(
                    name: URL(fileURLWithPath: path).lastPathComponent,
                    depth: depth,
                    isExpanded: isExpanded,
                    isRoot: depth == 0
                )
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                    if isExpanded && children == nil { loadChildren() }
                }

                if isExpanded, let kids = children {
                    ForEach(kids) { item in
                        DirectoryNode(
                            path: item.path,
                            depth: depth + 1,
                            expandedDirs: $expandedDirs,
                            selectedPath: $selectedPath,
                            onOpen: onOpen
                        )
                    }
                }
            }
            .onAppear {
                if depth == 0 { isExpanded = true; loadChildren() }
            }
        } else {
            FileRow(
                name: URL(fileURLWithPath: path).lastPathComponent,
                depth: depth,
                isSelected: selectedPath == path
            )
            .onTapGesture { onOpen(path) }
        }
    }

    private func loadChildren() {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: path) else { return }
        let filtered = entries
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .filter { name -> Bool in
                let full = (path as NSString).appendingPathComponent(name)
                var isD: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isD)
                return isD.boolValue || isSupportedFile(name)
            }
        let mapped = filtered.map { FSItem(name: $0, basePath: path) }
        children = mapped.sorted { l, r in
            if l.isDirectory != r.isDirectory { return l.isDirectory }
            return l.name < r.name
        }
    }

    private func isSupportedFile(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return textExtensions.contains(ext) || ext.isEmpty
    }
}

private let textExtensions: Set<String> = [
    "md", "txt", "swift", "js", "ts", "tsx", "jsx", "py", "rb", "go",
    "java", "kt", "rs", "c", "cpp", "h", "hpp", "css", "html", "htm",
    "json", "yaml", "yml", "toml", "xml", "sh", "bash", "zsh", "fish",
    "env", "gitignore", "dockerfile", "makefile", "gradle", "podspec",
    "plist", "xcconfig", "lock"
]

private struct FSItem: Identifiable {
    let name: String
    let basePath: String
    var id: String { path }
    var path: String { (basePath as NSString).appendingPathComponent(name) }
    var isDirectory: Bool {
        var isD: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isD)
        return isD.boolValue
    }
}

// MARK: - Row views

private struct DirectoryRow: View {
    let name: String
    let depth: Int
    let isExpanded: Bool
    var isRoot: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(depth) * 14)
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 10)
            Image(systemName: isExpanded ? "folder.fill" : "folder")
                .font(.caption)
                .foregroundStyle(isExpanded ? .yellow : .secondary)
            Text(name)
                .font(isRoot ? .caption.weight(.semibold) : .caption)
                .foregroundStyle(isRoot ? .primary : .secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }
}

private struct FileRow: View {
    let name: String
    let depth: Int
    let isSelected: Bool

    private var ext: String { (name as NSString).pathExtension.lowercased() }

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(depth) * 14 + 14)
            Image(systemName: fileIcon)
                .font(.caption2)
                .foregroundStyle(iconColor)
            Text(name)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
    }

    private var fileIcon: String {
        switch ext {
        case "md":                       return "doc.richtext"
        case "swift":                    return "swift"
        case "js","ts","jsx","tsx":      return "doc.badge.gearshape"
        case "py":                       return "doc.badge.gearshape"
        case "json","yaml","yml","toml": return "doc.text"
        case "sh","bash","zsh":          return "terminal"
        default:                         return "doc.text"
        }
    }
    private var iconColor: Color {
        switch ext {
        case "md":                  return .blue
        case "swift":               return .orange
        case "js","ts","jsx","tsx": return .yellow
        case "py":                  return .green
        case "sh","bash","zsh":     return .purple
        default:                    return .secondary
        }
    }
}
