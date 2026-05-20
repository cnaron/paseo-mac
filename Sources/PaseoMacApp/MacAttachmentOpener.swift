import AppKit
import UniformTypeIdentifiers

struct MacAttachmentOpener: PlatformAttachmentOpener {
    func open(allowedTypes: [UTType], allowsMultiple: Bool, onFilesSelected: @escaping @Sendable ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = allowsMultiple
        panel.canChooseDirectories = false
        panel.allowedContentTypes = allowedTypes
        panel.begin { response in
            guard response == .OK else { return }
            onFilesSelected(panel.urls)
        }
    }
}
