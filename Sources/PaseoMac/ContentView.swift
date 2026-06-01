import SwiftUI

/// Thin SwiftUI shell. The main UI runs on AppKit (`AppKitRoot`: split + sidebar +
/// NSTableView transcript + composer + docked workspace panel); SwiftUI is kept
/// only for the low-frequency modal layer (Connect / Import / Settings + toasts).
struct ContentView: View {
    @Environment(AppViewModel.self) private var app
    @Environment(SettingsStore.self) private var settings
    @State private var notif = NotificationStore()
    @State private var panelModel = WorkspacePanelModel()
    @State private var showConnect = false
    @State private var settingsOpen = false

    var body: some View {
        @Bindable var app = app
        ZStack {
            AppKitRoot(
                app: app, settings: settings, panelModel: panelModel,
                onOpenSettings: { settingsOpen = true },
                onOpenConnect: { showConnect = true },
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
}
