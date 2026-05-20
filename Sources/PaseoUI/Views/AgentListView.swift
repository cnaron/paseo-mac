#if os(macOS)
import AppKit
#endif
import SwiftUI
import PaseoCore

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
                            Spacer()
                            Button {
                                app.cancelPendingAgent()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .help("Cancel new conversation")
                        }
                        .tag(AppViewModel.pendingAgentId as String?)
                        .contextMenu {
                            Button(role: .destructive) { app.cancelPendingAgent() } label: {
                                Label("Cancel", systemImage: "xmark")
                            }
                        }
                    }
                    agentRows
                }
                if !app.archivedAgents.isEmpty {
                    Section("Archived") {
                        if app.isLoadingArchived {
                            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 4)
                        }
                        ForEach(app.archivedAgents) { agent in
                            ArchivedAgentRow(agent: agent)
                                .tag(agent.id as String?)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            if app.daemonVersionMismatch {
                Divider()
                DaemonVersionMismatchBanner(app: app)
            }
            if app.claudeCodeUpdateAvailable {
                Divider()
                ClaudeCodeUpdateBanner(app: app)
            }
            Divider()
            ArchivedToggleRow()
                .environment(app)
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
                onUpdate: { Task { await app.updateClaudeCode() } },
                hasGemini: app.providers.contains(where: { $0.provider == "gemini" && $0.status == "ready" })
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

extension AgentListView {
    @ViewBuilder
    private var agentRows: some View {
        let isWorking = app.selectedAgentIsWorking
        let selId = app.selectedAgentId
        ForEach(app.agents) { agent in
            AgentRow(
                agent: agent,
                live: app.liveStatus[agent.id],
                isActivelyWorking: isWorking && agent.id == selId,
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

private struct AgentRow: View {
    let agent: AgentSnapshot
    let live: AppViewModel.LiveStatus?
    var isActivelyWorking: Bool = false
    var onDelete: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            StatusIndicator(
                status: effectiveStatus,
                requiresAttention: effectiveAttention,
                isActivelyWorking: isActivelyWorking
            )
            ProviderIcon(provider: agent.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(effectiveStatus == "running" ? "\(shortCwd) · running" : shortCwd)
                    .font(.caption)
                    .foregroundStyle(effectiveStatus == "running" ? Color.green : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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

private struct ArchivedAgentRow: View {
    let agent: AgentSnapshot
    @Environment(AppViewModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "archivebox")
                .foregroundStyle(.tertiary)
                .font(.caption)
                .frame(width: 16)
            ProviderIcon(provider: agent.provider)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(shortCwd)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .help(agent.cwd)
        .contextMenu {
            Button {
                Task { await app.createAgent(cwd: agent.cwd) }
            } label: {
                Label("New Conversation Here", systemImage: "plus.bubble")
            }
        }
    }

    private var shortCwd: String {
        let parts = agent.cwd.split(separator: "/").map(String.init)
        guard parts.count > 2 else { return agent.cwd }
        return "…/" + parts.suffix(2).joined(separator: "/")
    }
}

// MARK: - Provider icon (real PNG logo for Claude/Gemini; SF Symbol fallback for others)

struct ProviderIcon: View {
    let provider: String?
    var body: some View {
        if let image = Self.brandImage(for: provider) {
            Image(platformImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: 16, height: 16)
        } else {
            Image(systemName: Self.symbolName(for: provider))
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(width: 20)
        }
    }

    private static func brandImage(for provider: String?) -> PlatformImage? {
        guard let name = brandAssetName(for: provider) else { return nil }
        #if os(macOS)
        guard let nsImage = NSImage(named: name)
            ?? (Bundle.main.path(forResource: name, ofType: "png").flatMap { NSImage(contentsOfFile: $0) }) else { return nil }
        nsImage.size = NSSize(width: 16, height: 16)
        return nsImage
        #else
        return nil
        #endif
    }

    private static func brandAssetName(for provider: String?) -> String? {
        switch provider {
        case "claude": return "claude"
        case "gemini": return "gemini"
        default: return nil
        }
    }

    static func symbolName(for provider: String?) -> String {
        switch provider {
        case "claude": return "sparkles"
        case "gemini": return "diamond.fill"
        case "codex": return "terminal.fill"
        case "opencode": return "chevron.left.forwardslash.chevron.right"
        case "copilot": return "airplane.circle"
        default: return "hammer.fill"
        }
    }
}

/// Status indicator: a colored dot, animated via scale pulse when running.
/// Colors chosen to contrast against macOS List's blue selection highlight:
/// green stays visible, idle uses cyan (not blue), errors use orange/red.
private struct StatusIndicator: View {
    let status: String
    let requiresAttention: Bool
    var isActivelyWorking: Bool = false

    @State private var pulse = false

    private var shouldPulse: Bool { isActivelyWorking }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
            )
            .scaleEffect(pulse && shouldPulse ? 1.35 : 1.0)
            .animation(
                shouldPulse
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear { pulse = shouldPulse }
            .onChange(of: shouldPulse) { _, active in
                pulse = false
                if active { DispatchQueue.main.async { pulse = true } }
            }
    }

    private var color: Color {
        switch status {
        case "running": return .green
        case "error", "failed": return .red
        default:
            if requiresAttention { return .accentColor }
            return status == "idle" ? .cyan : .gray
        }
    }
}

// MARK: - Archived sessions toggle row

private struct ArchivedToggleRow: View {
    @Environment(AppViewModel.self) private var app

    var body: some View {
        Button {
            Task {
                if app.archivedAgents.isEmpty {
                    await app.loadArchivedAgents()
                } else {
                    app.clearArchivedAgents()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: app.archivedAgents.isEmpty ? "clock" : "clock.fill")
                    .foregroundStyle(app.archivedAgents.isEmpty ? Color.secondary : Color.accentColor)
                    .frame(width: 16)
                Text(app.archivedAgents.isEmpty ? "Show archived" : "Hide archived")
                    .font(.caption)
                    .foregroundStyle(app.archivedAgents.isEmpty ? Color.secondary : Color.primary)
                Spacer()
                if app.isLoadingArchived {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(app.connectionState != .connected)
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

private struct DaemonVersionMismatchBanner: View {
    let app: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Daemon version mismatch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                Spacer()
                Button { app.versionMismatchDismissed = true } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if let host = app.daemonHostname, let ver = app.daemonVersion {
                Text("\(host) is running v\(ver). Expected v\(AppViewModel.compatibleDaemonPrefix).x. For the best experience, keep the daemon and client compatible.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

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
                    .frame(width: 16, height: 16)
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
