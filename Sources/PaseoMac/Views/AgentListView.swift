import SwiftUI

struct AgentListView: View {
    @Binding var showConnect: Bool
    @Environment(AppViewModel.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            List(selection: $app.selectedAgentId) {
                Section("Agents") {
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
            Divider()
            NewAgentBar()
                .environment(app)
            Divider()
            UsagePanel()
                .environment(app)
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
            .scaleEffect(pulse && status == "running" ? 1.35 : 1.0)
            .animation(
                status == "running"
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear { pulse = true }
            .onChange(of: status) { _, _ in
                pulse = false
                DispatchQueue.main.async { pulse = true }
            }
    }

    private var color: Color {
        if requiresAttention { return .orange }
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

    var body: some View {
        Button {
            let cwd = app.currentAgent()?.cwd ?? NSHomeDirectory()
            Task { await app.createAgent(cwd: cwd) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Color.accentColor)
                Text("New Agent")
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Create a new agent in the current working directory")
        .disabled(app.connectionState != .connected)
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
