import Foundation
import Observation

/// Per-agent conversation state: renders a scrollable list of message rows,
/// streams new items from `agent_stream` events, and sends outbound messages.
///
/// Streaming model: when `turn_started` arrives we flip `isAgentWorking` on and
/// clear the "completed" flag; each subsequent `timeline` event carries one
/// full `TimelineItem` which we append as its own row. `turn_completed` /
/// `turn_failed` / `turn_canceled` flip us back to idle. No delta merging
/// needed — the daemon hands us finalized rows.
@MainActor
@Observable
final class ConversationViewModel {

    struct Row: Identifiable, Hashable {
        let id: String
        let kind: String          // "user", "assistant", "reasoning", "tool", "todo", "error", "other"
        let text: String
        let timestamp: String?
    }

    let agentId: String

    var rows: [Row] = []
    var isLoading: Bool = false
    var isAgentWorking: Bool = false
    var lastError: String? = nil
    var composerText: String = ""

    private let getClient: () -> DaemonClient?
    private var streamRowCounter: Int = 0

    init(agentId: String, getClient: @escaping () -> DaemonClient?) {
        self.agentId = agentId
        self.getClient = getClient
    }

    // MARK: - Loading

    func loadInitial() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let client = getClient() else { return }
            let payload = try await client.fetchTimeline(agentId: agentId)
            self.rows = payload.entries.map(rowFromEntry)
            self.lastError = nil
        } catch {
            self.lastError = error.localizedDescription
        }
    }

    // MARK: - Send

    func sendComposer() async {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard let client = getClient() else {
            self.lastError = "Not connected"
            return
        }
        composerText = ""

        // Optimistically append a user bubble so the UI feels instant. The
        // real row will come back via agent_stream `timeline` events.
        appendLocalUserRow(text: text)

        do {
            _ = try await client.sendMessage(agentId: agentId, text: text)
            self.lastError = nil
        } catch {
            self.lastError = "Send failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Stream ingestion

    func apply(streamEvent: AgentStreamEvent, seq: Int?, timestamp: String) {
        switch streamEvent {
        case .turnStarted:
            isAgentWorking = true
        case .turnCompleted, .turnFailed, .turnCanceled:
            isAgentWorking = false
        case .threadStarted:
            break
        case .timelineUpdated(let item):
            appendStreamedRow(item: item, seq: seq, timestamp: timestamp)
        case .permissionRequested:
            appendSystemRow(text: "[permission requested]", timestamp: timestamp)
        case .permissionResolved:
            break
        case .attentionRequired:
            break
        case .other:
            break
        }
    }

    // MARK: - Row helpers

    private func rowFromEntry(_ entry: TimelineEntry) -> Row {
        Row(
            id: "entry-\(entry.id)",
            kind: entry.item.displayKind,
            text: entry.item.displayText,
            timestamp: entry.timestamp
        )
    }

    private func appendStreamedRow(item: TimelineItem, seq: Int?, timestamp: String) {
        streamRowCounter += 1
        let id = seq.map { "seq-\($0)" } ?? "stream-\(streamRowCounter)"

        // Coalesce: if the last row has the same id (e.g. assistant_message
        // with same seq arriving twice), replace in place rather than appending.
        if let idx = rows.firstIndex(where: { $0.id == id }) {
            rows[idx] = Row(id: id, kind: item.displayKind, text: item.displayText, timestamp: timestamp)
        } else {
            rows.append(Row(id: id, kind: item.displayKind, text: item.displayText, timestamp: timestamp))
        }
    }

    private func appendLocalUserRow(text: String) {
        let id = "local-\(UUID().uuidString)"
        rows.append(Row(id: id, kind: "user", text: text, timestamp: ISO8601DateFormatter().string(from: Date())))
    }

    private func appendSystemRow(text: String, timestamp: String) {
        streamRowCounter += 1
        rows.append(Row(id: "sys-\(streamRowCounter)", kind: "system", text: text, timestamp: timestamp))
    }
}
