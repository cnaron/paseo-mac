import SwiftUI

struct ContentView: View {
    @Environment(AppViewModel.self) private var app
    @State private var showConnect: Bool = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            AgentListView(showConnect: $showConnect)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            detailView
        }

        .sheet(isPresented: $showConnect) {
            ConnectSheet()
        }
        .task {
            app.autoConnectIfPossible()
            app.startWakeObserver()
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
        // Always show the conversation view if an agent is selected — even when
        // disconnected, so the user can keep reading cached history.
        // Only fall through to status screens when there's nothing to show.
        if let id = app.selectedAgentId {
            ConversationView(agentId: id)
                .id(id)
        } else {
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
                ContentUnavailableView(
                    "Select an agent",
                    systemImage: "sidebar.left",
                    description: Text("Pick an agent from the sidebar.")
                )
            }
        }
    }


}
