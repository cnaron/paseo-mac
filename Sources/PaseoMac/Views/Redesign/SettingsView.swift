import SwiftUI

// MARK: - Preferences modal (prototype `SettingsModal`)
//
// 通用 / 外观 / 用量 / 连接 / 模型. 外观 is fully live (drives the app accent,
// body size, density via SettingsStore); the rest display real daemon/usage
// state where available.

struct SettingsView: View {
    var onOpenConnect: () -> Void = {}
    var onClose: () -> Void = {}
    @State private var section = "general"

    private let sections: [(id: String, label: String, icon: String)] = [
        ("general", "通用", "gear"),
        ("appearance", "外观", "palette"),
        ("usage", "用量统计", "chart"),
        ("connection", "连接", "monitor"),
        ("providers", "模型", "sparkle"),
    ]

    var body: some View {
        HStack(spacing: 0) {
            // nav
            VStack(alignment: .leading, spacing: 2) {
                Text("偏好设置").font(.system(size: 12, weight: .bold)).foregroundStyle(DS.text3)
                    .padding(.horizontal, 10).padding(.bottom, 8).padding(.top, 2)
                ForEach(sections, id: \.id) { s in
                    let on = section == s.id
                    Button { section = s.id } label: {
                        HStack(spacing: 11) {
                            DSIcon(name: s.icon, size: 17).foregroundStyle(on ? .white : DS.text2)
                            Text(s.label).font(.system(size: 13.5)).foregroundStyle(on ? .white : DS.text)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(on ? AccentPalette.named(currentAccent).accent : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .frame(width: 190)
            .padding(14)
            .background(DS.sidebarBG)
            .overlay(alignment: .trailing) { Rectangle().fill(DS.divider).frame(width: 1) }

            // body
            VStack(spacing: 0) {
                HStack {
                    Text(sections.first { $0.id == section }?.label ?? "")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                    Spacer()
                    IconButton(icon: "x", glyph: 18, action: onClose)
                }
                .padding(.leading, 20).padding(.trailing, 14).frame(height: 50)
                .overlay(alignment: .bottom) { Rectangle().fill(DS.divider).frame(height: 1) }
                ScrollView {
                    Group {
                        switch section {
                        case "general": GeneralSection()
                        case "appearance": AppearanceSection()
                        case "usage": UsageStatsSection()
                        case "connection": ConnectionSection(onOpenConnect: onOpenConnect)
                        default: ProvidersSection()
                        }
                    }
                    .padding(.horizontal, 22).padding(.vertical, 16)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 720, height: 524)
        .background(DS.contentBG)
    }

    @Environment(SettingsStore.self) private var settings
    private var currentAccent: String { settings.accentHex }
}

// MARK: - section row scaffold

private struct SetRow<Trailing: View>: View {
    let label: String
    var sub: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.system(size: 13.5)).foregroundStyle(DS.text)
                if let sub { Text(sub).font(.system(size: 12)).foregroundStyle(DS.text3).frame(maxWidth: 330, alignment: .leading) }
            }
            Spacer()
            trailing()
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) { Rectangle().fill(DS.divider).frame(height: 1) }
    }
}

private struct GroupTitle: View {
    let text: String
    var body: some View { Text(text).font(.system(size: 11, weight: .bold)).foregroundStyle(DS.text3).textCase(.uppercase).padding(.bottom, 4) }
}

// MARK: - 外观 (live)

private struct AppearanceSection: View {
    @Environment(SettingsStore.self) private var settings
    var body: some View {
        @Bindable var settings = settings
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                GroupTitle(text: "主题")
                SetRow(label: "强调色", sub: "用于选中、链接、发送按钮等。") {
                    HStack(spacing: 11) {
                        ForEach(AccentPalette.all, id: \.hex) { p in
                            Button { settings.accentHex = p.hex } label: {
                                Circle().fill(p.accent).frame(width: 26, height: 26)
                                    .overlay { if settings.accentHex == p.hex { DSIcon(name: "check-sm", size: 13, weight: .bold).foregroundStyle(.white) } }
                                    .overlay(Circle().strokeBorder(settings.accentHex == p.hex ? p.accent : Color.black.opacity(0.1), lineWidth: settings.accentHex == p.hex ? 2 : 1).padding(settings.accentHex == p.hex ? -3 : 0))
                            }.buttonStyle(.plain)
                        }
                    }
                }
                SetRow(label: "外观模式", sub: "深色模式即将推出。") {
                    Seg2(options: ["light"], label: { _ in "浅色" }, selection: .constant("light"))
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                GroupTitle(text: "文字与密度")
                SetRow(label: "字体大小", sub: "对话正文字号 · \(String(format: "%.1f", settings.fontSize))px") {
                    HStack(spacing: 10) {
                        Text("A").font(.system(size: 12)).foregroundStyle(DS.text3)
                        Slider(value: $settings.fontSize, in: SettingsStore.fontSizeRange, step: 0.5).frame(width: 170).tint(settings.accentPalette.accent)
                        Text("A").font(.system(size: 17)).foregroundStyle(DS.text3)
                    }
                }
                SetRow(label: "行间距", sub: "正文每行之间的留白 · \(String(format: "%.1f", settings.paragraphLineSpacing))pt") {
                    HStack(spacing: 10) {
                        Text("密").font(.system(size: 12)).foregroundStyle(DS.text3)
                        Slider(value: $settings.paragraphLineSpacing, in: SettingsStore.lineSpacingRange, step: 0.5).frame(width: 170).tint(settings.accentPalette.accent)
                        Text("疏").font(.system(size: 12)).foregroundStyle(DS.text3)
                    }
                }
                SetRow(label: "消息密度", sub: "消息之间的留白。") {
                    Seg2(options: ["spacious", "compact"], label: { $0 == "spacious" ? "宽松" : "紧凑" }, selection: $settings.density)
                }
            }
        }
    }
}

// MARK: - 通用

private struct GeneralSection: View {
    @State private var launch = false
    @State private var keepAwake = true
    @State private var telemetry = false
    @State private var sendKey = "enter"
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                GroupTitle(text: "通用")
                SetRow(label: "开机自动启动") { DSSwitch(isOn: $launch) }
                SetRow(label: "运行任务时保持唤醒") { DSSwitch(isOn: $keepAwake) }
                SetRow(label: "发送匿名使用统计") { DSSwitch(isOn: $telemetry) }
            }
            VStack(alignment: .leading, spacing: 0) {
                GroupTitle(text: "对话")
                SetRow(label: "发送快捷键") {
                    Seg2(options: ["enter", "cmd"], label: { $0 == "enter" ? "Enter" : "⌘ Enter" }, selection: $sendKey)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                GroupTitle(text: "关于")
                SetRow(label: "版本") {
                    Text(appVersionString).font(DS.mono(12.5)).foregroundStyle(DS.text2)
                }
            }
        }
    }

