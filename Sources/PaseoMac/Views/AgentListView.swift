import SwiftUI

struct AgentListView: View {
    @Environment(AppViewModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selectedAgentId) {
            Section("Agents") {
                ForEach(app.agents) { agent in
                    AgentRow(
                        agent: agent,
                        live: app.liveStatus[agent.id]
                    )
                    .tag(agent.id as String?)
                }
            }
        }
        .listStyle(.sidebar)
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
private struct StatusIndicator: View {
    let status: String
    let requiresAttention: Bool

    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(pulse && status == "running" ? 1.35 : 1.0)
            .animation(
                status == "running"
                    ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                    : .default,
                value: pulse
            )
            .onAppear { pulse = true }
            .onChange(of: status) { _, _ in
                // Re-arm the animation when we transition into "running".
                pulse = false
                DispatchQueue.main.async { pulse = true }
            }
    }

    private var color: Color {
        if requiresAttention { return .orange }
        switch status {
        case "running": return .green
        case "idle": return .blue
        case "error", "failed": return .red
        default: return .gray
        }
    }
}
