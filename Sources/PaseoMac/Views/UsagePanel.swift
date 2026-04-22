import SwiftUI
import Foundation

// MARK: - Data (shared with AppViewModel)

struct ClaudeUsageData {
    let planName: String
    let fiveHour: Int?
    let sevenDay: Int?
    let fiveHourResetAt: Date?
    let sevenDayResetAt: Date?
}

// MARK: - View

struct UsagePanel: View {
    let usage: ClaudeUsageData?
    var onRefresh: (() -> Void)? = nil

    var body: some View {
        if let usage {
            VStack(alignment: .leading, spacing: 5) {
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
                .frame(width: 30, alignment: .trailing)
        }
        .help(helpText)
    }

    private var barColor: Color {
        percent >= 90 ? .red : percent >= 70 ? .orange : .blue
    }

    private var helpText: String {
        guard let reset = resetAt else { return "" }
        let interval = reset.timeIntervalSinceNow
        if interval <= 0 { return "Resetting…" }
        let h = Int(interval / 3600)
        let m = Int(interval.truncatingRemainder(dividingBy: 3600) / 60)
        if h >= 24 { return "Resets in \(h / 24)d \(h % 24)h" }
        if h > 0   { return "Resets in \(h)h \(m)m" }
        return "Resets in \(m)m"
    }
}
