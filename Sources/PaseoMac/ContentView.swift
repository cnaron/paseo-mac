import SwiftUI

struct ContentView: View {
    @Environment(AppViewModel.self) private var app
    @State private var showConnect: Bool = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            AgentListView()
        } detail: {
            detailView
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                connectionBadge
            }
        }
        .sheet(isPresented: $showConnect) {
            ConnectSheet()
        }
        .task {
            app.autoConnectIfPossible()
        }
        .onChange(of: app.connectionState) { _, newState in
            // Surface the connect sheet on first launch or when a reconnect is needed.
            switch newState {
            case .disconnected, .failed:
                if app.savedOfferRaw == nil || app.savedOfferRaw?.isEmpty == true {
                    showConnect = true
                }
            case .connecting, .connected:
                break
            }
        }
    }

    @ViewBuilder
    private var detailView: some View {
        switch app.connectionState {
        case .disconnected, .failed:
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "Not connected",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Paste a pairing offer to connect to your daemon.")
                )
                Button("Connect…") { showConnect = true }
                    .buttonStyle(.borderedProminent)
            }
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting…").foregroundStyle(.secondary)
            }
        case .connected:
            if let id = app.selectedAgentId {
                ConversationView(agentId: id)
            } else {
                ContentUnavailableView(
                    "Select an agent",
                    systemImage: "sidebar.left",
                    description: Text("Pick an agent from the sidebar.")
                )
            }
        }
    }

    @ViewBuilder
    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(badgeColor)
                .frame(width: 8, height: 8)
            Text(badgeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                showConnect = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("Connection settings")
        }
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
        case .connecting: "Connecting"
        case .failed(let m): "Failed: \(m)"
        case .disconnected: "Offline"
        }
    }
}
