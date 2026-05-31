import SwiftUI

// MARK: - Sidebar (290pt source list)
//
// Faithful to the prototype `src/sidebar.jsx`: workspace switcher · 新对话 ·
// Chats (four-state rows) · 显示归档 / 导入会话 · usage panel · connection
// footer · utility bar. Wired to the existing AppViewModel.

struct SidebarView: View {
    @Environment(AppViewModel.self) private var app
    @Environment(\.accent) private var accent
    var onOpenSettings: () -> Void = {}
    var onOpenConnect: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            // top — clears the window traffic lights (44pt)
            VStack(spacing: 4) {
                WorkspaceSwitcher(onOpenConnect: onOpenConnect)
                NewConversationButton()
            }
            .padding(.horizontal, 10)
            .padding(.top, 44)
            .padding(.bottom, 6)

            // scrolling body
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ChatsSection()
                    SecondarySection()
                    if app.usageData != nil
                        || app.codexSessionStats != nil
                        || app.claudeCodeCurrentVersion != nil {
                        UsagePanelView(onOpenSettings: onOpenSettings)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            ConnectionFooter(onOpenConnect: onOpenConnect)
            UtilityBar(onOpenSettings: onOpenSettings)
        }
        .frame(width: DS.sidebarW)
        .background(DS.sidebarBG)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DS.divider).frame(width: 1)
        }
    }
}

// MARK: - Workspace switcher

private struct WorkspaceSwitcher: View {
    @Environment(AppViewModel.self) private var app
    var onOpenConnect: () -> Void

    var body: some View {
        Menu {
            Section("已连接守护进程") {
                if let host = app.daemonHostname {
                    Text(host + (app.daemonVersion.map { " · v\($0)" } ?? ""))
                }
            }
            Button { onOpenConnect() } label: { Label("切换 / 重新配对守护进程…", systemImage: "arrow.clockwise") }
            Button { onOpenConnect() } label: { Label("连接设置…", systemImage: "gearshape") }
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: [Color(hex: 0x7D8DF0), Color(hex: 0x5566D6)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 26, height: 26)
                    .overlay(DSIcon(name: "person", size: 15, weight: .medium).foregroundStyle(.white))
                Text(workspaceName)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(DS.text)
                    .lineLimit(1)
                Spacer(minLength: 0)
                DSIcon(name: "chevron-down", size: 15).foregroundStyle(DS.text3)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
    }

    private var workspaceName: String {
        if let host = app.daemonHostname, !host.isEmpty { return "\(host) workspace" }
        return "cnaron's workspace"
    }
}

// MARK: - New conversation (directory picker)

private struct NewConversationButton: View {
    @Environment(AppViewModel.self) private var app
    @State private var showPicker = false
    @State private var hover = false

    var body: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 10) {
                DSIcon(name: "new-chat", size: 18).foregroundStyle(DS.text)
                Text("新对话").font(.system(size: 14.5, weight: .medium)).foregroundStyle(DS.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(hover ? DS.hover : .clear, in: RoundedRectangle(cornerRadius: 9))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(app.connectionState != .connected)
        .popover(isPresented: $showPicker, arrowEdge: .bottom) {
            DirectoryPicker { path in
                showPicker = false
                Task { await app.createAgent(cwd: path) }
            }
        }
    }
}

private struct DirectoryPicker: View {
    @Environment(AppViewModel.self) private var app
    let onSelect: (String) -> Void
    @State private var custom = ""

    private var suggested: [String] {
        var seen = Set<String>(); var out: [String] = []
        for a in app.agents.sorted(by: { ($0.lastUserMessageAt ?? $0.updatedAt) > ($1.lastUserMessageAt ?? $1.updatedAt) }) {
            if seen.insert(a.cwd).inserted { out.append(a.cwd) }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("选择目录").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text2)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(suggested, id: \.self) { p in
                        Button { onSelect(p) } label: {
                            HStack(spacing: 9) {
                                DSIcon(name: "folder", size: 16).foregroundStyle(DS.text3)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(URL(fileURLWithPath: p).lastPathComponent).font(.system(size: 13)).foregroundStyle(DS.text)
                                    Text(p).font(.system(size: 11.5)).foregroundStyle(DS.text3).lineLimit(1).truncationMode(.middle)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 6).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 200)
            Divider()
            TextField("/path/to/project", text: $custom)
                .textFieldStyle(.plain)
                .font(DS.mono(13))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .onSubmit {
                    let p = custom.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !p.isEmpty { onSelect(p) }
                }
        }
        .frame(width: 280)
    }
}

// MARK: - Chats section

private struct ChatsSection: View {
    @Environment(AppViewModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text("Chats").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text3)
                Spacer()
            }
            .padding(.horizontal, 9).padding(.top, 14).padding(.bottom, 6)

