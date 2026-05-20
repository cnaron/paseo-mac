import Foundation

public protocol PlatformWakeNotifier: Sendable {
    func observe(handler: @escaping @Sendable () -> Void)
}

public struct NoOpWakeNotifier: PlatformWakeNotifier {
    public init() {}
    public func observe(handler: @escaping @Sendable () -> Void) {}
}
