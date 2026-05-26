import SwiftUI

struct UsagePopoverView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let usage = store.usage {
                if let pct = usage.fiveHour {
                    UsageBar(label: "5h", percent: pct, resetAt: usage.fiveHourResetAt)
                }
                if let pct = usage.sevenDay {
                    UsageBar(label: "7d", percent: pct, resetAt: usage.sevenDayResetAt)
                }
                if let pct = usage.sevenDaySonnet {
                    SubQuotaRow(label: "Sonnet", percent: pct, resetAt: usage.sevenDaySonnetResetAt)
                }
                if let pct = usage.sevenDayOpus {
                    SubQuotaRow(label: "Opus", percent: pct, resetAt: usage.sevenDayOpusResetAt)
                }
                Text("Updated \(usage.fetchedTimestamp)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if let err = store.lastError {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 280, alignment: .leading)
    }

    private var header: some View {
        HStack {
            Text(store.usage?.planName ?? "Claude")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Refresh usage")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Quit widget")
        }
    }
}

private struct UsageBar: View {
    let label: String
    let percent: Int
    let resetAt: Date?

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 18, alignment: .leading)
            ProgressView(value: Double(percent), total: 100)
                .progressViewStyle(.linear)
                .tint(barColor)
            Text("\(percent)%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(barColor)
                .frame(width: 32, alignment: .trailing)
            Text(Self.resetText(resetAt))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 50, alignment: .trailing)
        }
    }

    private var barColor: Color {
        percent >= 90 ? .red : percent >= 70 ? .orange : .blue
    }

    static func resetText(_ date: Date?) -> String {
        guard let date else { return "" }
        let s = date.timeIntervalSinceNow
        if s <= 0 { return "now" }
        let h = Int(s / 3600)
        let m = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
        if h >= 24 { return "\(h / 24)d \(h % 24)h" }
        if h > 0   { return "\(h)h \(m)m" }
        return "\(m)m"
    }
}

private struct SubQuotaRow: View {
    let label: String
    let percent: Int
    let resetAt: Date?

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .frame(width: 50, alignment: .leading)
            ProgressView(value: Double(percent), total: 100)
                .progressViewStyle(.linear)
                .tint(.blue.opacity(0.4))
            Text("\(percent)%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.quaternary)
                .frame(width: 32, alignment: .trailing)
            Text(UsageBar.resetText(resetAt))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.quaternary)
                .frame(width: 50, alignment: .trailing)
        }
    }
}