            if app.pendingNewAgentCwd != nil {
                PendingRow()
            }
            ForEach(app.agents) { agent in
                ChatRowView(agent: agent)
            }
            if app.agents.isEmpty && app.pendingNewAgentCwd == nil {
                Text(app.connectionState == .connected ? "暂无会话" : "未连接")
                    .font(.system(size: 12.5)).foregroundStyle(DS.text3)
                    .padding(.horizontal, 9).padding(.vertical, 8)
            }
        }
    }
}

private struct PendingRow: View {
    @Environment(AppViewModel.self) private var app
    var body: some View {
        HStack(spacing: 9) {
            DSIcon(name: "chat", size: 16).foregroundStyle(DS.text3).frame(width: 22)
            Text("新对话").font(.system(size: 14)).foregroundStyle(DS.text)
            Spacer()
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(app.selectedAgentId == AppViewModel.pendingAgentId ? DS.hover : .clear,
                    in: RoundedRectangle(cornerRadius: DS.R.row))
        .contentShape(Rectangle())
        .onTapGesture { app.selectedAgentId = AppViewModel.pendingAgentId }
    }
}

// four chat states (prototype CHAT_STATE)
enum ChatState { case running, waiting, done, idle }

struct ChatRowView: View {
    let agent: AgentSnapshot
    @Environment(AppViewModel.self) private var app
    @Environment(\.accent) private var accent
    @State private var hover = false
    @State private var renaming = false
    @State private var draftName = ""

    private var live: AppViewModel.LiveStatus? { app.liveStatus[agent.id] }
    private var selected: Bool { app.selectedAgentId == agent.id }

    private var state: ChatState {
        let status = live?.status ?? agent.status
        let attention = live?.requiresAttention ?? (agent.requiresAttention ?? false)
        if status == "running" { return .running }
        if attention { return .waiting }
        return .idle
    }

    var body: some View {
        HStack(spacing: 9) {
            ChatAvatar(provider: agent.provider, state: state)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.displayName).font(.system(size: 14)).foregroundStyle(DS.text).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12.5))
                    .foregroundStyle(subtitleColor)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 4)
            Text(relativeTime(agent.lastUserMessageAt ?? agent.updatedAt))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(DS.text3)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(selected ? accent.sel : (hover ? DS.hover : .clear),
                    in: RoundedRectangle(cornerRadius: DS.R.row))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { app.selectedAgentId = agent.id }
        .help(agent.cwd)
        .contextMenu {
            Button { draftName = agent.title ?? agent.displayName; renaming = true } label: { Label("重命名…", systemImage: "pencil") }
            Divider()
            Button(role: .destructive) { Task { await app.archiveAgent(agentId: agent.id) } } label: { Label("归档会话", systemImage: "archivebox") }
        }
        .alert("重命名会话", isPresented: $renaming) {
            TextField("名称", text: $draftName)
            Button("保存") {
                let t = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { Task { await app.renameAgent(agentId: agent.id, name: t) } }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var dir: String {
        let parts = agent.cwd.split(separator: "/")
        return parts.isEmpty ? agent.cwd : "…/" + parts.suffix(1).joined(separator: "/")
    }
    private var subtitle: String {
        switch state {
        case .running: return dir + " · 进行中"
        case .waiting: return dir + " · 等待中"
        case .done:    return dir + " · 已完成"
        case .idle:    return dir
        }
    }
    private var subtitleColor: Color {
        switch state {
        case .running: return DS.greenSoftTX
        case .waiting: return DS.orange
        case .done:    return DS.cyan
        case .idle:    return DS.text3
        }
    }
}

/// Provider logo avatar with a state pulse-ring + corner badge (prototype `.chat-ava`).
struct ChatAvatar: View {
    let provider: String?
    let state: ChatState
    @State private var pulse = false

    var body: some View {
        ZStack {
            // pulse ring for live states
            if state == .running || state == .waiting {
                Circle()
                    .strokeBorder(ringColor, lineWidth: 1.5)
                    .frame(width: 28, height: 28)
                    .scaleEffect(pulse ? 1.25 : 0.85)
                    .opacity(pulse ? 0 : 0.65)
                    .animation(.easeOut(duration: 1.7).repeatForever(autoreverses: false), value: pulse)
                    .onAppear { pulse = true }
            }
            ProviderGlyph(provider: provider, size: 17)
                .frame(width: 22, height: 22)
            // corner badge
            if let badge = badgeColor {
                Circle().fill(badge)
                    .frame(width: 11, height: 11)
                    .overlay {
                        if state == .done { DSIcon(name: "check-sm", size: 7, weight: .bold).foregroundStyle(.white) }
                    }
                    .overlay(Circle().strokeBorder(DS.sidebarBG, lineWidth: 2))
                    .offset(x: 9, y: 9)
            }
        }
        .frame(width: 22, height: 22)
    }

    private var ringColor: Color { state == .waiting ? DS.orange : DS.green }
    private var badgeColor: Color? {
        switch state {
        case .running: return DS.green
        case .waiting: return DS.orange
        case .done:    return DS.cyan
        case .idle:    return nil
        }
    }
}

// MARK: - Archived + import

private struct SecondarySection: View {
    @Environment(AppViewModel.self) private var app
    @State private var hoverA = false
    @State private var hoverI = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                Task {
                    if app.archivedAgents.isEmpty { await app.loadArchivedAgents() }
                    else { app.clearArchivedAgents() }
                }
            } label: {
                row(icon: "clock", text: app.archivedAgents.isEmpty ? "显示归档" : "隐藏归档", hover: hoverA)
            }
            .buttonStyle(.plain).onHover { hoverA = $0 }
            .disabled(app.connectionState != .connected)

            ForEach(app.archivedAgents) { a in
                HStack(spacing: 9) {
                    DSIcon(name: "archive", size: 15).foregroundStyle(DS.text3).opacity(0.6).frame(width: 22)
                    Text(a.displayName).font(.system(size: 14)).foregroundStyle(DS.text3).lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 9).padding(.vertical, 6).contentShape(Rectangle())
                .onTapGesture { app.selectedAgentId = a.id }
            }

            Button { Task { await app.openImportSheet() } } label: {
                row(icon: "import", text: "导入会话…", hover: hoverI)
            }
            .buttonStyle(.plain).onHover { hoverI = $0 }
            .disabled(app.connectionState != .connected)
        }
        .padding(.top, 14)
    }

    private func row(icon: String, text: String, hover: Bool) -> some View {
        HStack(spacing: 9) {
            DSIcon(name: icon, size: 16).foregroundStyle(DS.text2).frame(width: 22)
            Text(text).font(.system(size: 13.5)).foregroundStyle(DS.text2)
            Spacer()
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .background(hover ? DS.hover : .clear, in: RoundedRectangle(cornerRadius: DS.R.row))
        .contentShape(Rectangle())
    }
}

