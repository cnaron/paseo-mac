import SwiftUI

struct AgentListView: View {
    @Binding var showConnect: Bool
    @Environment(AppViewModel.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            List(selection: $app.selectedAgentId) {
                Section("Agents") {
                    if app.pendingNewAgentCwd != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "ellipsis.bubble")
                                .foregroundStyle(.secondary)
                                .frame(width: 16)
                            Text("New conversation")
                                .foregroundStyle(.primary)
                        }
                        .tag(AppViewModel.pendingAgentId as String?)
                    }
                    ForEach(app.agents) { agent in
                        AgentRow(
                            agent: agent,
                            live: app.liveStatus[agent.id],
                            onDelete: { Task { await app.archiveAgent(agentId: agent.id) } }
                        )
                        .tag(agent.id as String?)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                Task { await app.archiveAgent(agentId: agent.id) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            if app.claudeCodeUpdateAvailable {
                Divider()
                ClaudeCodeUpdateBanner(app: app)
            }
            Divider()
            NewAgentBar()
                .environment(app)
            Divider()
            UsagePanel(
                usage: app.usageData,
                onRefresh: { Task { await app.fetchUsage() } },
                currentVersion: app.claudeCodeCurrentVersion,
                latestVersion: app.claudeCodeLatestVersion,
                isCheckingVersion: app.isCheckingClaudeCodeVersion,
                isUpdating: app.isUpdatingClaudeCode,
                onCheckVersion: { Task { await app.checkClaudeCodeVersion() } },
                onUpdate: { Task { await app.updateClaudeCode() } }
            )
            Divider()
            ConnectionFooter(showConnect: $showConnect)
                .environment(app)
        }
        .navigationTitle("PaseoMac")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { try? await app.refreshAgents() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Refresh agents")
            }
        }
        .overlay {
            if app.agents.isEmpty {
                ContentUnavailableView(
                    "No agents",
                    systemImage: "sparkles",
                    description: Text("Connect and your agents will appear here.")
                )
            }
        }
    }
}

