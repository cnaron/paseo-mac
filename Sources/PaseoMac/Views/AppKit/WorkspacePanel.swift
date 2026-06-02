import SwiftUI
import AppKit

// MARK: - Docked workspace panel (prototype `FilePanel`)
//
// Docks on the right of the whole conversation as a collapsible 3rd split column.
// Tabs: 变更 (left, default) / 文件 (right). File content opens in a separate
// workspace preview page so it gets conversation-width space instead of being
// squeezed into this narrow navigation panel.

@MainActor
@Observable
final class WorkspacePanelModel {
    var isOpen = false
    var tab = "changes"            // "changes" | "files"
    /// When set, the conversation column shows a full-page in-window file
    /// preview over the transcript+composer (NOT a separate window, NOT a
    /// narrow docked column). Cleared by the preview's close (✕) button.
    var previewRoute: WorkspaceFilePreviewRoute? = nil

    func toggle() { isOpen.toggle() }
    func openChanges() { tab = "changes"; isOpen = true }
    func toggleChanges() {
        if isOpen, tab == "changes" { close() }
        else { openChanges() }
    }
    func openFile(cwd: String, raw: String) {
        previewRoute = WorkspaceFilePreviewRouting.forceRoute(cwd: cwd, rawLocation: raw)
        isOpen = false
    }
    func openListed(cwd: String, path: String) {
        previewRoute = WorkspaceFilePreviewRouting.forceRoute(cwd: cwd, rawLocation: path)
        isOpen = false
    }
    func closePreview() { previewRoute = nil }
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
            ChangesTab(changes: deriveChanges(vm), onOpen: { model.openListed(cwd: cwd, path: $0) })
        } else {
            FilesTab(cwd: cwd, onOpen: { model.openListed(cwd: cwd, path: $0) })
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
