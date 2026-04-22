import SwiftUI
import Foundation

// MARK: - Data (shared with AppViewModel)

struct ClaudeUsageData {
    let planName: String
    let fiveHour: Int?
    let sevenDay: Int?
    let fiveHourResetAt: Date?
    let sevenDayResetAt: Date?
    let sevenDaySonnet: Int?
    let sevenDaySonnetResetAt: Date?
    let sevenDayOpus: Int?
    let sevenDayOpusResetAt: Date?
    let fetchedAt: Date

    var fetchedTimestamp: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: fetchedAt)
    }
}

// MARK: - View

struct UsagePanel: View {
    let usage: ClaudeUsageData?
    var onRefresh: (() -> Void)? = nil

    var body: some View {
        if let usage {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(usage.planName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button { onRefresh?() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh usage")
                }
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
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
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
                .frame(width: 14, alignment: .leading)
            ProgressView(value: Double(percent), total: 100)
                .progressViewStyle(.linear)
                .tint(barColor)
            Text("\(percent)%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(barColor)
                .frame(width: 28, alignment: .trailing)
            Text(Self.resetText(resetAt))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 42, alignment: .trailing)
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
                .frame(width: 40, alignment: .leading)
            ProgressView(value: Double(percent), total: 100)
                .progressViewStyle(.linear)
                .tint(.blue.opacity(0.4))
            Text("\(percent)%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.quaternary)
                .frame(width: 28, alignment: .trailing)
            Text(UsageBar.resetText(resetAt))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.quaternary)
                .frame(width: 42, alignment: .trailing)
        }
    }
}
