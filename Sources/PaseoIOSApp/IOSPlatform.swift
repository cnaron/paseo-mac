import UIKit
import UniformTypeIdentifiers
import PaseoCore
import PaseoUI

// MARK: - Pasteboard
struct IOSPasteboard: PlatformPasteboard {
    func copyString(_ s: String) {
        UIPasteboard.general.string = s
    }
}

// MARK: - Wake notifier (iOS foreground notification)
final class IOSWakeNotifier: PlatformWakeNotifier, @unchecked Sendable {
    func observe(handler: @escaping @Sendable () -> Void) {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in handler() }
    }
}

// MARK: - Attachment opener (document picker — present from root VC)
struct IOSAttachmentOpener: PlatformAttachmentOpener {
    func open(allowedTypes: [UTType], allowsMultiple: Bool, onFilesSelected: @escaping @Sendable ([URL]) -> Void) {
        // For Phase 1 MVP: no-op. Phase 2 will add UIDocumentPickerViewController.
    }
}

// MARK: - File reveal (no Finder on iOS)
struct IOSNoOpFileReveal: PlatformFileReveal {
    func revealFile(atPath path: String) {}
}
