import SwiftUI
import AppKit

// MARK: - Conversation header (prototype `ConvHeader`)

struct ChangesSummary: Equatable {
    var count: Int = 0
    var add: Int = 0
    var del: Int = 0
}

struct HeaderBar: View {
    let agent: AgentSnapshot?
    var working: Bool = false
    var repoUrl: String? = nil
    var changes = ChangesSummary()
    var panelOpen: Bool = false
    let notifStore: NotificationStore
    var onTogglePanel: () -> Void = {}
    var onOpenChanges: () -> Void = {}
    var onOpenNotif: (AppNotification) -> Void = { _ in }
    var onSearch: () -> Void = {}

    @Environment(AppViewModel.self) private var app
    @State private var renaming = false
    @State private var draftName = ""
    @State private var panelHover = false

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 9) {
                DSIcon(name: "chat", size: 18).foregroundStyle(DS.text)
                Text(agent?.displayName ?? "新对话")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
            }
            Spacer(minLength: 8)

            if working {
                HStack(spacing: 7) {
                    ThinkingDots()
                    Text("Working…").font(.system(size: 13)).foregroundStyle(DS.text2)
                }
                .padding(.trailing, 4)
            }

            if let repoUrl, let url = URL(string: repoUrl) {
                Button { NSWorkspace.shared.open(url) } label: {
                    HStack(spacing: 7) {
                        DSIcon(name: "github", size: 16).foregroundStyle(DS.text)
                        Text("Open").font(.system(size: 13.5, weight: .medium)).foregroundStyle(DS.text)
                    }
                    .pillSurface(radius: 8, height: 30, hpad: 12)
                }
                .buttonStyle(.plain)
                .help("在 GitHub 打开")
            }

            // "变更" button opens the changes tab in the workspace panel.
            // It also acts as the panel toggle — no separate sidebar icon needed.
            Button(action: onOpenChanges) {
                HStack(spacing: 6) {
                    DSIcon(name: "diffstat", size: 16).foregroundStyle(panelOpen ? DS.text : DS.text3)
                    if changes.count > 0 {
                        Text("+\(changes.add)").font(.system(size: 13.5, weight: .semibold)).monospacedDigit().foregroundStyle(DS.greenSoftTX)
                        Text("−\(changes.del)").font(.system(size: 13.5, weight: .semibold)).monospacedDigit().foregroundStyle(DS.red)
                    } else {
                        Text("变更").font(.system(size: 13.5, weight: .medium)).foregroundStyle(panelOpen ? DS.text : DS.text2)
                    }
                }
                .pillSurface(radius: 8, height: 30, hpad: 12)
                .background(panelOpen ? DS.hover : .clear, in: RoundedRectangle(cornerRadius: 8))
                .overlay { if panelOpen { RoundedRectangle(cornerRadius: 8).strokeBorder(DS.dividerStrong, lineWidth: 1) } }
            }
            .buttonStyle(.plain)
            .help(changes.count > 0 ? "\(changes.count) 个文件改动 · 点击查看" : "工作区变更")

            NotifBell(store: notifStore, onOpen: onOpenNotif)

            Menu {
                if let a = agent {
                    Button { Task { await app.createAgent(cwd: a.cwd) } } label: { Label("新建同目录会话", systemImage: "plus") }
                }
                Button { onSearch() } label: { Label("搜索", systemImage: "magnifyingglass") }
                if agent != nil {
                    Divider()
                    Button { draftName = agent?.title ?? agent?.displayName ?? ""; renaming = true } label: { Label("重命名…", systemImage: "pencil") }
                    Button(role: .destructive) {
                        if let a = agent { Task { await app.archiveAgent(agentId: a.id) } }
                    } label: { Label("归档会话", systemImage: "archivebox") }
                }
            } label: {
                DSIcon(name: "dots", size: 18).foregroundStyle(DS.text2).frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.leading, 22).padding(.trailing, 12)
        .frame(height: 52)
        .alert("重命名会话", isPresented: $renaming) {
            TextField("名称", text: $draftName)
            Button("保存") {
                if let a = agent {
                    let t = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !t.isEmpty { Task { await app.renameAgent(agentId: a.id, name: t) } }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }
}

// MARK: - Tab strip (prototype `TabStrip`)

struct TabItem: Identifiable, Equatable {
    let id: String
    let title: String
    let provider: String?
}

struct TabStripView: View {
    let tabs: [TabItem]
    let activeId: String?
    var onSelect: (String) -> Void = { _ in }
    var onClose: (String) -> Void = { _ in }
    var onNew: () -> Void = {}

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { t in
                TabButton(tab: t, active: t.id == activeId,
                          onSelect: { onSelect(t.id) }, onClose: { onClose(t.id) })
            }
            Button(action: onNew) {
                DSIcon(name: "plus", size: 16).foregroundStyle(DS.text2)
                    .frame(width: 30, height: 29)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("新标签页")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 41)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.divider).frame(height: 1) }
    }
}

private struct TabButton: View {
    let tab: TabItem
    let active: Bool
    var onSelect: () -> Void
    var onClose: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                ProviderGlyph(provider: tab.provider, size: 14).frame(width: 14, height: 14)
                Text(tab.title)
                    .font(.system(size: 13.5, weight: active ? .medium : .regular))
                    .foregroundStyle(active ? DS.text : DS.text2)
                    .lineLimit(1).frame(maxWidth: 150, alignment: .leading)
                Group {
                    if hover {
                        Button(action: onClose) { DSIcon(name: "x", size: 12).foregroundStyle(DS.text3) }
                            .buttonStyle(.plain)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 18, height: 18)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: 230, minHeight: 41, maxHeight: 41)
            .overlay(alignment: .bottom) {
                if active { Rectangle().fill(DS.text).frame(height: 2).padding(.horizontal, 8) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
