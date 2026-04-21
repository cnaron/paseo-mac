import Foundation

/// Runs a synchronous smoke test that connects to the daemon and prints all agents
/// in a table similar to `paseo ls`. Never returns — exits the process when done.
func runSmokeTestAndExit() -> Never {
    // Disable stdout buffering so our output is visible even if the process is killed.
    setbuf(stdout, nil)
    let args = CommandLine.arguments
    let host = argValue("--host", in: args) ?? "localhost"
    let port = Int(argValue("--port", in: args) ?? "") ?? 6767
    let limit = Int(argValue("--limit", in: args) ?? "") ?? 50

    let endpoint = DaemonEndpoint(
        host: host,
        port: port,
        clientId: "cid_paseomac_smoke_\(Int(Date().timeIntervalSince1970))"
    )

    let sem = DispatchSemaphore(value: 0)

    Task {
        defer { sem.signal() }
        let client = DaemonClient(endpoint: endpoint)
        do {
            print("Connecting to \(endpoint.websocketURL.absoluteString) ...")
            try await client.connect()
            try? await Task.sleep(for: .milliseconds(150))

            let agents = try await client.listAgents(limit: limit)
            print("")
            print(pad("ID", 10) + "  " + pad("STATUS", 10) + "  TITLE")
            print(String(repeating: "-", count: 60))
            for a in agents {
                let id = String(a.id.prefix(8))
                print(pad(id, 10) + "  " + pad(a.status, 10) + "  " + a.displayName)
            }
            print("")
            print("Total: \(agents.count) agent(s)")
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
