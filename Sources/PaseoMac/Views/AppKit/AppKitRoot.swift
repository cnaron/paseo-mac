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

        addSplitViewItem(sidebarItem)
        addSplitViewItem(contentItem)
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
