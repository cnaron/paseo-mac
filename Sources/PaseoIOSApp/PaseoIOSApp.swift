import SwiftUI
import PaseoCore
import PaseoUI

@main
struct PaseoIOSApp: App {
    @State private var appModel: AppViewModel
    @State private var settings: SettingsStore

    init() {
        PendingImageAttachment.cleanOldCache()
        let vm = AppViewModel()
        vm.setWakeNotifier(IOSWakeNotifier())
        self._appModel = State(initialValue: vm)
        self._settings = State(initialValue: SettingsStore())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appModel)
                .environment(settings)
                .environment(\.platformPasteboard, IOSPasteboard())
                .environment(\.platformAttachmentOpener, IOSAttachmentOpener())
                .environment(\.platformFileReveal, IOSNoOpFileReveal())
        }
    }
}
