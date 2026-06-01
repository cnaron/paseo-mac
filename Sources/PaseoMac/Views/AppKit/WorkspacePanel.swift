import SwiftUI
import AppKit

// MARK: - Docked workspace panel (prototype `FilePanel`)
//
// Docks on the right of the whole conversation as a collapsible 3rd split column
// (not a window). Tabs: 变更 (left, default) / 文件 (right). Clicking a file link
// in the transcript, the header changes button, or a file row expands the panel
// and locates the target — no path/breadcrumb on the file view. Shares the header
// toggle. Changes are derived from the agent's Edit/Write tool calls this session.

@MainActor
@Observable
final class WorkspacePanelModel {
    var isOpen = false
    var tab = "changes"            // "changes" | "files"
    var filePath: String? = nil    // non-nil + tab=="files" → show file content
    var lineStart: Int? = nil
    var lineEnd: Int? = nil
    var nonce = 0

    func toggle() { isOpen.toggle() }
    func openChanges() { tab = "changes"; filePath = nil; isOpen = true }
    func openFile(_ raw: String) {
        let p = WorkspaceFilePreviewRouting.parseLocation(raw)
        filePath = p.path; lineStart = p.lineStart; lineEnd = p.lineEnd
        tab = "files"; isOpen = true; nonce += 1
    }
    func openListed(_ path: String) {
        filePath = path; lineStart = nil; lineEnd = nil; tab = "files"; isOpen = true; nonce += 1
    }
    func back() { filePath = nil; nonce += 1 }
    func close() { isOpen = false }
}

struct WorkspacePanelView: View {
    let model: WorkspacePanelModel
    @Environment(AppViewModel.self) private var app

