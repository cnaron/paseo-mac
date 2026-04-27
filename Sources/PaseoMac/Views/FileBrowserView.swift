import SwiftUI

// MARK: - Entry point

struct FileBrowserView: View {
    let rootPath: String
    @Environment(SettingsStore.self) private var settings
    @State private var selectedPath: String? = nil
    @State private var expandedDirs: Set<String> = []
    @State private var openTabs: [FileTab] = []
    @State private var activeTab: String? = nil  // tab path

    struct FileTab: Identifiable, Equatable {
        let id: String   // path
        var path: String { id }
        var name: String { URL(fileURLWithPath: id).lastPathComponent }
    }

    var body: some View {
        HSplitView {
            // Left: file tree
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    DirectoryNode(
                        path: rootPath,
                        depth: 0,
                        expandedDirs: $expandedDirs,
                        selectedPath: $selectedPath,
                        onOpen: openFile
                    )
                }
                .padding(.vertical, 8)
            }
            .frame(minWidth: 180, idealWidth: 220, maxWidth: 300)
            .background(Color(NSColor.windowBackgroundColor))

            // Right: content
            if openTabs.isEmpty {
                ContentUnavailableView(
                    "Select a file",
                    systemImage: "doc.text",
                    description: Text("Click a file in the tree to view it")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 0) {
                    // Tab bar
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(openTabs) { tab in
                                FileTabButton(
                                    tab: tab,
                                    isActive: activeTab == tab.id,
                                    onSelect: { activeTab = tab.id },
                                    onClose: { closeTab(tab.id) }
                                )
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .frame(height: 36)
                    .background(Color(NSColor.windowBackgroundColor))
                    Divider()

                    // File content
                    if let path = activeTab {
                        FileContentView(path: path)
                            .id(path)
                            .environment(settings)
                    }
                }
            }
        }
    }

    private func openFile(_ path: String) {
        selectedPath = path
        if !openTabs.contains(where: { $0.id == path }) {
            openTabs.append(FileTab(id: path))
        }
        activeTab = path
    }

    private func closeTab(_ path: String) {
        openTabs.removeAll { $0.id == path }
        if activeTab == path {
            activeTab = openTabs.last?.id
        }
    }
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
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                    if isExpanded && children == nil {
                        loadChildren()
                    }
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
                if depth == 0 {
                    isExpanded = true
                    loadChildren()
                }
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
        let hidden = entries.filter { !$0.hasPrefix(".") }.sorted()
        let shown = hidden.filter { name in
            let full = (path as NSString).appendingPathComponent(name)
            var isD: ObjCBool = false
            fm.fileExists(atPath: full, isDirectory: &isD)
            return isD.boolValue || isSupportedFile(name)
        }
        children = shown.map { FSItem(name: $0, basePath: path) }
            .sorted { lhs, rhs in
                let lDir = lhs.isDirectory; let rDir = rhs.isDirectory
                if lDir != rDir { return lDir }
                return lhs.name < rhs.name
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
        .background(isSelected ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
    }

    private var fileIcon: String {
        switch ext {
        case "md": return "doc.richtext"
        case "swift": return "swift"
        case "js", "ts", "jsx", "tsx": return "doc.badge.gearshape"
        case "py": return "doc.badge.gearshape"
        case "json", "yaml", "yml", "toml": return "doc.text"
        case "sh", "bash", "zsh": return "terminal"
        default: return "doc.text"
        }
    }

    private var iconColor: Color {
        switch ext {
        case "md": return .blue
        case "swift": return .orange
        case "js", "ts", "jsx", "tsx": return .yellow
        case "py": return .green
        case "sh", "bash", "zsh": return .purple
        default: return .secondary
        }
    }
}

// MARK: - Tab button

private struct FileTabButton: View {
    let tab: FileBrowserView.FileTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(tab.name)
                .font(.caption)
                .foregroundStyle(isActive ? .primary : .secondary)
                .lineLimit(1)
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered || isActive ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isActive
                ? Color(NSColor.controlBackgroundColor)
                : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onHover { isHovered = $0 }
        .onTapGesture { onSelect() }
        .contentShape(Rectangle())
    }
}

// MARK: - File content view

private struct FileContentView: View {
    let path: String
    @Environment(SettingsStore.self) private var settings
    @State private var content: String = ""
    @State private var loadError: String? = nil

    private var isMarkdown: Bool {
        (path as NSString).pathExtension.lowercased() == "md"
    }

    var body: some View {
        ScrollView {
            fileContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: path) { load() }
    }

    @ViewBuilder
    private var fileContent: some View {
        if let err = loadError {
            Text(err)
                .foregroundStyle(.red)
                .padding()
        } else if isMarkdown {
            MarkdownBodyView(text: content)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        } else {
            Text(content)
                .font(.system(size: settings.scaled(13), design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
    }

    private func load() {
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
            loadError = nil
        } catch {
            loadError = "Cannot read file: \(error.localizedDescription)"
        }
    }
}
