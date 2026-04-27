import Foundation

/// Runs a synchronous smoke test that connects to the daemon and prints all agents
/// in a table similar to `paseo ls`. Never returns — exits the process when done.
///
/// Two modes:
///
///   # Direct (SSH-tunnelled or loopback)
///   PaseoMac --list-agents [--host localhost] [--port 6767]
///
///   # Relay (E2EE via a Paseo relay server)
///   PaseoMac --list-agents --offer <paseo-offer-url-or-base64-or-json>
///
func runSmokeTestAndExit() -> Never {
    setbuf(stdout, nil)
    let args = CommandLine.arguments

    let limit = Int(argValue("--limit", in: args) ?? "") ?? 50
    let clientId = argValue("--client-id", in: args)
        ?? "cid_paseomac_smoke_\(Int(Date().timeIntervalSince1970))"

    let endpoint: DaemonEndpoint
    if let offerRaw = argValue("--offer", in: args) {
        do {
            let offer = try ConnectionOffer.parse(offerRaw)
            endpoint = .relay(offer: offer, clientId: clientId)
        } catch {
            fputs("ERROR: could not parse --offer: \(error.localizedDescription)\n", stderr)
            exit(2)
        }
    } else {
        let host = argValue("--host", in: args) ?? "localhost"
        let port = Int(argValue("--port", in: args) ?? "") ?? 6767
        endpoint = .direct(host: host, port: port, clientId: clientId)
    }

    let sem = DispatchSemaphore(value: 0)

    Task {
        defer { sem.signal() }
        let client = DaemonClient(endpoint: endpoint)
        do {
            print("Connecting to \(endpoint.displayName) ...")
            try await client.connect()
            try? await Task.sleep(for: .milliseconds(150))

            let agents = try await client.listAgents(limit: limit)

            if let agentQuery = argValue("--timeline", in: args) {
                // Resolve prefix match against the list we just fetched.
                guard let target = agents.first(where: { $0.id.hasPrefix(agentQuery) }) else {
                    fputs("ERROR: no agent found with id prefix '\(agentQuery)'\n", stderr)
                    return
                }
                print("Fetching timeline for \(target.displayName) (\(target.id.prefix(8)))...")
                let payload = try await client.fetchTimeline(agentId: target.id, limit: 30)
                print("")
                print("Timeline: \(payload.entries.count) entries (hasOlder=\(payload.hasOlder))")
                print(String(repeating: "-", count: 60))
                for entry in payload.entries {
                    let kind = entry.item.displayKind.padding(toLength: 10, withPad: " ", startingAt: 0)
                    let text = entry.item.displayText
                        .replacingOccurrences(of: "\n", with: " ⏎ ")
                        .prefix(120)
                    print("\(kind) \(text)")
                }
            } else {
                print("")
                print(pad("ID", 10) + "  " + pad("STATUS", 10) + "  TITLE")
                print(String(repeating: "-", count: 60))
                for a in agents {
                    let id = String(a.id.prefix(8))
                    print(pad(id, 10) + "  " + pad(a.status, 10) + "  " + a.displayName)
                }
                print("")
                print("Total: \(agents.count) agent(s)")
            }
            await client.disconnect()
        } catch {
            fputs("ERROR: \(error.localizedDescription)\n", stderr)
        }
    }

    sem.wait()
    exit(0)
}

private func argValue(_ flag: String, in args: [String]) -> String? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return args[i + 1]
}

private func pad(_ s: String, _ n: Int) -> String {
    s.padding(toLength: n, withPad: " ", startingAt: 0)
}