    private var cwd: String {
        guard let id = app.selectedAgentId else { return "" }
        return (app.agents.first { $0.id == id } ?? app.archivedAgents.first { $0.id == id })?.cwd ?? ""
    }
    private var vm: ConversationViewModel? {
        guard let id = app.selectedAgentId, id != AppViewModel.pendingAgentId else { return nil }
        return app.conversation(for: id)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(DS.divider).frame(height: 1)
            content
        }
        .background(DS.contentBG)
        .overlay(alignment: .leading) { Rectangle().fill(DS.divider).frame(width: 1) }
    }

    private var topBar: some View {
        HStack(spacing: 2) {
            tabButton("changes", "变更")
            tabButton("files", "文件")
            Spacer()
            IconButton(icon: "x", box: 24, glyph: 16, help: "关闭") { model.close() }
        }
        .padding(.horizontal, 10).frame(height: 52)
    }

    private func tabButton(_ id: String, _ label: String) -> some View {
        let on = model.tab == id
        return Button {
            model.tab = id
            if id == "changes" { model.filePath = nil }
        } label: {
            Text(label).font(.system(size: 14, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? DS.text : DS.text3)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(on ? DS.hover : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var content: some View {
        if model.tab == "changes" {
            ChangesTab(changes: deriveChanges(vm), onOpen: { model.openListed($0) })
        } else {
            // Keep FilesTab mounted as the base layer so it never flashes
            // when a file is selected. FileContentTab slides in on top.
            ZStack(alignment: .top) {
                FilesTab(cwd: cwd, onOpen: { model.openListed($0) })
                if let path = model.filePath {
                    FileContentTab(cwd: cwd, path: path, lineStart: model.lineStart, lineEnd: model.lineEnd,
                                   nonce: model.nonce, onBack: { model.back() })
                    .background(DS.contentBG)
                    .transition(.opacity)
                }
            }
        }
    }
}

// MARK: - 变更 (derived from the session's Edit/Write tool calls)

struct WorkspaceChange: Identifiable {
    let path: String
    let name: String
    let status: String  // "added" | "modified"
    var id: String { path }
}

@MainActor
func deriveChanges(_ vm: ConversationViewModel?) -> [WorkspaceChange] {
    guard let vm else { return [] }
    var status: [String: String] = [:]
    var order: [String] = []
    for row in vm.rows where row.kind == "tool" {
        guard let t = row.tool, var target = t.target, !target.isEmpty else { continue }
        if let colon = target.firstIndex(of: ":") { target = String(target[..<colon]) }
        let name = t.name.lowercased()
        let isWrite = name.contains("write"), isEdit = name.contains("edit")
        guard isWrite || isEdit else { continue }
        if status[target] == nil { order.append(target) }
        if isWrite, status[target] == nil { status[target] = "added" }
        else if status[target] == nil { status[target] = "modified" }
    }
    return order.map { WorkspaceChange(path: $0, name: URL(fileURLWithPath: $0).lastPathComponent, status: status[$0] ?? "modified") }
}

private struct ChangesTab: View {
    let changes: [WorkspaceChange]
    let onOpen: (String) -> Void

    var body: some View {
        if changes.isEmpty {
            VStack { Spacer(); Text("暂无变更").font(.system(size: 13.5)).foregroundStyle(DS.text3); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 4) {
                        Text("变更").font(.system(size: 13, weight: .semibold)).foregroundStyle(DS.text)
                        Text("· \(changes.count)").font(.system(size: 13)).foregroundStyle(DS.text3)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 10)
                    ForEach(changes) { c in changeRow(c) }
                }
            }
        }
    }

    private func changeRow(_ c: WorkspaceChange) -> some View {
        let added = c.status == "added"
        return Button { onOpen(c.path) } label: {
            HStack(spacing: 9) {
                Text(added ? "A" : "M").font(.system(size: 11, weight: .bold))
                    .foregroundStyle(added ? DS.greenSoftTX : DS.orange)
                    .frame(width: 18, height: 18)
                    .background(added ? DS.greenSoftBG : DS.orangeSoftBG, in: RoundedRectangle(cornerRadius: 5))
                Text(c.name).font(.system(size: 13.5)).foregroundStyle(DS.text).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 文件 (list cwd, click to open)

private struct FilesTab: View {
    let cwd: String
    let onOpen: (String) -> Void
    @Environment(AppViewModel.self) private var app
    @State private var path = "."
    @State private var entries: [FileExplorerEntry] = []
    @State private var loading = false
    @State private var error: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if path != "." {
                    row(icon: "chevron-up", name: "..", dir: true) { navigate(up()) }
                }
                if loading { ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 12) }
                if let error { Text(error).font(.system(size: 12)).foregroundStyle(DS.red).padding(12) }
                ForEach(entries.sorted { ($0.kind == "directory" ? 0 : 1, $0.name.lowercased()) < ($1.kind == "directory" ? 0 : 1, $1.name.lowercased()) }, id: \.path) { e in
                    row(icon: e.kind == "directory" ? "folder" : iconFor(e.name), name: e.name, dir: e.kind == "directory") {
                        if e.kind == "directory" { navigate(e.path) } else { onOpen(e.path) }
                    }
                }
            }
        }
        .task(id: "\(cwd)|\(path)") { await load() }
    }

    private func row(icon: String, name: String, dir: Bool, action: @escaping () -> Void) -> some View {
        HoverRow(radius: DS.R.row) {
            Button(action: action) {
                HStack(spacing: 9) {
                    DSIcon(name: icon, size: 15).foregroundStyle(DS.text3)
                    Text(name).font(.system(size: 13.5)).foregroundStyle(dir ? DS.text2 : DS.text).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 7).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func iconFor(_ name: String) -> String {
        let l = name.lowercased()
        if l.hasSuffix(".md") || l.hasSuffix(".markdown") { return "doc" }
        if l.hasSuffix(".png") || l.hasSuffix(".jpg") || l.hasSuffix(".jpeg") || l.hasSuffix(".gif") { return "image" }
        return "file-text"
    }
    private func up() -> String {
        let parts = path.split(separator: "/").dropLast()
        return parts.isEmpty ? "." : parts.joined(separator: "/")
    }
    private func navigate(_ p: String) { path = p }

    private func load() async {
        guard !cwd.isEmpty else { return }
        loading = true; error = nil
        defer { loading = false }
        do { entries = try await app.listWorkspaceDirectory(cwd: cwd, path: path).entries }
        catch let err { error = err.localizedDescription; entries = [] }
    }
}

// MARK: - file content (back + bare filename + line badge; code/md/image)

private struct FileContentTab: View {
    let cwd: String
    let path: String
    let lineStart: Int?
    let lineEnd: Int?
    let nonce: Int
    let onBack: () -> Void
    @Environment(AppViewModel.self) private var app
    @State private var file: FileExplorerFile? = nil
    @State private var imageData: Data? = nil
    @State private var loading = false
    @State private var error: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                IconButton(icon: "chevron-up", box: 24, glyph: 16, help: "返回文件列表", action: onBack)
                    .rotationEffect(.degrees(-90))
                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.text).lineLimit(1)
                if let s = lineStart {
                    Text(lineEnd.map { "line \(s)-\($0)" } ?? "line \(s)")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(AccentPalette.terracotta.accent)
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(AccentPalette.terracotta.tint, in: RoundedRectangle(cornerRadius: 5))
                }
                Spacer()
            }
            .padding(.horizontal, 8).frame(height: 40)
            .background(Color(hex: 0xFBFBFA))
            .overlay(alignment: .bottom) { Rectangle().fill(DS.divider).frame(height: 1) }
            body0
        }
        .task(id: "\(path)|\(nonce)") { await load() }
    }

    @ViewBuilder private var body0: some View {
        if let error {
            VStack(spacing: 8) { Spacer(); DSIcon(name: "alert", size: 24).foregroundStyle(DS.orange); Text(error).font(.system(size: 12.5)).foregroundStyle(DS.text2).multilineTextAlignment(.center).padding(.horizontal, 20); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loading {
            VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let f = file {
            if f.kind == "image", let d = imageData, let ns = NSImage(data: d) {
                ScrollView([.horizontal, .vertical]) { Image(nsImage: ns).resizable().interpolation(.high).scaledToFit().padding(16) }
            } else if f.kind == "text", let content = f.content {
                if (path.lowercased().hasSuffix(".md") || path.lowercased().hasSuffix(".markdown")), lineStart == nil {
                    ScrollView { MarkdownBodyView(text: content, workspaceCwd: cwd).frame(maxWidth: .infinity, alignment: .leading).padding(18) }
                } else {
                    WorkspaceCodePreview(content: content, filePath: f.path, revisionToken: "\(f.modifiedAt)|\(f.size)", lineStart: lineStart, lineEnd: lineEnd)
                }
            } else {
                VStack(spacing: 8) { Spacer(); DSIcon(name: "file-text", size: 28).foregroundStyle(DS.text3); Text("无法以文本渲染（二进制 · \(ByteCountFormatter.string(fromByteCount: Int64(f.size), countStyle: .file))）").font(.system(size: 13)).foregroundStyle(DS.text3); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func load() async {
        guard !cwd.isEmpty else { return }
        loading = true; error = nil
        defer { loading = false }
        do {
            let readPath = WorkspaceFilePreviewRouting.normalizePathForWorkspace(path, cwd: cwd) ?? path
            let f = try await app.readWorkspaceFile(cwd: cwd, path: readPath)
            file = f
            imageData = (f.kind == "image" && f.encoding == "base64") ? f.content.flatMap { Data(base64Encoded: $0) } : nil
        } catch let err { file = nil; imageData = nil; error = err.localizedDescription }
    }
}
