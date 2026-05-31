import SwiftUI

/// Thin SwiftUI shell. The main UI runs on AppKit (`AppKitRoot`: split + sidebar +
/// NSTableView transcript + composer); SwiftUI is kept only for the low-frequency
/// modal layer (Connect / Import / Settings sheets + toasts) and the window config.
struct ContentView: View {
    @Environment(AppViewModel.self) private var app
    @Environment(SettingsStore.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var notif = NotificationStore()
    @State private var showConnect = false
    @State private var settingsOpen = false

    var body: some View {
        @Bindable var app = app
        ZStack {
            AppKitRoot(
                app: app, settings: settings,
                onOpenSettings: { settingsOpen = true },
                onOpenConnect: { showConnect = true },
                onOpenFile: openFile,
                onOpenWorkspace: openWorkspace,
                notif: notif
            )
            ToastStack(store: notif, onOpen: { n in app.selectedAgentId = n.chatId; notif.markRead(n.id) })
                .allowsHitTesting(!notif.toasts.isEmpty)
        }
        .ignoresSafeArea()
        .background(WindowConfigurator())
        .preferredColorScheme(.light)
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

    private var currentCwd: String? {
        guard let id = app.selectedAgentId else { return nil }
        return (app.agents.first { $0.id == id } ?? app.archivedAgents.first { $0.id == id })?.cwd
    }
    private func openFile(_ raw: String) {
        guard let cwd = currentCwd else { return }
        openWindow(value: WorkspaceFilePreviewRouting.forceRoute(cwd: cwd, rawLocation: raw))
    }
    private func openWorkspace() {
        guard let cwd = currentCwd else { return }
        openWindow(value: WorkspaceFilePreviewRoute(cwd: cwd, path: "."))
    }
}
