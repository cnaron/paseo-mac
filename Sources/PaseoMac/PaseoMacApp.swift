import SwiftUI

@main
struct PaseoMacApp: App {
    init() {
        if CommandLine.arguments.contains("--list-agents") {
            runSmokeTestAndExit()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}
