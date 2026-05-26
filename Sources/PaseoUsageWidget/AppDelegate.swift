import AppKit
import SwiftUI
import Combine

/// The widget runs as a menu-bar accessory: a small status item that shows
/// the current 5h utilization at-a-glance ("5h 26%"), and reveals the full
/// PaseoMac-style usage panel when clicked.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let store = UsageStore()
    private var cancellables: Set<AnyCancellable> = []
    private var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status item lives in the menu bar at variable width — we size to
        // fit the title content (e.g. "5h 26%") rather than using a fixed
        // square so the percentage stays readable.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "—"
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 160)
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView(store: store)
        )

        // Sync the menu-bar title whenever the usage snapshot changes.
        store.$usage
            .receive(on: RunLoop.main)
            .sink { [weak self] usage in
                self?.updateStatusBarTitle(from: usage)
            }
            .store(in: &cancellables)

        // Initial fetch + periodic refresh. Every 60 seconds is plenty —
        // claude.ai usage rolls slowly and the network cost is trivial.
        Task { await store.refresh() }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await self.store.refresh() }
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            // Refresh on open so the panel never shows truly stale numbers.
            Task { await store.refresh() }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusBarTitle(from usage: ClaudeUsageData?) {
        guard let button = statusItem.button else { return }
        guard let usage else {
            button.title = "—"
            button.toolTip = "Claude usage unavailable"
            return
        }
        // Prefer 5h since that's the actively-rolling window. Show the
        // bigger of 5h vs 7d on the rare case 7d is dominant (>5h%) so
        // the user sees the binding constraint at a glance.
        let parts: [(String, Int)] = [
            ("5h", usage.fiveHour ?? 0),
            ("7d", usage.sevenDay ?? 0)
        ]
        let display = parts.max(by: { $0.1 < $1.1 }) ?? ("5h", 0)
        button.title = "\(display.0) \(display.1)%"
        button.toolTip = "Claude · 5h \(usage.fiveHour ?? 0)% · 7d \(usage.sevenDay ?? 0)% · updated \(usage.fetchedTimestamp)"
    }
}
