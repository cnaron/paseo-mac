import SwiftUI

struct ContentView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Text("Agents")
                    .font(.headline)
                Text("(Phase 1 will populate this)")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
            .navigationTitle("PaseoMac")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 12) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 48))
                    .foregroundStyle(.tertiary)
                Text("Select an agent to begin")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#Preview {
    ContentView()
}
