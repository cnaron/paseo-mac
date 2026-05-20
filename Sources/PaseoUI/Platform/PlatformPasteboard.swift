import Foundation

public protocol PlatformPasteboard: Sendable {
    func copyString(_ s: String)
}

struct NoOpPasteboard: PlatformPasteboard {
    func copyString(_ s: String) {}
}

import SwiftUI

private struct PlatformPasteboardKey: EnvironmentKey {
    static let defaultValue: any PlatformPasteboard = NoOpPasteboard()
}

extension EnvironmentValues {
    public var platformPasteboard: any PlatformPasteboard {
        get { self[PlatformPasteboardKey.self] }
        set { self[PlatformPasteboardKey.self] = newValue }
    }
}
