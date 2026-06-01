import SwiftUI
import AppKit

// MARK: - Conversation pane (AppKit)
//
// header+tabs island (auto-updating SwiftUI) on top · AppKit transcript table in
// the middle (the stability fix) · composer island on the bottom. Only the
// transcript is AppKit-native; header/composer/sidebar stay SwiftUI islands that
// re-render themselves via Observation — without the List/ScrollView container
// that lost scroll position.

final class ConversationVC: NSViewController {
    let app: AppViewModel
    let settings: SettingsStore
    let notif: NotificationStore
    let panelModel: WorkspacePanelModel

    private var headerHost: NSHostingView<AnyView>!
    private var composerHost: NSHostingView<AnyView>!
    let transcriptVC: TranscriptVC
    private var lastAccentHex: String = ""

    init(app: AppViewModel, settings: SettingsStore, notif: NotificationStore, panelModel: WorkspacePanelModel) {
        self.app = app
        self.settings = settings
        self.notif = notif
        self.panelModel = panelModel
        self.transcriptVC = TranscriptVC(app: app, settings: settings, onOpenFile: { panelModel.openFile($0) })
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.white.cgColor

        headerHost = NSHostingView(rootView: header())
        composerHost = NSHostingView(rootView: composer())
        let table = transcriptVC.view
        addChild(transcriptVC)

        for v in [headerHost, table, composerHost] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        // header content-hugging so it stays at its intrinsic height; composer too.
        headerHost.setContentHuggingPriority(.required, for: .vertical)
        composerHost.setContentHuggingPriority(.required, for: .vertical)

        NSLayoutConstraint.activate([
            headerHost.topAnchor.constraint(equalTo: root.topAnchor),
            headerHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            table.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            table.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: composerHost.topAnchor),

            composerHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            composerHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            composerHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeSelection()
        syncAgent()
    }

    // The header/composer islands auto-update via Observation; we only re-bind
    // the AppKit transcript when the active agent changes.
    private func observeSelection() {
        withObservationTracking {
            _ = app.selectedAgentId
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.syncAgent(); self?.observeSelection() }
        }
    }

    private func syncAgent() {
        let id = app.selectedAgentId
        let agent = id.flatMap { aid in app.agents.first { $0.id == aid } ?? app.archivedAgents.first { $0.id == aid } }
        let isPending = id == AppViewModel.pendingAgentId
        let vm = (id != nil && !isPending) ? app.conversation(for: id!) : nil
        transcriptVC.bind(vm: vm, agentProvider: agent?.provider, workspaceCwd: agent?.cwd,
                          pending: isPending)
    }

    // Only replace rootViews when the accent color changes. The islands
    // self-update via @Observable observation for everything else. Calling
    // this on every app property mutation (agent list updates, streaming)
    // rebuilds the NSHostingView tree, causes NSTextView to lose focus,
    // and wipes partially-typed composer text.
    func refreshIslands() {
        guard isViewLoaded else { return }
        let accent = settings.accentHex
        guard accent != lastAccentHex else { return }
        lastAccentHex = accent
        headerHost.rootView = header()
        composerHost.rootView = composer()
    }

    private func header() -> AnyView {
        AnyView(
            ConversationHeaderIsland(
                notif: notif,
                onTogglePanel: { [panelModel] in panelModel.toggle() },
                onOpenChanges: { [panelModel] in panelModel.openChanges() }
            )
            .environment(app).environment(settings).environment(\.accent, settings.accentPalette)
        )
    }
    private func composer() -> AnyView {
        AnyView(
            ConversationComposerIsland()
                .environment(app).environment(settings).environment(\.accent, settings.accentPalette)
        )
    }
}

// MARK: - Header + tabs island (auto-updating)

private struct ConversationHeaderIsland: View {
    @Environment(AppViewModel.self) private var app
    let notif: NotificationStore
    var onTogglePanel: () -> Void
    var onOpenChanges: () -> Void
    @State private var tabs: [String] = []
    @State private var repoUrl: String? = nil

    private var agentId: String? { app.selectedAgentId }
    private var currentAgent: AgentSnapshot? {
        guard let id = agentId else { return nil }
        return app.agents.first { $0.id == id } ?? app.archivedAgents.first { $0.id == id }
    }
    private var working: Bool {
        guard let id = agentId, id != AppViewModel.pendingAgentId else { return false }
        return app.conversation(for: id).isAgentWorking
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(
                agent: currentAgent, working: working, repoUrl: repoUrl, panelOpen: false,
                notifStore: notif,
                onTogglePanel: onTogglePanel, onOpenChanges: onOpenChanges,
                onOpenNotif: { n in app.selectedAgentId = n.chatId; notif.markRead(n.id) }
            )
            TabStripView(
                tabs: tabItems, activeId: agentId,
                onSelect: { app.selectedAgentId = $0 },
                onClose: closeTab,
                onNew: { if let cwd = currentAgent?.cwd { Task { await app.createAgent(cwd: cwd) } } }
            )
        }
        .background(DS.contentBG)
        .onAppear { if let id = agentId, !tabs.contains(id) { tabs.append(id) } }
        .onChange(of: agentId) { _, id in if let id, !tabs.contains(id) { tabs.append(id) } }
        .task(id: currentAgent?.cwd ?? "") { repoUrl = await app.fetchGitHubUrl(for: currentAgent?.cwd ?? "") }
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
}

// MARK: - Composer island (auto-updating)

private struct ConversationComposerIsland: View {
    @Environment(AppViewModel.self) private var app
    private var agentId: String? { app.selectedAgentId }

    var body: some View {
        if let id = agentId {
            ComposerCard(vm: app.conversation(for: id))
        } else {
            Color.clear.frame(height: 0)
        }
    }
}