    private var appVersionString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }
}

// MARK: - 用量

private struct UsageStatsSection: View {
    @Environment(AppViewModel.self) private var app
    @State private var period: UsagePeriod = .all
    private let colors: [Color] = [Color(hex: 0xD97757), Color(hex: 0xE0A33E), Color(hex: 0x10A37F), Color(hex: 0x4285F4)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if let s = remoteStats {
                    Text("长期统计 · \(s.lastComputedDate)").font(.system(size: 12)).foregroundStyle(DS.text3)
                } else if !localUsage.isEmpty {
                    Text("\(period.label) · 当前 daemon 会话 · API 等价估算").font(.system(size: 12)).foregroundStyle(DS.text3)
                }
                Spacer()
                Button("刷新") {
                    Task {
                        await app.fetchStats()
                        try? await app.refreshAgents()
                    }
                }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(AccentPalette.terracotta.accent)
            }
            periodPicker
            if let s = remoteStats {
                let totalTokens = s.modelUsage.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheWriteTokens }
                let totalCost = s.modelUsage.reduce(0.0) { $0 + $1.apiEquivCostUSD }
                HStack(spacing: 12) {
                    statCard("TOKEN", compactTokens(totalTokens))
                    statCard("API 等价估算（USD）", formatCost(totalCost))
                }
                GroupTitle(text: "按模型").padding(.top, 4)
                ForEach(Array(s.modelUsage.enumerated()), id: \.element.id) { i, m in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(colors[i % colors.count]).frame(width: 11, height: 11)
                        Text(m.displayName).font(DS.mono(12.5)).foregroundStyle(DS.text)
                        Spacer()
                        Text(compactTokens(m.inputTokens + m.outputTokens + m.cacheReadTokens + m.cacheWriteTokens))
                            .font(.system(size: 12.5, weight: .semibold)).monospacedDigit().foregroundStyle(DS.text2)
                        Text("· $\(String(format: "%.2f", m.apiEquivCostUSD))").font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.text3)
                    }
                    .padding(.vertical, 6)
                }
            } else if !localUsage.isEmpty {
                HStack(spacing: 12) {
                    statCard("TOKEN", compactTokens(localUsage.reduce(0) { $0 + $1.totalTokens }))
                    statCard("API 等价估算（USD）", formatCost(localUsage.reduce(0) { $0 + $1.apiEquivCostUSD }))
                }
                Text("长期统计端点不可用时，使用 daemon 返回的各会话 token 快照。费用按对应模型的标准 API 单价估算，不代表订阅账单。")
                    .font(.system(size: 12)).foregroundStyle(DS.text3).fixedSize(horizontal: false, vertical: true)
                GroupTitle(text: "按模型").padding(.top, 4)
                ForEach(Array(localUsage.enumerated()), id: \.element.id) { i, row in
                    HStack(spacing: 10) {
                        RoundedRectangle(cornerRadius: 3).fill(colors[i % colors.count]).frame(width: 11, height: 11)
                        Text(row.label).font(DS.mono(12.5)).foregroundStyle(DS.text)
                        Spacer()
                        Text(compactTokens(row.totalTokens))
                            .font(.system(size: 12.5, weight: .semibold)).monospacedDigit().foregroundStyle(DS.text2)
                        Text("· \(formatCost(row.apiEquivCostUSD))").font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.text3)
                    }
                    .padding(.vertical, 6)
                    .help(row.tooltip)
                }
            } else {
                VStack(spacing: 8) {
                    Text("暂无可汇总的 token 数据").font(.system(size: 13)).foregroundStyle(DS.text3)
                    Text("完成一次对话后即可显示当前会话的 token 与 API 等价估算。").font(.system(size: 12)).foregroundStyle(DS.textFaint)
                    Button("立即获取") {
                        Task {
                            await app.fetchStats()
                            try? await app.refreshAgents()
                        }
                    }
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            }
        }
        .task {
            await app.fetchStats()
            try? await app.refreshAgents()
        }
    }

    private var periodPicker: some View {
        HStack(spacing: 4) {
            ForEach(UsagePeriod.allCases) { item in
                Button {
                    period = item
                } label: {
                    Text(item.label)
                        .font(.system(size: 12.5, weight: period == item ? .semibold : .regular))
                        .foregroundStyle(period == item ? DS.text : DS.text3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(period == item ? DS.contentBG : .clear, in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(DS.hover, in: RoundedRectangle(cornerRadius: 9))
    }

    private var remoteStats: ClaudeStatsData? {
        guard period == .all, let stats = app.statsData, !stats.modelUsage.isEmpty else { return nil }
        return stats
    }

    private func statCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DS.text3)
            Text(value).font(.system(size: 30, weight: .bold)).monospacedDigit().foregroundStyle(DS.text)
        }
        .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xFBFBFA), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DS.divider, lineWidth: 1))
    }

    private var localUsage: [LocalUsageRow] {
        var rows: [String: LocalUsageRow] = [:]
        var seen = Set<String>()
        for agent in app.agents + app.archivedAgents where seen.insert(agent.id).inserted {
            guard period.includes(parseISODate(agent.updatedAt)) else { continue }
            guard let usage = agent.lastUsage else { continue }
            let provider = agent.provider ?? "unknown"
            let model = agent.model ?? provider
            let key = "\(provider)|\(model)"
            var row = rows[key] ?? LocalUsageRow(id: key, label: "\(provider.capitalized) · \(prettyModel(model))")
            row.inputTokens += usage.inputTokens ?? 0
            row.cachedInputTokens += usage.cachedInputTokens ?? 0
            row.outputTokens += usage.outputTokens ?? 0
            row.apiEquivCostUSD += estimateAPIEquivCost(provider: provider, model: model, usage: usage)
            rows[key] = row
        }
        return rows.values
            .filter { $0.totalTokens > 0 || $0.apiEquivCostUSD > 0 }
            .sorted { $0.apiEquivCostUSD == $1.apiEquivCostUSD ? $0.totalTokens > $1.totalTokens : $0.apiEquivCostUSD > $1.apiEquivCostUSD }
    }

    private func estimateAPIEquivCost(provider: String, model: String, usage: AgentUsage) -> Double {
        if let reported = usage.totalCostUsd, reported > 0 { return reported }
        guard let price = apiPrice(provider: provider, model: model) else { return 0 }
        return Double(usage.inputTokens ?? 0) / 1_000_000 * price.input
            + Double(usage.cachedInputTokens ?? 0) / 1_000_000 * price.cachedInput
            + Double(usage.outputTokens ?? 0) / 1_000_000 * price.output
    }

    private func apiPrice(provider: String, model: String) -> (input: Double, cachedInput: Double, output: Double)? {
        let m = model.lowercased()
        if provider == "codex" {
            if m.contains("5.5") { return (5, 0.5, 30) }
            if m.contains("5.4") && m.contains("mini") { return (0.75, 0.075, 4.5) }
            if m.contains("5.4") { return (2.5, 0.25, 15) }
            if m.contains("5.2") { return (1.75, 0.175, 14) }
            if m.contains("5.1") || m.contains("gpt-5") { return (1.25, 0.125, 10) }
        }
        if provider == "claude" {
            if m.contains("opus") { return (5, 0.5, 25) }
            if m.contains("haiku") { return (1, 0.1, 5) }
            if m.contains("sonnet") { return (3, 0.3, 15) }
        }
        return nil
    }

    private enum UsagePeriod: String, CaseIterable, Identifiable {
        case day
        case week
        case month
        case all

        var id: String { rawValue }
        var label: String {
            switch self {
            case .day: return "日"
            case .week: return "周"
            case .month: return "月"
            case .all: return "总量"
            }
        }

        func includes(_ date: Date?) -> Bool {
            guard self != .all else { return true }
            guard let date else { return false }
            let calendar = Calendar.current
            switch self {
            case .day:
                return calendar.isDateInToday(date)
            case .week:
                return calendar.dateInterval(of: .weekOfYear, for: Date())?.contains(date) == true
            case .month:
                return calendar.dateInterval(of: .month, for: Date())?.contains(date) == true
            case .all:
                return true
            }
        }
    }

    private struct LocalUsageRow: Identifiable {
        let id: String
        let label: String
        var inputTokens = 0
        var cachedInputTokens = 0
        var outputTokens = 0
        var apiEquivCostUSD = 0.0

        var totalTokens: Int { inputTokens + cachedInputTokens + outputTokens }
        var tooltip: String {
            "Input: \(inputTokens.formatted())\nCached: \(cachedInputTokens.formatted())\nOutput: \(outputTokens.formatted())"
        }
    }
}

