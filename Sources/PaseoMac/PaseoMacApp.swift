import SwiftUI

@main
struct PaseoMacApp: App {

    @State private var appModel: AppViewModel
    @State private var settings: SettingsStore

    init() {
        if CommandLine.arguments.contains("--list-agents") {
            runSmokeTestAndExit()
        }
        PendingImageAttachment.cleanOldCache()
        self._appModel = State(initialValue: AppViewModel())
        self._settings = State(initialValue: SettingsStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environment(settings)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Agents") {
                    Task { try? await appModel.refreshAgents() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                Button("Import Session…") {
                    Task { await appModel.openImportSheet() }
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
        }

        WindowGroup("Workspace Files", for: WorkspaceFilePreviewRoute.self) { routeBinding in
            if let route = routeBinding.wrappedValue {
                WorkspaceFilePreviewWindow(route: route)
                    .environment(appModel)
                    .environment(settings)
                    .frame(minWidth: 900, minHeight: 620)
            } else {
                ContentUnavailableView(
                    "No file selected",
                    systemImage: "doc",
                    description: Text("Open a file from a conversation link or the Files button.")
                )
                .frame(minWidth: 640, minHeight: 420)
            }
        }
        .windowResizability(.contentMinSize)

        Settings {
            PreferencesView()
                .environment(settings)
                .environment(appModel)
        }
    }
}
