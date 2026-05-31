import SwiftUI
import AppKit

// MARK: - Root shell (prototype `App`)
//
// Custom split: sidebar | conversation. Forces a light, full-size-content
// window (traffic lights overlaid on the sidebar's 44pt top inset). Reuses the
// existing ConnectSheet / ImportSessionSheet and the file-preview window for
// v1; the docked workspace panel + native Settings land in the next phase.

struct RootView: View {
    @Environment(AppViewModel.self) private var app
    @Environment(SettingsStore.self) private var settings
    @State private var notif = NotificationStore()
    @State private var showConnect = false
    @State private var settingsOpen = false

    var body: some View {
        @Bindable var app = app
        ZStack {
            HStack(spacing: 0) {
                SidebarView(
                    onOpenSettings: { settingsOpen = true },
                    onOpenConnect: { showConnect = true }
                )
                ConversationPane(notif: notif)
            }
            ToastStack(store: notif, onOpen: { n in app.selectedAgentId = n.chatId; notif.markRead(n.id) })
                .allowsHitTesting(!notif.toasts.isEmpty)
        }
        .background(DS.contentBG)
        .background(WindowConfigurator())
        .environment(\.accent, settings.accentPalette)
        .preferredColorScheme(.light)
        .ignoresSafeArea()
        .sheet(isPresented: $showConnect) { ConnectSheet() }
        .sheet(isPresented: $app.importSheetOpen) { ImportSessionSheet() }
        .sheet(isPresented: $settingsOpen) {
            SettingsView(
                onOpenConnect: { settingsOpen = false; showConnect = true },
                onClose: { settingsOpen = false }
            )
            .environment(\.accent, settings.accentPalette)
        }
        .task {
            app.autoConnectIfPossible()
            app.startWakeObserver()
        }
        .onChange(of: app.connectionState) { _, s in
            if case .disconnected = s, (app.savedOfferRaw ?? "").isEmpty { showConnect = true }
        }
    }
}

// MARK: - Conversation pane (header + tabs + transcript + composer)

private struct ConversationPane: View {
    let notif: NotificationStore
    @Environment(AppViewModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var tabs: [String] = []
    @State private var searchVisible = false
    @State private var searchText = ""
    @State private var repoUrl: String? = nil

    private var agentId: String? { app.selectedAgentId }
    private var currentAgent: AgentSnapshot? {
        guard let id = agentId else { return nil }
        return app.agents.first { $0.id == id } ?? app.archivedAgents.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(
                agent: currentAgent,
                working: currentWorking,
                repoUrl: repoUrl,
                panelOpen: false,
                notifStore: notif,
                onTogglePanel: openWorkspace,
                onOpenChanges: openWorkspace,
                onOpenNotif: { n in app.selectedAgentId = n.chatId; notif.markRead(n.id) },
                onSearch: { withAnimation(.easeInOut(duration: 0.15)) { searchVisible.toggle() }; if !searchVisible { searchText = "" } }
            )
            TabStripView(
                tabs: tabItems, activeId: agentId,
                onSelect: { app.selectedAgentId = $0 },
                onClose: closeTab,
                onNew: newConversation
            )
            if searchVisible { searchBar }
            content
        }
        .background(DS.contentBG)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if let id = agentId, !tabs.contains(id) { tabs.append(id) } }
        .onChange(of: agentId) { _, id in if let id, !tabs.contains(id) { tabs.append(id) } }
        .task(id: currentAgent?.cwd ?? "") {
            repoUrl = await app.fetchGitHubUrl(for: currentAgent?.cwd ?? "")
        }
    }

    @ViewBuilder private var content: some View {
        if let id = agentId {
            let vm = app.conversation(for: id)
            if id == AppViewModel.pendingAgentId {
                PendingConversationView()
                ComposerCard(vm: vm)
            } else {
                TranscriptView(
                    vm: vm, agentProvider: currentAgent?.provider, workspaceCwd: currentAgent?.cwd,
                    searchText: searchText, onOpenFile: openFile
                )
                ComposerCard(vm: vm)
            }
        } else {
            EmptyStateView(state: app.connectionState)
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            DSIcon(name: "search", size: 13).foregroundStyle(DS.text3)
            TextField("搜索消息", text: $searchText).textFieldStyle(.plain).font(.system(size: 13.5))
            if !searchText.isEmpty { Button { searchText = "" } label: { DSIcon(name: "x", size: 12).foregroundStyle(DS.text3) }.buttonStyle(.plain) }
            Button("完成") { withAnimation { searchVisible = false }; searchText = "" }.buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(DS.text2)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.divider).frame(height: 1) }
    }

    private var currentWorking: Bool {
        guard let id = agentId, id != AppViewModel.pendingAgentId else { return false }
        return app.conversation(for: id).isAgentWorking
    }

    private var tabItems: [TabItem] {
        tabs.compactMap { id in
            if id == AppViewModel.pendingAgentId { return TabItem(id: id, title: "新对话", provider: app.pendingNewAgentProvider) }
            guard let a = app.agents.first(where: { $0.id == id }) ?? app.archivedAgents.first(where: { $0.id == id }) else { return nil }
            return TabItem(id: id, title: a.displayName, provider: a.provider)
        }
    }

    private func closeTab(_ id: String) {
        tabs.removeAll { $0 == id }
        if app.selectedAgentId == id { app.selectedAgentId = tabs.last }
    }
    private func newConversation() {
        if let cwd = currentAgent?.cwd { Task { await app.createAgent(cwd: cwd) } }
    }
    private func openWorkspace() {
        if let cwd = currentAgent?.cwd { openWindow(value: WorkspaceFilePreviewRoute(cwd: cwd, path: ".")) }
    }
    private func openFile(_ raw: String) {
        guard let cwd = currentAgent?.cwd else { return }
        openWindow(value: WorkspaceFilePreviewRouting.forceRoute(cwd: cwd, rawLocation: raw))
    }
}