// MARK: - 连接

private struct ConnectionSection: View {
    @Environment(AppViewModel.self) private var app
    var onOpenConnect: () -> Void
    @State private var autoReconnect = true
    @State private var keepAwake = true
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 0) {
                GroupTitle(text: "当前守护进程")
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 9).fill(DS.greenSoftBG).frame(width: 38, height: 38)
                        .overlay(DSIcon(name: "monitor", size: 20).foregroundStyle(DS.greenSoftTX))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(app.daemonHostname ?? "未连接").font(.system(size: 14, weight: .semibold)).foregroundStyle(DS.text)
                        HStack(spacing: 6) {
                            Circle().fill(app.connectionState == .connected ? DS.green : DS.grayDot).frame(width: 8, height: 8)
                            Text(app.connectionState == .connected ? "已连接 · 守护进程 v\(app.daemonVersion ?? "?")" : "未连接")
                                .font(.system(size: 12)).foregroundStyle(DS.text2)
                        }
                    }
                    Spacer()
                    Button { onOpenConnect() } label: { HStack(spacing: 7) { DSIcon(name: "refresh", size: 15); Text("重新配对") }.font(.system(size: 13)).foregroundStyle(DS.text).padding(.horizontal, 12).frame(height: 30).background(DS.hover, in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain)
                }
                .padding(14).background(Color(hex: 0xFBFBFA), in: RoundedRectangle(cornerRadius: 11)).overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(DS.divider, lineWidth: 1))
                .padding(.bottom, 6)
                SetRow(label: "自动重连", sub: "连接中断时自动尝试恢复。") { DSSwitch(isOn: $autoReconnect) }
                SetRow(label: "保持设备唤醒", sub: "运行任务时阻止系统休眠。") { DSSwitch(isOn: $keepAwake) }
            }
        }
    }
}

// MARK: - 模型

private struct ProvidersSection: View {
    @Environment(AppViewModel.self) private var app
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupTitle(text: "已接入的厂商")
            ForEach(orderedProviders, id: \.provider) { p in
                SetRow(label: p.label ?? p.provider.capitalized, sub: p.status) {
                    Circle().fill(p.status == "ready" ? DS.green : DS.grayDot).frame(width: 8, height: 8)
                }
            }
            if orderedProviders.isEmpty {
                Text("尚未接入厂商").font(.system(size: 13)).foregroundStyle(DS.text3).padding(.vertical, 20)
            }
        }
    }
    private var orderedProviders: [ProviderSnapshot] {
        let order = ["claude", "codex", "antigravity", "gemini", "opencode", "copilot", "pi"]
        return app.providers.sorted { (order.firstIndex(of: $0.provider) ?? 99) < (order.firstIndex(of: $1.provider) ?? 99) }
    }
}
