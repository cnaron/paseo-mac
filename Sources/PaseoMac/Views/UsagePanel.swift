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

/// Per-session Codex aggregate. ChatGPT/Codex doesn't expose quota %
/// publicly, so we surface what we actually know: cumulative tokens and
/// USD across all Codex-backed agents the user has open right now.
struct CodexSessionStats {
    let totalCostUsd: Double
    let totalTokens: Int
    let agentCount: Int
    let activeAgentCount: Int
}

// MARK: - View

struct UsagePanel: View {
    let usage: ClaudeUsageData?
    var onRefresh: (() -> Void)? = nil
    var currentVersion: String? = nil
    var latestVersion: String? = nil
    var isCheckingVersion: Bool = false
    var isUpdating: Bool = false
    var onCheckVersion: (() -> Void)? = nil
    var onUpdate: (() -> Void)? = nil
    var hasGemini: Bool = false
    var hasCodex: Bool = false
    var codexStats: CodexSessionStats? = nil

    private var updateAvailable: Bool {
        guard let current = currentVersion, let latest = latestVersion,
              !current.isEmpty, current != "unknown" else { return false }
        return latest != current
    }

    var body: some View {
        VStack(spacing: 0) {
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
            if hasCodex {
                if usage != nil { Divider() }
                CodexUsageRow(stats: codexStats)
            }
            if hasGemini {
                if usage != nil || hasCodex { Divider() }
                GeminiUsageRow()
            }
            if currentVersion != nil || latestVersion != nil {
                if usage != nil || hasCodex || hasGemini { Divider() }
                ClaudeCodeVersionRow(
                    currentVersion: currentVersion,
                    latestVersion: latestVersion,
                    isChecking: isCheckingVersion,
                    isUpdating: isUpdating,
                    updateAvailable: updateAvailable,
                    onCheck: onCheckVersion,
                    onUpdate: onUpdate
                )
            }
        }
    }
}

// MARK: - Codex session row

/// Codex / ChatGPT plans don't expose a public quota endpoint the way
/// claude.ai does, so we show what we actually have: an aggregate of
/// the Codex agents in this session. Clicking opens the ChatGPT Codex
/// settings page so the user can see their real subscription state.
private struct CodexUsageRow: View {
    let stats: CodexSessionStats?

    var body: some View {
        Button {
            if let url = URL(string: "https://chatgpt.com/codex/settings/usage") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: "terminal.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Codex")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let s = stats, s.agentCount > 0 {
                    HStack(spacing: 6) {
                        Text(Self.formatCost(s.totalCostUsd))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.quaternary)
                        Text(Self.formatTokens(s.totalTokens))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                        if s.activeAgentCount > 0 {
                            Text("·")
                                .font(.caption2)
                                .foregroundStyle(.quaternary)
                            Text("\(s.activeAgentCount) running")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    Text("ChatGPT plan · click to view usage")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open ChatGPT Codex usage page")
    }

    private static func formatCost(_ usd: Double) -> String {
        if usd >= 1.0 {
            return String(format: "$%.2f", usd)
        }
        if usd >= 0.01 {
            return String(format: "$%.3f", usd)
        }
        if usd > 0 {
            return String(format: "$%.4f", usd)
        }
        return "$0"
    }

    private static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 {
            return String(format: "%.1fM tok", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fk tok", Double(count) / 1_000)
        }
        return "\(count) tok"
    }
}

// MARK: - Gemini usage link row

private struct GeminiUsageRow: View {
    var body: some View {
        Button {
            if let url = URL(string: "https://aistudio.google.com/app/usage") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "g.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("Gemini")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("· free tier: 60 RPM / 1000 RPD")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Google AI Studio usage page")
    }
}

// MARK: - Claude Code version row

private struct ClaudeCodeVersionRow: View {
    let currentVersion: String?
    let latestVersion: String?
    let isChecking: Bool
    let isUpdating: Bool
    let updateAvailable: Bool
    var onCheck: (() -> Void)? = nil
    var onUpdate: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text("Claude Code")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if isChecking {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else {
                    Button { onCheck?() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Check for Claude Code updates")
                }
            }
            HStack(spacing: 4) {
                if let current = currentVersion {
                    Text("v\(current)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(updateAvailable ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                } else {
                    Text("—")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
                if updateAvailable, let latest = latestVersion {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text("v\(latest)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.green)
                    Spacer()
                    if isUpdating {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    } else {
                        Button("Update") { onUpdate?() }
                            .font(.caption2.weight(.medium))
                            .buttonStyle(.plain)
                            .foregroundStyle(.green)
                    }
                } else if !updateAvailable, latestVersion != nil, currentVersion != nil {
                    Text("· latest")
                        .font(.caption2)
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
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