private struct AgentRow: View {
    let agent: AgentSnapshot
    let live: AppViewModel.LiveStatus?
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            StatusIndicator(
                status: effectiveStatus,
                requiresAttention: effectiveAttention
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                    .font(.body)
                    .lineLimit(1)
                if effectiveAttention {
                    Text("Needs input · \(shortCwd)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(effectiveStatus == "running" ? "\(shortCwd) · running" : shortCwd)
                        .font(.caption)
                        .foregroundStyle(effectiveStatus == "running" ? Color.green : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .help(agent.cwd)
        .contextMenu {
            Button(role: .destructive) {
                onDelete?()
            } label: {
                Label("Delete Agent", systemImage: "trash")
            }
        }
    }

    private var effectiveStatus: String { live?.status ?? agent.status }
    private var effectiveAttention: Bool {
        live?.requiresAttention ?? (agent.requiresAttention ?? false)
    }

    /// Trim absolute paths to `<parent>/<dir>` so long cwd values stay readable.
    private var shortCwd: String {
        let parts = agent.cwd.split(separator: "/").map(String.init)
        guard parts.count > 2 else { return agent.cwd }
        let tail = parts.suffix(2).joined(separator: "/")
        return "…/" + tail
    }
}

/// Status indicator: a colored dot, animated via scale pulse when running.
/// Colors chosen to contrast against macOS List's blue selection highlight:
/// green stays visible, idle uses cyan (not blue), errors use orange/red.
private struct StatusIndicator: View {
    let status: String
    let requiresAttention: Bool

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
            )
            .scaleEffect((pulse && status == "running") || (pulse && requiresAttention) ? 1.35 : 1.0)
            .animation(
                (status == "running" || requiresAttention)
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear { pulse = true }
            .onChange(of: status) { _, _ in
                pulse = false
                DispatchQueue.main.async { pulse = true }
            }
            .onChange(of: requiresAttention) { _, _ in
                pulse = false
                DispatchQueue.main.async { pulse = true }
            }
    }

    private var color: Color {
        if requiresAttention { return .yellow }
        switch status {
        case "running": return .green
        case "idle": return .cyan
        case "error", "failed": return .red
        default: return .gray
        }
    }
}

// MARK: - New Agent bar

private struct NewAgentBar: View {
    @Environment(AppViewModel.self) private var app
    @State private var showPicker = false

    var body: some View {
        Button { showPicker = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("New Agent")
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.up")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Create a new agent — choose directory")
        .disabled(app.connectionState != .connected)
        .popover(isPresented: $showPicker, arrowEdge: .top) {
            DirectoryPickerPopover(
                suggestedPaths: suggestedPaths,
                onSelect: { path in
                    showPicker = false
                    Task { await app.createAgent(cwd: path) }
                }
            )
            .environment(app)
        }
    }

    private var suggestedPaths: [String] {
        var seen = Set<String>()
        var result: [String] = []
        // Agents sorted newest-first so recent dirs rise to the top
        let sorted = app.agents.sorted {
            ($0.lastUserMessageAt ?? $0.updatedAt) > ($1.lastUserMessageAt ?? $1.updatedAt)
        }
        for agent in sorted {
            let cwd = agent.cwd
            if seen.insert(cwd).inserted { result.append(cwd) }
            let parent = URL(fileURLWithPath: cwd).deletingLastPathComponent().path
            if parent != "/" && parent != cwd && seen.insert(parent).inserted {
                result.append(parent)
            }
        }
        return result
    }
}

// MARK: - Directory picker popover

private struct DirectoryPickerPopover: View {
    let suggestedPaths: [String]
    let onSelect: (String) -> Void
    @Environment(AppViewModel.self) private var app
    @State private var customPath = ""
    @State private var hoveredPath: String? = nil
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Choose directory")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider()

            // Directory list
            if suggestedPaths.isEmpty {
                Text("No recent directories")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(suggestedPaths, id: \.self) { path in
                            PathRow(
                                path: path,
                                isHovered: hoveredPath == path,
                                onSelect: { onSelect(path) }
                            )
                            .onHover { h in hoveredPath = h ? path : nil }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }

            Divider()

            // Custom path input
            HStack(spacing: 8) {
                Image(systemName: "folder.badge.plus")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 14)
                TextField("/path/to/project", text: $customPath)
                    .font(.callout)
                    .textFieldStyle(.plain)
                    .focused($fieldFocused)
                    .onSubmit {
                        let p = customPath.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !p.isEmpty { onSelect(p) }
                    }
                if !customPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        onSelect(customPath.trimmingCharacters(in: .whitespacesAndNewlines))
                    } label: {
                        Image(systemName: "return")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 300)
        .onAppear { fieldFocused = false }
    }
}

private struct PathRow: View {
    let path: String
    let isHovered: Bool
    let onSelect: () -> Void

    private var dirName: String {
        URL(fileURLWithPath: path).lastPathComponent.isEmpty ? "/" :
        URL(fileURLWithPath: path).lastPathComponent
    }
    private var parentPath: String {
        URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundStyle(isHovered ? Color.accentColor : Color.secondary)
                    .frame(width: 14)
                VStack(alignment: .leading, spacing: 1) {
                    Text(dirName)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(isHovered ? Color.accentColor.opacity(0.08) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Connection footer (sidebar bottom)

private struct ConnectionFooter: View {
    @Binding var showConnect: Bool
    @Environment(AppViewModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
            Text(badgeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                showConnect = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Connection settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var badgeColor: Color {
        switch app.connectionState {
        case .connected: .green
        case .connecting: .yellow
        case .failed: .red
        case .disconnected: .gray
        }
    }

    private var badgeLabel: String {
        switch app.connectionState {
        case .connected: "Connected"
        case .connecting: "Connecting…"
        case .failed: "Disconnected"
        case .disconnected: "Offline"
        }
    }
}

// MARK: - Claude Code update banner

private struct ClaudeCodeUpdateBanner: View {
    let app: AppViewModel

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text("Claude Code update available")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                if let latest = app.claudeCodeLatestVersion {
                    Text("v\(latest) ready")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if app.isUpdatingClaudeCode {
                ProgressView()
                    .progressViewStyle(.circular)
                    .scaleEffect(0.6)
                    .frame(width: 14, height: 14)
            } else {
                Button("Update") {
                    Task { await app.updateClaudeCode() }
                }
                .font(.caption2.weight(.medium))
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.orange.opacity(0.08))
    }
}
