import Foundation
import SwiftUI

public protocol PlatformFileReveal: Sendable {
    func revealFile(atPath path: String)
}

struct NoOpFileReveal: PlatformFileReveal {
    func revealFile(atPath path: String) {}
}

private struct PlatformFileRevealKey: EnvironmentKey {
    static let defaultValue: any PlatformFileReveal = NoOpFileReveal()
}

extension EnvironmentValues {
    public var platformFileReveal: any PlatformFileReveal {
        get { self[PlatformFileRevealKey.self] }
        set { self[PlatformFileRevealKey.self] = newValue }
    }
}
