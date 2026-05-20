import Foundation

public protocol PlatformWakeNotifier: Sendable {
    func observe(handler: @escaping @Sendable () -> Void)
}

public struct NoOpWakeNotifier: PlatformWakeNotifier {
    public func observe(handler: @escaping @Sendable () -> Void) {}
}