// MARK: - Connection footer

private struct ConnectionFooter: View {
    @Environment(AppViewModel.self) private var app
    var onOpenConnect: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Circle().fill(dotColor).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text)
                if app.connectionState == .connected, let host = app.daemonHostname {
                    Text(host + (app.daemonVersion.map { " · v\($0)" } ?? ""))
                        .font(.system(size: 11.5)).foregroundStyle(DS.text3).lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            IconButton(icon: "gear", box: 28, glyph: 16, help: "连接设置（服务器 URL）", action: onOpenConnect)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .overlay(alignment: .top) { Rectangle().fill(DS.divider).frame(height: 1) }
    }

    private var dotColor: Color {
        switch app.connectionState {
        case .connected: return DS.green
        case .connecting: return Color(hex: 0xE0B62B)
        case .failed: return DS.red
        case .disconnected: return DS.grayDot
        }
    }
    private var label: String {
        switch app.connectionState {
        case .connected: return "已连接"
        case .connecting: return "连接中…"
        case .failed: return "已断开"
        case .disconnected: return "离线"
        }
    }
}

// MARK: - Utility bar

private struct UtilityBar: View {
    @Environment(AppViewModel.self) private var app
    var onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            IconButton(icon: "gear", box: 28, glyph: 17, help: "偏好设置 (⌘,)", action: onOpenSettings)
            IconButton(icon: "help", box: 28, glyph: 17, help: "帮助") {}
            IconButton(icon: "archive", box: 28, glyph: 17, help: "归档") {
                Task { if app.archivedAgents.isEmpty { await app.loadArchivedAgents() } }
            }
            Spacer()
            IconButton(icon: "filter", box: 28, glyph: 17, help: "筛选 / 排序") {}
        }
        .padding(.horizontal, 12).padding(.top, 7).padding(.bottom, 11)
        .overlay(alignment: .top) { Rectangle().fill(DS.divider).frame(height: 1) }
    }
}

// MARK: - Shared helpers

/// ISO8601 → relative ("now" / "2h" / "1d" / "1mo").
func relativeTime(_ iso: String?) -> String {
    guard let iso, let date = parseISODate(iso) else { return "" }
    let s = Date().timeIntervalSince(date)
    if s < 60 { return "now" }
    if s < 3600 { return "\(Int(s / 60))m" }
    if s < 86_400 { return "\(Int(s / 3600))h" }
    if s < 86_400 * 30 { return "\(Int(s / 86_400))d" }
    if s < 86_400 * 365 { return "\(Int(s / (86_400 * 30)))mo" }
    return "\(Int(s / (86_400 * 365)))y"
}

func parseISODate(_ iso: String) -> Date? {
    let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    return frac.date(from: iso) ?? plain.date(from: iso)
}

/// Future Date → countdown ("3d 6h" / "2h 41m" / "12m" / "now").
func resetCountdown(_ date: Date?) -> String {
    guard let date else { return "" }
    let s = date.timeIntervalSinceNow
    if s <= 0 { return "now" }
    let days = Int(s / 86_400), hours = Int(s.truncatingRemainder(dividingBy: 86_400) / 3600)
    let mins = Int(s.truncatingRemainder(dividingBy: 3600) / 60)
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(mins)m" }
    return "\(mins)m"
}
