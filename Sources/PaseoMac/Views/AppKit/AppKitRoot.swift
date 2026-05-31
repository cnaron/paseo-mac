import SwiftUI
import AppKit

// MARK: - AppKit shell entry
//
// The redesigned UI runs on an AppKit foundation (NSSplitViewController +
// NSTableView transcript) so scrolling, row lifecycle and reconnects are stable
// — the SwiftUI List/ScrollView re-evaluation that caused the instability is
// gone. The design itself is reused as SwiftUI `NSHostingView` islands inside
// the AppKit cells/panes (brief §9). SwiftUI is kept only for the thin modal
// layer (Connect / Import / Settings sheets + toasts) in `ContentView`.

struct AppKitRoot: NSViewControllerRepresentable {
    let app: AppViewModel
    let settings: SettingsStore
    var onOpenSettings: () -> Void = {}
    var onOpenConnect: () -> Void = {}
    var onOpenFile: (String) -> Void = { _ in }
    var onOpenWorkspace: () -> Void = {}
    let notif: NotificationStore

    func makeNSViewController(context: Context) -> RootSplitController {
        RootSplitController(app: app, settings: settings, notif: notif,
                            onOpenSettings: onOpenSettings, onOpenConnect: onOpenConnect,
                            onOpenFile: onOpenFile, onOpenWorkspace: onOpenWorkspace)
    }

    func updateNSViewController(_ controller: RootSplitController, context: Context) {
        controller.refreshAppearance()
    }
}

// MARK: - Root split (sidebar | conversation)

final class RootSplitController: NSSplitViewController {
    let app: AppViewModel
    let settings: SettingsStore
    let notif: NotificationStore
    private let sidebarVC: HostingVC
    private let conversationVC: ConversationVC

    init(app: AppViewModel, settings: SettingsStore, notif: NotificationStore,
         onOpenSettings: @escaping () -> Void, onOpenConnect: @escaping () -> Void,
         onOpenFile: @escaping (String) -> Void, onOpenWorkspace: @escaping () -> Void) {
        self.app = app
        self.settings = settings
        self.notif = notif
        // Sidebar: the existing SwiftUI SidebarView as a hosted island (stable;
        // it isn't the source of the transcript instability).
        self.sidebarVC = HostingVC {
            AnyView(
                SidebarView(onOpenSettings: onOpenSettings, onOpenConnect: onOpenConnect)
                    .environment(app)
                    .environment(settings)
                    .environment(\.accent, settings.accentPalette)
            )
        }
        self.conversationVC = ConversationVC(
            app: app, settings: settings, notif: notif,
            onOpenFile: onOpenFile, onOpenWorkspace: onOpenWorkspace
        )
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
        sidebarItem.holdingPriority = .init(260)

        let contentItem = NSSplitViewItem(viewController: conversationVC)
        contentItem.minimumThickness = 480

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

    /// Replace the hosted SwiftUI tree (e.g. when the active agent or accent changes).
    func update(_ newMake: @escaping () -> AnyView) {
        self.make = newMake
        if isViewLoaded { hosting.rootView = make() }
    }
}
