import SwiftUI
import AppKit

// MARK: - AppKit shell entry
//
// The redesigned UI runs on an AppKit foundation (NSSplitViewController +
// NSTableView transcript) so scrolling / row lifecycle / reconnects are stable.
// The design is reused as SwiftUI NSHostingView islands. Three columns:
// sidebar | conversation | workspace panel (the last collapsible, design-docked).

struct AppKitRoot: NSViewControllerRepresentable {
    let app: AppViewModel
    let settings: SettingsStore
    let panelModel: WorkspacePanelModel
    var onOpenSettings: () -> Void = {}
    var onOpenConnect: () -> Void = {}
    let notif: NotificationStore

    func makeNSViewController(context: Context) -> RootSplitController {
        RootSplitController(app: app, settings: settings, notif: notif, panelModel: panelModel,
                            onOpenSettings: onOpenSettings, onOpenConnect: onOpenConnect)
    }

    func updateNSViewController(_ controller: RootSplitController, context: Context) {
        controller.refreshAppearance()
    }
}

// MARK: - Root split (sidebar | conversation | workspace panel)

final class RootSplitController: NSSplitViewController {
    let app: AppViewModel
    let settings: SettingsStore
    let notif: NotificationStore
    let panelModel: WorkspacePanelModel
    private let sidebarVC: HostingVC
    private let conversationVC: ConversationVC
    private let panelVC: HostingVC
    private var panelItem: NSSplitViewItem?
    private let panelWidth: CGFloat = 300

    init(app: AppViewModel, settings: SettingsStore, notif: NotificationStore, panelModel: WorkspacePanelModel,
         onOpenSettings: @escaping () -> Void, onOpenConnect: @escaping () -> Void) {
        self.app = app
        self.settings = settings
        self.notif = notif
        self.panelModel = panelModel
        self.sidebarVC = HostingVC {
            AnyView(
                SidebarView(onOpenSettings: onOpenSettings, onOpenConnect: onOpenConnect)
                    .environment(app).environment(settings).environment(\.accent, settings.accentPalette)
            )
        }
        self.conversationVC = ConversationVC(app: app, settings: settings, notif: notif, panelModel: panelModel)
        self.panelVC = HostingVC {
            AnyView(
                WorkspacePanelView(model: panelModel)
                    .environment(app).environment(settings).environment(\.accent, settings.accentPalette)
            )
        }
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.dividerStyle = .thin

        let sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.minimumThickness = DS.sidebarW
        sidebarItem.maximumThickness = DS.sidebarW
        sidebarItem.canCollapse = false

        let contentItem = NSSplitViewItem(viewController: conversationVC)
        contentItem.minimumThickness = 420
        contentItem.holdingPriority = .init(240)

        let panel = NSSplitViewItem(viewController: panelVC)
        panel.canCollapse = true
        panel.minimumThickness = panelWidth
        panel.maximumThickness = 760
        panel.isCollapsed = true  // always start collapsed; user opens via toggle
        panel.holdingPriority = .init(260)
        self.panelItem = panel

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
        addSplitViewItem(panel)

        observePanel()
    }

    private func observePanel() {
        withObservationTracking {
            _ = panelModel.isOpen
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.syncPanel(); self?.observePanel() }
        }
    }

    // Open/close the panel by resizing the window so the conversation column
    // width never changes — the panel is truly additive space.
    private func syncPanel() {
        guard let panelItem else { return }
        let open = panelModel.isOpen
        guard panelItem.isCollapsed == open else { return }  // already in target state

        if open {
            // Grow window first, then reveal panel (one layout pass → no transcript resize).
            resizeWindow(by: +panelWidth)
            panelItem.isCollapsed = false
        } else {
            // Collapse first, then shrink window.
            panelItem.isCollapsed = true
            resizeWindow(by: -panelWidth)
        }
    }

    private func resizeWindow(by delta: CGFloat) {
        guard let window = splitView.window else { return }
        var frame = window.frame
        if delta > 0 {
            frame.size.width += delta
            if let screen = window.screen ?? NSScreen.main {
                let sf = screen.visibleFrame
                frame.size.width = min(frame.size.width, sf.width)
                frame.origin.x = max(sf.origin.x, min(frame.origin.x, sf.maxX - frame.size.width))
            }
        } else {
            frame.size.width = max(frame.size.width + delta, 700)
        }
        window.setFrame(frame, display: true)
    }

    func refreshAppearance() {
        conversationVC.refreshIslands()
        sidebarVC.view.needsLayout = true
    }
}

// MARK: - Generic SwiftUI-island hosting controller

final class HostingVC: NSViewController {
    private var make: () -> AnyView
    private var hosting: NSHostingView<AnyView>!

    init(make: @escaping () -> AnyView) {
        self.make = make
        super.init(nibName: nil, bundle: nil)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        hosting = NSHostingView(rootView: make())
        hosting.translatesAutoresizingMaskIntoConstraints = true
        hosting.autoresizingMask = [.width, .height]
        view = hosting
    }

    func update(_ newMake: @escaping () -> AnyView) {
        self.make = newMake
        if isViewLoaded { hosting.rootView = make() }
    }
}
