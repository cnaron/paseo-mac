import Foundation

/// File-based JSONL event logger. Writes one line per event to
/// `~/Library/Logs/PaseoMac/paseomac.log`. Rotates to `.log.1` when the
/// active file exceeds 5MB so total disk usage caps at ~10MB.
///
/// All writes go through a utility-QoS serial queue so the main thread never
/// blocks on disk I/O. The only persistent in-memory state is a single
/// FileHandle; no in-memory ring buffer.
///
/// Intended for post-hoc diagnosis ("show me what happened around 14:32") not
/// real-time monitoring. SSH-tail with:
///     ssh naron@100.112.136.122 'tail -f ~/Library/Logs/PaseoMac/paseomac.log'
final class EventLogger: @unchecked Sendable {
    static let shared = EventLogger()

    private let queue = DispatchQueue(label: "paseomac.logger", qos: .utility)
    private let url: URL
    private let rotatedURL: URL
    private let maxBytes: Int = 5 * 1024 * 1024
    private var handle: FileHandle?
    private let iso: ISO8601DateFormatter

    private init() {
        let fm = FileManager.default
        let logsDir = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/PaseoMac")
        try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.url = logsDir.appendingPathComponent("paseomac.log")
        self.rotatedURL = logsDir.appendingPathComponent("paseomac.log.1")
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.iso = iso
    }

    /// Lightweight enqueue. The fields dictionary is captured by value but
    /// rendering happens on the background queue, so the caller pays only for
    /// the dictionary allocation and the async hop.
    func log(_ area: String, _ event: String, _ fields: [String: Any] = [:]) {
        let ts = iso.string(from: Date())
        queue.async { [weak self] in
            self?.write(ts: ts, area: area, event: event, fields: fields)
        }
    }

    private func write(ts: String, area: String, event: String, fields: [String: Any]) {
        var rec: [String: Any] = ["t": ts, "area": area, "event": event]
        for (k, v) in fields { rec[k] = v }
        guard let data = try? JSONSerialization.data(
            withJSONObject: rec, options: [.sortedKeys]
        ) else { return }
        ensureHandle()
        guard let h = handle else { return }
        h.write(data)
        h.write(Data([0x0a]))
        if (try? h.offset()).map({ $0 > maxBytes }) ?? false {
            rotate()
        }
    }

    private func ensureHandle() {
        guard handle == nil else { return }
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: url, to: rotatedURL)
    }
}
