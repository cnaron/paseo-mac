import Foundation
import UniformTypeIdentifiers
import SwiftUI

public protocol PlatformAttachmentOpener: Sendable {
    func open(allowedTypes: [UTType], allowsMultiple: Bool, onFilesSelected: @escaping @Sendable ([URL]) -> Void)
}

struct NoOpAttachmentOpener: PlatformAttachmentOpener {
    func open(allowedTypes: [UTType], allowsMultiple: Bool, onFilesSelected: @escaping @Sendable ([URL]) -> Void) {}
}

private struct PlatformAttachmentOpenerKey: EnvironmentKey {
    static let defaultValue: any PlatformAttachmentOpener = NoOpAttachmentOpener()
}

extension EnvironmentValues {
    public var platformAttachmentOpener: any PlatformAttachmentOpener {
        get { self[PlatformAttachmentOpenerKey.self] }
        set { self[PlatformAttachmentOpenerKey.self] = newValue }
    }
}
