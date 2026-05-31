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
                SetRow(label: "行间距 / 密度", sub: "消息之间的留白。") {
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
        }
    }
}

// MARK: - 用量

private struct UsageStatsSection: View {
    @Environment(AppViewModel.self) private var app
    private let colors: [Color] = [Color(hex: 0xD97757), Color(hex: 0xE0A33E), Color(hex: 0x10A37F), Color(hex: 0x4285F4)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                if let s = app.statsData { Text("Last computed: \(s.lastComputedDate)").font(.system(size: 12)).foregroundStyle(DS.text3) }
                Spacer()
                Button("刷新") { Task { await app.fetchStats() } }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(AccentPalette.terracotta.accent)
            }
            if let s = app.statsData, !s.modelUsage.isEmpty {
                let totalTokens = s.modelUsage.reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cacheReadTokens + $1.cacheWriteTokens }
                let totalCost = s.modelUsage.reduce(0.0) { $0 + $1.apiEquivCostUSD }
                HStack(spacing: 12) {
                    statCard("TOKEN", compactTokens(totalTokens))
                    statCard("花费（USD）", String(format: "$%.2f", totalCost))
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
            } else {
                VStack(spacing: 8) {
                    Text("暂无用量数据").font(.system(size: 13)).foregroundStyle(DS.text3)
                    Text("在「连接 / Integration」配置 stats 端点后重连即可。").font(.system(size: 12)).foregroundStyle(DS.textFaint)
                    Button("立即获取") { Task { await app.fetchStats() } }.controlSize(.small)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 30)
            }
        }
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
