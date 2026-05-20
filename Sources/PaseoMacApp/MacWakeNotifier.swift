import AppKit
import Foundation

struct MacWakeNotifier: PlatformWakeNotifier {
    func observe(handler: @escaping @Sendable () -> Void) {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in handler() }
    }
}
