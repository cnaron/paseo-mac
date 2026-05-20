import SwiftUI
import PaseoCore

struct PreferencesView: View {
    @Environment(SettingsStore.self) private var settings
    @Environment(AppViewModel.self) private var app

    @AppStorage("paseomac.usageApiUrl")   private var usageApiUrl:   String = ""
    @AppStorage("paseomac.usageApiToken") private var usageApiToken: String = ""

    var body: some View {
        @Bindable var settings = settings
        TabView {
            // MARK: General tab
            Form {
                Section("Typography") {
                    Slider(
                        value: $settings.fontScale,
                        in: SettingsStore.fontScaleRange,
                        step: 0.05
                    ) {
                        Text("Font size")
                    } minimumValueLabel: {
                        Text("A").font(.caption)
                    } maximumValueLabel: {
                        Text("A").font(.title2)
                    }
                    HStack {
                        Text("Font scale")
                        Spacer()
                        Text(String(format: "%.2f×", settings.fontScale))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Slider(
                        value: $settings.paragraphLineSpacing,
                        in: SettingsStore.lineSpacingRange,
                        step: 0.5
                    ) {
                        Text("Line spacing")
                    }
                    HStack {
                        Text("Paragraph line spacing")
                        Spacer()
                        Text(String(format: "%.1f pt", settings.paragraphLineSpacing))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Section("Layout") {
                    Slider(
                        value: $settings.bubbleGap,
                        in: SettingsStore.bubbleGapRange,
                        step: 1
                    ) {
                        Text("Bubble gap")
                    }
                    HStack {
                        Text("Gap between bubbles")
                        Spacer()
                        Text(String(format: "%.0f pt", settings.bubbleGap))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }

                    Slider(
                        value: $settings.composerHeight,
                        in: SettingsStore.composerHeightRange,
                        step: 2
                    ) {
                        Text("Composer height")
                    }
                    HStack {
                        Text("Composer height")
                        Spacer()
                        Text(String(format: "%.0f pt", settings.composerHeight))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Section {
                    HStack {
                        Spacer()
                        Button("Reset to Defaults") {
                            settings.resetToDefaults()
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(8)
            .tabItem { Label("General", systemImage: "slider.horizontal.3") }

            // MARK: Integration tab
            Form {
                Section("Claude Usage") {
                    TextField("Endpoint URL", text: $usageApiUrl)
                        .font(.system(.body, design: .monospaced))
                    SecureField("Token", text: $usageApiToken)
                        .font(.system(.body, design: .monospaced))
                    Text("Point to a VPS endpoint that proxies the Anthropic usage API and returns JSON with five_hour/seven_day utilization. The sidebar quota panel appears only when configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Model Access") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Blocked models: \(app.blockedModels.count)")
                            if !app.blockedModels.isEmpty {
                                Text(app.blockedModels.sorted().joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        Spacer()
                        Button("Reset") { app.clearBlockedModels() }
                            .disabled(app.blockedModels.isEmpty)
                    }
                    Text("Models are auto-blocked when the daemon returns an 'Extra usage is required for 1M context' error. Enable extra usage at claude.ai/settings/usage and reset here to make them selectable again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .padding(8)
            .tabItem { Label("Integration", systemImage: "network") }
            // MARK: Usage tab
            StatsTabView(app: app)
                .tabItem { Label("Usage", systemImage: "chart.bar") }
        }
        .frame(minWidth: 520, minHeight: 420)
    }
}

private struct StatsTabView: View {
    let app: AppViewModel

    var body: some View {
        Group {
            if let stats = app.statsData {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            Text("Last computed: \(stats.lastComputedDate)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Refresh") { Task { await app.fetchStats() } }
                                .font(.caption)
                                .buttonStyle(.plain)
                                .foregroundStyle(.blue)
                        }

                        Divider()
                        Text("Recent Activity").font(.headline)

                        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
                            GridRow {
                                Text("Date").gridColumnAlignment(.leading)
                                Text("Sessions")
                                Text("Messages")
                                Text("Tool calls")
                                Text("Tokens")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                            ForEach(stats.daily.prefix(14)) { entry in
                                GridRow {
                                    Text(entry.displayDate).gridColumnAlignment(.leading)
                                    Text("\(entry.sessionCount)")
                                    Text("\(entry.messageCount)")
                                    Text("\(entry.toolCallCount)")
                                    Text(ClaudeStatsData.fmtTokens(entry.totalTokens))
                                }
                                .font(.caption.monospacedDigit())
                            }
                        }

                        Divider()
                        Text("Totals by Model").font(.headline)

                        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
                            GridRow {
                                Text("Model").gridColumnAlignment(.leading)
                                Text("Input")
                                Text("Output")
                                Text("Cache R")
                                Text("Cache W")
                                Text("API equiv.")
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                            ForEach(stats.modelUsage) { m in
                                GridRow {
                                    Text(m.displayName).gridColumnAlignment(.leading)
                                    Text(ClaudeStatsData.fmtTokens(m.inputTokens))
                                    Text(ClaudeStatsData.fmtTokens(m.outputTokens))
                                    Text(ClaudeStatsData.fmtTokens(m.cacheReadTokens))
                                    Text(ClaudeStatsData.fmtTokens(m.cacheWriteTokens))
                                    Text(ClaudeStatsData.fmtCost(m.apiEquivCostUSD))
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption.monospacedDigit())
                            }

                            let total = stats.modelUsage.reduce(0) { $0 + $1.apiEquivCostUSD }
                            GridRow {
                                Text("Total").gridColumnAlignment(.leading).fontWeight(.semibold)
                                Text("").gridCellColumns(4)
                                Text(ClaudeStatsData.fmtCost(total)).fontWeight(.semibold)
                            }
                            .font(.caption.monospacedDigit())
                        }

                        Text("API-equivalent cost — you pay a flat subscription. Cache reads are high because Claude Code re-reads the full conversation history from cache on every turn.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding()
                }
            } else {
                VStack(spacing: 10) {
                    Text("No stats data available.")
                        .foregroundStyle(.secondary)
                    Text("Configure the usage endpoint in Integration, then reconnect.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Button("Fetch Now") { Task { await app.fetchStats() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
