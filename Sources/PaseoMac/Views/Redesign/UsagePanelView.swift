import SwiftUI
import AppKit

// MARK: - Sidebar usage panel (prototype `UsagePanel`)
//
// Claude quota bars (5h / 7d / Sonnet / Opus) + Codex / Gemini / Claude-Code
// version rows. Wired to AppViewModel. Hidden by the sidebar when there's no
// usage data at all.

struct UsagePanelView: View {
    @Environment(AppViewModel.self) private var app
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let u = app.usageData {
                HStack {
                    Text(u.planName).font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.text2)
                    Spacer()
                    IconButton(icon: "refresh", box: 24, glyph: 14, help: "刷新用量") {
                        Task { await app.fetchUsage() }
                    }
                }
                .padding(.bottom, 8)

                if let p = u.fiveHour { Bar(label: "5h window", pct: Double(p) / 100, reset: resetCountdown(u.fiveHourResetAt)) }
                if let p = u.sevenDay { Bar(label: "7d window", pct: Double(p) / 100, reset: resetCountdown(u.sevenDayResetAt)) }
                if let p = u.sevenDaySonnet { Bar(label: "7d · Sonnet", pct: Double(p) / 100, reset: nil) }
                if let p = u.sevenDayOpus { Bar(label: "7d · Opus", pct: Double(p) / 100, reset: nil) }

                Text("Updated \(u.fetchedTimestamp)")
                    .font(.system(size: 11)).foregroundStyle(DS.textFaint)
                    .padding(.top, 2).padding(.bottom, 8)
            }

            if let codex = app.codexSessionStats {
                LinkRow(provider: "codex", url: "https://chatgpt.com/codex/settings/usage") {
                    HStack(spacing: 0) {
                        Text("Codex · \(formatCost(codex.totalCostUsd)) · \(compactTokens(codex.totalTokens))")
                            .font(.system(size: 12)).foregroundStyle(DS.text2)
                        Spacer(minLength: 4)
                        if codex.activeAgentCount > 0 {
                            Text("\(codex.activeAgentCount) running").font(.system(size: 11)).foregroundStyle(DS.greenSoftTX)
                        }
                    }
                }
            }

            if app.providers.contains(where: { $0.provider == "gemini" && $0.status == "ready" }) {
                LinkRow(provider: "gemini", url: "https://aistudio.google.com/app/usage") {
                    Text("free tier · 60 RPM / 1000 RPD").font(.system(size: 12)).foregroundStyle(DS.text2).lineLimit(1)
                }
            }

            if let cur = app.claudeCodeCurrentVersion, cur != "unknown" {
                ClaudeCodeVersionRow(current: cur)
            }
        }
        .padding(.horizontal, 9).padding(.top, 10).padding(.bottom, 4)
        .padding(.top, 0)
        .overlay(alignment: .top) { Rectangle().fill(DS.divider).frame(height: 1).padding(.top, 10) }
        .padding(.top, 10)
    }

    private struct Bar: View {
        let label: String
        let pct: Double
        let reset: String?

        var body: some View {
            VStack(spacing: 4) {
                HStack {
                    Text(label).font(.system(size: 11.5)).foregroundStyle(DS.text2)
                    Spacer()
                    Text("\(Int(pct * 100))%\(reset.map { " · \($0)" } ?? "")")
                        .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(DS.text2)
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DS.dividerStrong)
                        Capsule().fill(color).frame(width: geo.size.width * min(max(pct, 0), 1))
                    }
                }
                .frame(height: 5)
            }
            .padding(.bottom, 9)
        }

        private var color: Color {
            if pct >= 0.9 { return DS.red }
            if pct >= 0.7 { return DS.orange }
            return DS.accentFallback
        }
    }

    private struct LinkRow<Content: View>: View {
        let provider: String
        let url: String?
        @ViewBuilder var content: () -> Content
        @State private var hover = false

        var body: some View {
            Button {
                if let url, let u = URL(string: url) { NSWorkspace.shared.open(u) }
            } label: {
                HStack(spacing: 8) {
                    ProviderGlyph(provider: provider, size: 14).frame(width: 14, height: 14)
                    content()
                    if url != nil {
                        DSIcon(name: "external", size: 11).foregroundStyle(DS.text3)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hover ? DS.hover : .clear, in: RoundedRectangle(cornerRadius: DS.R.row))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .disabled(url == nil)
        }
    }

    // Claude Code version row. When a newer version is available it becomes a
    // clickable button that triggers `updateClaudeCode()` (via the usage proxy's
    // claude-code-update endpoint); shows a spinner while updating; "· latest"
    // (inert) when up to date.
    private struct ClaudeCodeVersionRow: View {
        let current: String
        @Environment(AppViewModel.self) private var app
        @State private var hover = false

        private var canUpdate: Bool {
            app.claudeCodeUpdateAvailable
                && app.claudeCodeLatestVersion != nil
                && !app.isUpdatingClaudeCode
        }

        var body: some View {
            Button {
                guard canUpdate else { return }
                Task { await app.updateClaudeCode() }
            } label: {
                HStack(spacing: 8) {
                    ProviderGlyph(provider: "claude", size: 14).frame(width: 14, height: 14)
                    Text("Claude Code · v\(current)").font(.system(size: 12)).foregroundStyle(DS.text2)
                    Spacer(minLength: 4)
                    if app.isUpdatingClaudeCode {
                        ProgressView().controlSize(.mini)
                        Text("更新中…").font(.system(size: 11)).foregroundStyle(DS.text3)
                    } else if app.claudeCodeUpdateAvailable, let latest = app.claudeCodeLatestVersion {
                        Text("→ v\(latest)").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.orange)
                    } else {
                        Text("· latest").font(.system(size: 11)).foregroundStyle(DS.textFaint)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((canUpdate && hover) ? DS.hover : .clear, in: RoundedRectangle(cornerRadius: DS.R.row))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hover = $0 }
            .disabled(!canUpdate)
            .help(canUpdate ? "点击更新 Claude Code 到 v\(app.claudeCodeLatestVersion ?? "")" : "Claude Code 已是最新")
        }
    }
}

// MARK: - formatting helpers

func formatCost(_ cost: Double) -> String {
    if cost >= 10 { return String(format: "$%.2f", cost) }
    if cost < 0.01 && cost > 0 { return String(format: "$%.4f", cost) }
    return String(format: "$%.2f", cost)
}

func compactTokens(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
    return "\(n)"
}

extension DS {
    /// Fallback accent for places without the environment palette (sidebar bars
    /// read the user's accent in practice; this keeps a sane terracotta default).
    static let accentFallback = AccentPalette.terracotta.accent
}
