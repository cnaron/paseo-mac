import SwiftUI

@main
struct PaseoMacApp: App {

    @State private var appModel: AppViewModel

    init() {
        if CommandLine.arguments.contains("--list-agents") {
            runSmokeTestAndExit()
        }
        self._appModel = State(initialValue: AppViewModel())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
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
    }
}
