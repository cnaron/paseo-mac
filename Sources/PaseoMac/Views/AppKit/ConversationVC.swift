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
    private var panelHost: NSHostingView<AnyView>!
    let transcriptVC: TranscriptVC
    private var lastAccentHex: String = ""
    private var tableTrailingClosed: NSLayoutConstraint!
    private var tableTrailingOpen: NSLayoutConstraint!

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
        panelHost = NSHostingView(rootView: panelView())
        let table = transcriptVC.view
        addChild(transcriptVC)

        for v in [headerHost, table, panelHost, composerHost] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        // header / composer content-hugging so they stay at intrinsic height.
        headerHost.setContentHuggingPriority(.required, for: .vertical)
        composerHost.setContentHuggingPriority(.required, for: .vertical)

        // Dynamic table trailing: closed → full width; open → stop at panel leading.
        tableTrailingClosed = table.trailingAnchor.constraint(equalTo: root.trailingAnchor)
        tableTrailingOpen   = table.trailingAnchor.constraint(equalTo: panelHost.leadingAnchor)
        let panelOpen = panelModel.isOpen
        tableTrailingClosed.isActive = !panelOpen
        tableTrailingOpen.isActive   = panelOpen
        panelHost.isHidden = !panelOpen

        NSLayoutConstraint.activate([
            headerHost.topAnchor.constraint(equalTo: root.topAnchor),
            headerHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            headerHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),

            table.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            table.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            table.bottomAnchor.constraint(equalTo: composerHost.topAnchor),

            panelHost.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            panelHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            panelHost.bottomAnchor.constraint(equalTo: composerHost.topAnchor),
            panelHost.widthAnchor.constraint(equalToConstant: 300),

            composerHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            composerHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            composerHost.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        observeSelection()
        observePanelModel()
        syncAgent()
    }

    private func observePanelModel() {
        withObservationTracking {
            _ = panelModel.isOpen
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.syncPanel(); self?.observePanelModel() }
        }
    }

    private func syncPanel() {
        let open = panelModel.isOpen
        panelHost.isHidden = !open
        if open {
            tableTrailingClosed.isActive = false
            tableTrailingOpen.isActive   = true
        } else {
            tableTrailingOpen.isActive   = false
            tableTrailingClosed.isActive = true
        }
        view.layoutSubtreeIfNeeded()
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
        panelHost.rootView = panelView()
    }

    private func panelView() -> AnyView {
        AnyView(
            WorkspacePanelView(model: panelModel)
                .environment(app).environment(settings).environment(\.accent, settings.accentPalette)
        )
    }

    private func header() -> AnyView {
        AnyView(
            ConversationHeaderIsland(
                panelModel: panelModel,
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
    let panelModel: WorkspacePanelModel
    let notif: NotificationStore
    var onTogglePanel: () -> Void
    var onOpenChanges: () -> Void
    @State private var repoUrl: String? = nil
    // Tracks tabs the user explicitly closed (so they stay hidden until the
    // agent is re-selected). Scoped to this island instance; resets when the
    // island is rebuilt (e.g. theme change) — acceptable for this lightweight state.
    @State private var closedTabs: Set<String> = []

    private var agentId: String? { app.selectedAgentId }
    private var currentAgent: AgentSnapshot? {
        guard let id = agentId else { return nil }
        return app.agents.first { $0.id == id } ?? app.archivedAgents.first { $0.id == id }
    }
    private var currentCwd: String? { currentAgent?.cwd }
    private var working: Bool {
        guard let id = agentId, id != AppViewModel.pendingAgentId else { return false }
        return app.conversation(for: id).isAgentWorking
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(
                agent: currentAgent, working: working, repoUrl: repoUrl, panelOpen: panelModel.isOpen,
                notifStore: notif,
                onTogglePanel: onTogglePanel, onOpenChanges: onOpenChanges,
                onOpenNotif: { n in app.selectedAgentId = n.chatId; notif.markRead(n.id) }
            )
            TabStripView(
                tabs: tabItems, activeId: agentId,
                onSelect: { id in closedTabs.remove(id); app.selectedAgentId = id },
                onClose: closeTab,
                onNew: { if let cwd = currentCwd { Task { await app.createAgent(cwd: cwd) } } }
            )
        }
        .background(DS.contentBG)
        .task(id: currentCwd ?? "") { repoUrl = await app.fetchGitHubUrl(for: currentCwd ?? "") }
    }

    // Only show tabs for agents in the same working directory. Clicking an
    // agent with a different cwd switches to it but doesn't add cross-project
    // tabs — each project directory has its own tab group.
    private var tabItems: [TabItem] {
        if agentId == AppViewModel.pendingAgentId {
            return [TabItem(id: AppViewModel.pendingAgentId, title: "新对话", provider: app.pendingNewAgentProvider)]
        }
        guard let cwd = currentCwd else { return [] }

        var items = app.agents
            .filter { $0.cwd == cwd && !closedTabs.contains($0.id) }
            .map { TabItem(id: $0.id, title: $0.displayName, provider: $0.provider) }

        // Always include the current agent even if somehow filtered out.
        if let id = agentId, !items.contains(where: { $0.id == id }),
           let a = app.agents.first(where: { $0.id == id }) ?? app.archivedAgents.first(where: { $0.id == id }) {
            items.append(TabItem(id: id, title: a.displayName, provider: a.provider))
        }
        return items
    }

    private func closeTab(_ id: String) {
        closedTabs.insert(id)
        if app.selectedAgentId == id {
            let next = tabItems.first { $0.id != id }
            app.selectedAgentId = next?.id
        }
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