// MARK: - States

private struct PendingConversationView: View {
    @Environment(AppViewModel.self) private var app
    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            if let err = app.creatingAgentError {
                DSIcon(name: "alert", size: 28).foregroundStyle(DS.orange)
                Text("无法启动会话").font(.system(size: 16, weight: .semibold)).foregroundStyle(DS.text)
                Text(err).font(.system(size: 13)).foregroundStyle(DS.text2).multilineTextAlignment(.center).padding(.horizontal, 40)
            } else if let text = app.creatingAgentText {
                if !app.creatingAgentImages.isEmpty { UserTurnView(group: TurnGroup(id: "creating", isUser: true, text: text, images: app.creatingAgentImages)) }
                else { UserTurnView(group: TurnGroup(id: "creating", isUser: true, text: text)) }
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("正在启动会话…").font(.system(size: 13)).foregroundStyle(DS.text2) }
            } else {
                DSIcon(name: "chat", size: 34, weight: .light).foregroundStyle(DS.text3)
                Text("输入消息开始对话").font(.system(size: 14)).foregroundStyle(DS.text2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyStateView: View {
    let state: AppViewModel.ConnectionState
    var body: some View {
        VStack(spacing: 12) {
            switch state {
            case .connecting:
                ProgressView(); Text("连接中…").font(.system(size: 14)).foregroundStyle(DS.text2)
            case .connected:
                DSIcon(name: "chat", size: 32, weight: .light).foregroundStyle(DS.text3)
                Text("从侧栏选择一个会话").font(.system(size: 14)).foregroundStyle(DS.text2)
            case .disconnected, .failed:
                DSIcon(name: "cloud-slash", size: 32, weight: .light).foregroundStyle(DS.text3)
                Text("未连接").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                Text("粘贴配对 offer 以连接守护进程。").font(.system(size: 13)).foregroundStyle(DS.text2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Window chrome (light, full-size content)

struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { configure(v.window) } }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .white
        if let tb = window.standardWindowButton(.closeButton)?.superview {
            tb.isHidden = false // keep traffic lights visible
        }
    }
}
