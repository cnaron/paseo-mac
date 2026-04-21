import SwiftUI

struct AgentListView: View {
    @Environment(AppViewModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.selectedAgentId) {
            Section("Agents") {
                ForEach(app.agents) { agent in
                    AgentRow(agent: agent)
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

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: agent.status, requiresAttention: agent.requiresAttention ?? false)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(agent.cwd)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

private struct StatusDot: View {
    let status: String
    let requiresAttention: Bool

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }

    private var color: Color {
        if requiresAttention { return .orange }
        switch status {
        case "running": return .green
        case "idle": return .blue
        case "error": return .red
        default: return .gray
        }
    }
}
