import SwiftUI

@main
struct PaseoMacApp: App {

    @State private var appModel: AppViewModel
    @State private var settings: SettingsStore

    init() {
        if CommandLine.arguments.contains("--list-agents") {
            runSmokeTestAndExit()
        }
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
            }
        }

        Settings {
            PreferencesView()
                .environment(settings)
        }
    }
}
