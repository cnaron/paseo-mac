import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class AppViewModel {

    enum ConnectionState: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    struct LiveStatus: Equatable {
        var status: String
        var requiresAttention: Bool
        var attentionReason: String?
    }

    // MARK: Persisted offer

    private let storedOfferKey = "paseomac.connectionOfferRaw"
    private let storedClientIdKey = "paseomac.clientId"

    /// Stable per-install client id. Generated once and persisted so the
    /// daemon can resume our session across reconnects rather than spinning
    /// up a fresh externalSessionsByKey entry every time.
    private var stableClientId: String {
        let ud = UserDefaults.standard
        if let existing = ud.string(forKey: storedClientIdKey), !existing.isEmpty {
            return existing
        }
        let new = "cid_paseomac_\(UUID().uuidString)"
        ud.set(new, forKey: storedClientIdKey)
        return new
    }

    var connectionState: ConnectionState = .disconnected
    var agents: [AgentSnapshot] = []
    var archivedAgents: [AgentSnapshot] = []
    var isLoadingArchived: Bool = false
    var selectedAgentId: String? = nil {
        didSet {
            if let id = selectedAgentId, id != AppViewModel.pendingAgentId {
                UserDefaults.standard.set(id, forKey: "paseomac.lastSelectedAgentId")
            }
        }
    }
    var pendingNewAgentCwd: String? = nil
    var pendingNewAgentProvider: String = "anthropic"
    var pendingNewAgentModel: String? = nil
    var pendingNewAgentModeId: String? = nil
    var pendingNewAgentThinkingOptionId: String? = nil
    /// Set while createAgent is in flight after the user submitted their first
    /// message. Drives the optimistic user bubble + "Starting agent…" spinner
    /// so the new-conversation view never goes blank between submit and the new
    /// agent ID landing.
    var creatingAgentText: String? = nil
    var creatingAgentImages: [PendingImageAttachment] = []
    static let pendingAgentId = "__pending__"
    private var knownAgentIds: Set<String> = []
    private var pendingCreationContinuation: CheckedContinuation<String?, Never>? = nil
    var savedOfferRaw: String? {
        get { UserDefaults.standard.string(forKey: storedOfferKey) }
        set {
            if let v = newValue, !v.isEmpty {
                UserDefaults.standard.set(v, forKey: storedOfferKey)
            } else {
                UserDefaults.standard.removeObject(forKey: storedOfferKey)
            }
        }
    }

    var liveStatus: [String: LiveStatus] = [:]
    var providers: [ProviderSnapshot] = []

    var daemonVersion: String? = nil
    var daemonHostname: String? = nil
    var versionMismatchDismissed: Bool = false

    /// Compatible Paseo daemon version prefix (major.minor)
    static let compatibleDaemonPrefix = "0.1"

    var daemonVersionMismatch: Bool {
        guard !versionMismatchDismissed,
              let v = daemonVersion else { return false }
        let prefix = Self.compatibleDaemonPrefix
        return !v.hasPrefix(prefix + ".") && v != prefix
    }

    /// Claude subscription usage — fetched from VPS proxy after connect.
    var usageData: ClaudeUsageData? = nil
    var statsData: ClaudeStatsData? = nil

    /// Claude Code CLI version state.
    var claudeCodeCurrentVersion: String? = nil
    var claudeCodeLatestVersion: String? = nil
    var isCheckingClaudeCodeVersion = false
    var isUpdatingClaudeCode = false

    var claudeCodeUpdateAvailable: Bool {
        guard let current = claudeCodeCurrentVersion,
              let latest = claudeCodeLatestVersion,
              !current.isEmpty, current != "unknown" else { return false }
        return latest != current
    }

    // MARK: Internals

    private var client: DaemonClient?
    private var eventTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var conversations: [String: ConversationViewModel] = [:]

    // MARK: - Lifecycle

    var selectedAgentIsWorking: Bool {
        guard let id = selectedAgentId else { return false }
        return conversations[id]?.isAgentWorking ?? false
    }

    func autoConnectIfPossible() {
        guard case .disconnected = connectionState else { return }
        guard let raw = savedOfferRaw, !raw.isEmpty else { return }
        Task { await connect(withOfferRaw: raw) }
    }


    func connect(withOfferRaw raw: String) async {
        EventLogger.shared.log("conn", "connect_start")
        connectionState = .connecting
        // Cancel the old event-listener task before tearing down the old
        // client. Otherwise `await old.disconnect()` finishes the old events
        // stream, the old `for await` exits, and the old task runs
        // `handleUnexpectedDisconnect()` — scheduling a phantom reconnect
        // that races our new connection.
        eventTask?.cancel()
        eventTask = nil
        // Tear down any previous transport before we spin up a fresh one.
        // Without this the old WS task lingers until ARC frees it, and the
        // daemon may still see two sockets keyed to our clientId for a
        // window — the resume logic handles it but it's noisy.
        if let old = self.client {
            await old.disconnect()
            self.client = nil
        }
        do {
            let offer = try ConnectionOffer.parse(raw)
            let endpoint = DaemonEndpoint.relay(
                offer: offer,
                clientId: stableClientId
            )
            let client = DaemonClient(endpoint: endpoint)
            try await client.connect()
            self.client = client
            self.savedOfferRaw = raw
            self.connectionState = .connected
            EventLogger.shared.log("conn", "connected", ["agents": agents.count])

            let events = client.events
            self.eventTask = Task { [weak self] in
                for await session in events {
                    await self?.ingest(session: session)
                }
                guard let self, !Task.isCancelled else { return }
                await self.handleUnexpectedDisconnect()
            }

            try await refreshAgents()

            // Connection is healthy again — clear stale connection-related
            // errors that might have stuck on conversation VMs from the
            // disconnect window (e.g. "Daemon is not connected." surfacing
            // from a sendMessage that raced the drop).
            for vm in conversations.values {
                vm.clearConnectionError()
            }

            // After reconnect, reload conversations that may have missed streaming
            // content while the client was offline. Skip agents that are still
            // running — their streaming events will arrive via the new event stream,
            // and reloading mid-turn would race with and overwrite those updates.
            let runningIds = Set(agents.filter { $0.status == "running" }.map(\.id))
            for (agentId, vm) in conversations where !runningIds.contains(agentId) {
                // Skip the pending-agent placeholder VM — it has no real agentId
                // and asking the daemon to fetch its timeline returns "Agent not
                // found" which closes the WS connection and triggers a reconnect
                // loop.
                if agentId == AppViewModel.pendingAgentId { continue }
                Task { await vm.loadInitial() }
                // Reconcile in case the agent finished while we were offline
                // and the turn_completed event was missed.
                if let snap = agents.first(where: { $0.id == agentId }) {
                    vm.reconcileAgentStatus(snap.status)
                }
            }

            Task { [weak self] in
                if let list = try? await self?.client?.getProvidersSnapshot() {
                    self?.providers = list
                }
            }

            // Fetch usage quota from VPS proxy.
            Task { [weak self] in await self?.fetchUsage() }
            Task { [weak self] in await self?.fetchStats() }
            Task { [weak self] in await self?.checkClaudeCodeVersion() }

        } catch {
            EventLogger.shared.log("conn", "connect_failed", ["err": error.localizedDescription])
            self.connectionState = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        eventTask?.cancel()
        eventTask = nil
        if let c = client { await c.disconnect() }
        client = nil
        conversations.removeAll()
        agents = []
        selectedAgentId = nil
        liveStatus.removeAll()
        providers = []
        usageData = nil
        statsData = nil
        claudeCodeCurrentVersion = nil
        pendingNewAgentCwd = nil
        pendingNewAgentThinkingOptionId = nil
        creatingAgentText = nil
        creatingAgentImages = []
        claudeCodeLatestVersion = nil
        daemonVersion = nil
        daemonHostname = nil
        versionMismatchDismissed = false
        connectionState = .disconnected
    }

    private func handleUnexpectedDisconnect() async {
        let aliveSec = await client?.aliveDuration() ?? 0
        EventLogger.shared.log("conn", "disconnected_unexpected", [
            "secondsAlive": Int(aliveSec)
        ])
        client = nil
        connectionState = .disconnected
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard let raw = savedOfferRaw, !raw.isEmpty else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            // First retry after 1s, then 3s, 9s, 27s — capped at 30s. Each
            // delay also gets ±25% jitter so multiple clients on the same
            // VPS don't reconnect in lock-step (Discord-style thundering-herd
            // mitigation; less critical for a single user but cheap).
            var delay: UInt64 = 1_000_000_000
            while !Task.isCancelled {
                let jittered = AppViewModel.applyJitter(delay)
                EventLogger.shared.log("conn", "reconnect_scheduled", [
                    "delaySec": Double(jittered) / 1e9
                ])
                try? await Task.sleep(nanoseconds: jittered)
                guard !Task.isCancelled, let self else { return }
                guard case .disconnected = connectionState else { return }
                await self.connect(withOfferRaw: raw)
                if case .connected = connectionState { return }
                delay = min(delay * 3, 30_000_000_000)
            }
        }
    }

    /// Apply ±25% random jitter to a backoff delay (in nanoseconds).
    private static func applyJitter(_ delayNs: UInt64) -> UInt64 {
        let f = Double(delayNs)
        let factor = Double.random(in: 0.75...1.25)
        return UInt64(f * factor)
    }

    func startWakeObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, case .disconnected = self.connectionState,
                      let raw = self.savedOfferRaw, !raw.isEmpty else { return }
                await self.connect(withOfferRaw: raw)
            }
        }
    }

    // MARK: - Agent creation

    func createAgent(cwd: String) async {
        let agent = currentAgent()
        pendingNewAgentProvider = agent?.provider ?? "anthropic"
        pendingNewAgentModel = agent?.model
        pendingNewAgentModeId = agent?.currentModeId
        pendingNewAgentThinkingOptionId = agent?.effectiveThinkingOptionId
        pendingNewAgentCwd = cwd
        selectedAgentId = AppViewModel.pendingAgentId
    }

    func cancelPendingAgent() {
        pendingNewAgentCwd = nil
        pendingNewAgentThinkingOptionId = nil
        if selectedAgentId == AppViewModel.pendingAgentId {
            selectedAgentId = agents.first?.id
        }
    }

    func submitPendingAgent(text: String, images: [PendingImageAttachment] = []) async {
        guard let cwd = pendingNewAgentCwd, let client else { return }
        let provider = pendingNewAgentProvider
        let model = pendingNewAgentModel
        let modeId = pendingNewAgentModeId
        let thinkingOptionId = pendingNewAgentThinkingOptionId
        pendingNewAgentCwd = nil
        pendingNewAgentModel = nil
        pendingNewAgentModeId = nil
        pendingNewAgentThinkingOptionId = nil
        creatingAgentText = text
        creatingAgentImages = images
        knownAgentIds = Set(agents.map(\.id))
        EventLogger.shared.log("create_agent", "request", [
            "provider": provider, "model": model ?? "<default>",
            "hasInitialPrompt": images.isEmpty,
            "images": images.count,
            "thinking": thinkingOptionId ?? "<default>"
        ])
        // Pass thinking in createAgent's config so the daemon initializes
        // the agent at the chosen level. Calling set_agent_thinking_request
        // afterward races with turn 1's startup in daemons up to 0.1.70 and
        // fails the turn with "Cannot read properties of null (reading
        // 'push')" — observed for both "max" and "xhigh", so it's the race
        // itself, not any one option. AgentSessionConfigSchema accepts
        // thinkingOptionId directly, which sidesteps the race entirely.
        do {
            try await client.createAgent(
                cwd: cwd, provider: provider, model: model, modeId: modeId,
                thinkingOptionId: thinkingOptionId,
                initialPrompt: images.isEmpty ? text : nil
            )
        } catch {
            EventLogger.shared.log("create_agent", "error", ["err": error.localizedDescription])
            creatingAgentText = nil
            creatingAgentImages = []
            selectedAgentId = agents.first?.id
            return
        }
        // Wait for the new agent via stream event (fast) or poll fallback.
        let detected = await withCheckedContinuation { cont in
            pendingCreationContinuation = cont
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if let cont = pendingCreationContinuation {
                    pendingCreationContinuation = nil
                    cont.resume(returning: nil as String?)
                }
            }
        }
        var agentId = detected
        if agentId == nil {
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                try? await refreshAgents()
                if let newAgent = agents.first(where: { !knownAgentIds.contains($0.id) }) {
                    agentId = newAgent.id
                    break
                }
            }
        }
        guard let agentId else {
            EventLogger.shared.log("create_agent", "timeout")
            creatingAgentText = nil
            creatingAgentImages = []
            selectedAgentId = agents.first?.id
            return
        }
        EventLogger.shared.log("create_agent", "detected", ["agent": agentId])
        // Image-only path: pre-populate optimistic user row and sendMessage.
        if !images.isEmpty {
            let vm = conversation(for: agentId)
            let messageId = UUID().uuidString
            vm.injectOptimisticFirstMessage(text: text, messageId: messageId, images: images)
            selectedAgentId = agentId
            creatingAgentText = nil
            creatingAgentImages = []
            let wireImages = images.map {
                SendAgentMessageRequest.ImageAttachment(
                    data: $0.pngData.base64EncodedString(),
                    mimeType: $0.mimeType
                )
            }
            _ = try? await client.sendMessage(
                agentId: agentId, text: text, messageId: messageId,
                images: wireImages.isEmpty ? nil : wireImages
            )
        } else {
            selectedAgentId = agentId
            creatingAgentText = nil
            creatingAgentImages = []
        }
        // Thinking is now part of createAgent's config above, so we no
        // longer call setAgentThinking here (it would trip the turn-1
        // race documented above). Patch the local snapshot to match.
        if let thinkingOptionId {
            patchAgent(id: agentId) { $0.withThinking(thinkingOptionId) }
        }
    }

    func archiveAgent(agentId: String) async {
        agents.removeAll { $0.id == agentId }
        liveStatus.removeValue(forKey: agentId)
        conversations.removeValue(forKey: agentId)
        if selectedAgentId == agentId {
            selectedAgentId = agents.first?.id
        }
        guard let client else { return }
        do {
            try await client.archiveAgent(agentId: agentId)
        } catch {
            try? await refreshAgents()
        }
    }

    func loadArchivedAgents() async {
        guard let client else { return }
        isLoadingArchived = true
        defer { isLoadingArchived = false }
        do {
            archivedAgents = try await client.listArchivedAgents()
        } catch {
            archivedAgents = []
        }
    }

    func clearArchivedAgents() {
        archivedAgents = []
        // Deselect if the currently selected agent is archived
        if let id = selectedAgentId,
           archivedAgents.contains(where: { $0.id == id }) {
            selectedAgentId = agents.first?.id
        }
    }

    // MARK: - Data access

    func refreshAgents() async throws {
        guard let client else { return }
        let list = try await client.listAgents(limit: 100)
        self.agents = list
        if selectedAgentId == nil {
            let saved = UserDefaults.standard.string(forKey: "paseomac.lastSelectedAgentId")
            if let saved, list.contains(where: { $0.id == saved }) {
                selectedAgentId = saved
            } else if let first = list.first {
                selectedAgentId = first.id
            }
        }
    }

    func conversation(for agentId: String) -> ConversationViewModel {
        if let existing = conversations[agentId] { return existing }
        let vm = ConversationViewModel(agentId: agentId) { [weak self] in self?.client }
        conversations[agentId] = vm
        Task { await vm.loadInitial() }
        return vm
    }

    func effectiveStatus(for agentId: String) -> (status: String, attention: Bool) {
        let base = agents.first(where: { $0.id == agentId })
        if let live = liveStatus[agentId] {
            return (live.status, live.requiresAttention)
        }
        return (base?.status ?? "unknown", base?.requiresAttention ?? false)
    }

    func currentAgent() -> AgentSnapshot? {
        guard let id = selectedAgentId else { return nil }
        return agents.first { $0.id == id } ?? archivedAgents.first { $0.id == id }
    }

    func isArchivedAgent(_ agentId: String) -> Bool {
        archivedAgents.contains(where: { $0.id == agentId })
    }

    // MARK: - Model / mode / thinking dispatch

    func setAgentMode(agentId: String, modeId: String) async {
        guard let client else { return }
        do {
            _ = try await client.setAgentMode(agentId: agentId, modeId: modeId)
            patchAgent(id: agentId) { $0.withMode(modeId) }
        } catch { }
    }

    func setAgentModel(agentId: String, modelId: String?) async {
        guard let client else { return }
        do {
            _ = try await client.setAgentModel(agentId: agentId, modelId: modelId)
            patchAgent(id: agentId) { $0.withModel(modelId) }
        } catch { }
    }

    func setAgentThinking(agentId: String, thinkingOptionId: String?) async {
        guard let client else { return }
        do {
            _ = try await client.setAgentThinking(agentId: agentId, thinkingOptionId: thinkingOptionId)
            patchAgent(id: agentId) { $0.withThinking(thinkingOptionId) }
        } catch { }
    }

    private func patchAgent(id: String, _ body: (AgentSnapshot) -> AgentSnapshot) {
        if let idx = agents.firstIndex(where: { $0.id == id }) {
            agents[idx] = body(agents[idx])
        }
    }

    // MARK: - Usage quota

    func fetchUsage() async {
        let urlString = UserDefaults.standard.string(forKey: "paseomac.usageApiUrl") ?? ""
        let token     = UserDefaults.standard.string(forKey: "paseomac.usageApiToken") ?? ""
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return }

        var req = URLRequest(url: url)
        if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Usage-Token") }
        req.timeoutInterval = 15

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }

        struct Resp: Decodable {
            struct Period: Decodable {
                let utilization: Double?
                let resetsAt: String?
                enum CodingKeys: String, CodingKey {
                    case utilization; case resetsAt = "resets_at"
                }
            }
            let fiveHour: Period?
            let sevenDay: Period?
            let sevenDaySonnet: Period?
            let sevenDayOpus: Period?
            let subscriptionType: String?
            enum CodingKeys: String, CodingKey {
                case fiveHour = "five_hour"; case sevenDay = "seven_day"
                case sevenDaySonnet = "seven_day_sonnet"
                case sevenDayOpus = "seven_day_opus"
                case subscriptionType = "subscription_type"
            }
        }
        guard let parsed = try? JSONDecoder().decode(Resp.self, from: data) else { return }

        let isoFull: ISO8601DateFormatter = {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f
        }()
        func parseISO(_ s: String) -> Date? { isoFull.date(from: s) ?? ISO8601DateFormatter().date(from: s) }
        func clamp(_ v: Double) -> Int { Int(max(0, min(100, v.rounded()))) }
        func planName(_ sub: String) -> String {
            let l = sub.lowercased()
            if l.contains("max") { return "Max" }
            if l.contains("pro") { return "Pro" }
            if l.contains("team") { return "Team" }
            return sub.isEmpty ? "Claude.ai" : sub.capitalized
        }

        usageData = ClaudeUsageData(
            planName: planName(parsed.subscriptionType ?? ""),
            fiveHour: parsed.fiveHour?.utilization.map { clamp($0) },
            sevenDay: parsed.sevenDay?.utilization.map { clamp($0) },
            fiveHourResetAt: parsed.fiveHour?.resetsAt.flatMap(parseISO),
            sevenDayResetAt: parsed.sevenDay?.resetsAt.flatMap(parseISO),
            sevenDaySonnet: parsed.sevenDaySonnet?.utilization.flatMap { $0 > 0 ? clamp($0) : nil },
            sevenDaySonnetResetAt: parsed.sevenDaySonnet?.resetsAt.flatMap(parseISO),
            sevenDayOpus: parsed.sevenDayOpus?.utilization.flatMap { $0 > 0 ? clamp($0) : nil },
            sevenDayOpusResetAt: parsed.sevenDayOpus?.resetsAt.flatMap(parseISO),
            fetchedAt: Date()
        )
    }

    func fetchStats() async {
        let urlString = UserDefaults.standard.string(forKey: "paseomac.usageApiUrl") ?? ""
        let token     = UserDefaults.standard.string(forKey: "paseomac.usageApiToken") ?? ""
        guard !urlString.isEmpty,
              let usageURL = URL(string: urlString) else { return }
        let url = usageURL.deletingLastPathComponent().appendingPathComponent("claude-stats")

        var req = URLRequest(url: url)
        if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Usage-Token") }
        req.timeoutInterval = 15

        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return }

        struct StatsResp: Decodable {
            struct DailyActivity: Decodable {
                let date: String
                let messageCount: Int?
                let sessionCount: Int?
                let toolCallCount: Int?
            }
            struct DailyTokens: Decodable {
                let date: String
                let tokensByModel: [String: Int]
            }
            struct ModelEntry: Decodable {
                let inputTokens: Int?
                let outputTokens: Int?
                let cacheReadInputTokens: Int?
                let cacheCreationInputTokens: Int?
            }
            let lastComputedDate: String?
            let dailyActivity: [DailyActivity]?
            let dailyModelTokens: [DailyTokens]?
            let modelUsage: [String: ModelEntry]?
            let totalMessages: Int?
            let totalSessions: Int?
        }
        guard let parsed = try? JSONDecoder().decode(StatsResp.self, from: data) else { return }

        var tokensByDate: [String: [String: Int]] = [:]
        for entry in parsed.dailyModelTokens ?? [] {
            tokensByDate[entry.date] = entry.tokensByModel
        }

        var daily: [ClaudeStatsData.DailyEntry] = []
        for act in parsed.dailyActivity ?? [] {
            daily.append(ClaudeStatsData.DailyEntry(
                date: act.date,
                messageCount: act.messageCount ?? 0,
                sessionCount: act.sessionCount ?? 0,
                toolCallCount: act.toolCallCount ?? 0,
                tokensByModel: tokensByDate[act.date] ?? [:]
            ))
        }
        daily.sort { $0.date > $1.date }

        let models: [ClaudeStatsData.ModelUsage] = (parsed.modelUsage ?? [:]).map { key, val in
            ClaudeStatsData.ModelUsage(
                modelId: key,
                inputTokens: val.inputTokens ?? 0,
                outputTokens: val.outputTokens ?? 0,
                cacheReadTokens: val.cacheReadInputTokens ?? 0,
                cacheWriteTokens: val.cacheCreationInputTokens ?? 0
            )
        }.sorted { $0.apiEquivCostUSD > $1.apiEquivCostUSD }

        statsData = ClaudeStatsData(
            lastComputedDate: parsed.lastComputedDate ?? "",
            daily: daily,
            modelUsage: models,
            totalMessages: parsed.totalMessages ?? 0,
            totalSessions: parsed.totalSessions ?? 0
        )
    }

    // MARK: - Claude Code version

    private func claudeVersionBaseURL() -> URL? {
        let urlString = UserDefaults.standard.string(forKey: "paseomac.usageApiUrl") ?? ""
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        return url.deletingLastPathComponent()
    }

    func checkClaudeCodeVersion() async {
        guard !isCheckingClaudeCodeVersion else { return }
        isCheckingClaudeCodeVersion = true
        defer { isCheckingClaudeCodeVersion = false }

        let token = UserDefaults.standard.string(forKey: "paseomac.usageApiToken") ?? ""

        if let base = claudeVersionBaseURL() {
            let versionURL = base.appendingPathComponent("claude-code-version")
            var req = URLRequest(url: versionURL)
            if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Usage-Token") }
            req.timeoutInterval = 10
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONDecoder().decode([String: String].self, from: data),
               let v = json["version"] {
                claudeCodeCurrentVersion = v
            }
        }

        struct NpmResp: Decodable { let version: String }
        if let npmURL = URL(string: "https://registry.npmjs.org/@anthropic-ai/claude-code/latest") {
            var req = URLRequest(url: npmURL)
            req.timeoutInterval = 10
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let parsed = try? JSONDecoder().decode(NpmResp.self, from: data) {
                claudeCodeLatestVersion = parsed.version
            }
        }
    }

    func updateClaudeCode() async {
        guard !isUpdatingClaudeCode, let base = claudeVersionBaseURL() else { return }
        isUpdatingClaudeCode = true
        defer { isUpdatingClaudeCode = false }

        let versionBefore = claudeCodeCurrentVersion
        let token = UserDefaults.standard.string(forKey: "paseomac.usageApiToken") ?? ""
        let updateURL = base.appendingPathComponent("claude-code-update")
        var req = URLRequest(url: updateURL)
        req.httpMethod = "POST"
        if !token.isEmpty { req.setValue(token, forHTTPHeaderField: "X-Usage-Token") }
        req.timeoutInterval = 130

        _ = try? await URLSession.shared.data(for: req)
        await checkClaudeCodeVersion()

        // If version actually changed, cancel running agents so next message uses new Claude Code.
        // Context is preserved — Paseo resumes via session ID.
        if claudeCodeCurrentVersion != versionBefore {
            await cancelRunningAgentsForVersionUpdate()
        }
    }

    private func cancelRunningAgentsForVersionUpdate() async {
        guard let client else { return }
        let runningIds = agents
            .filter { (liveStatus[$0.id]?.status ?? $0.status) == "running" }
            .map(\.id)
        for agentId in runningIds {
            _ = try? await client.cancelAgent(agentId: agentId)
        }
    }

    // MARK: - Inbound events

    private func ingest(session: SessionInbound) async {
        switch session {
        case .agentStream(let msg):
            let agentId = msg.payload.agentId
            applyLiveStatus(agentId: agentId, event: msg.payload.event)
            switch msg.payload.event {
            case .turnStarted:
                EventLogger.shared.log("turn", "started", ["agent": agentId])
                // Fast-path for create-agent flow: turn_started for an
                // unknown agent id arrives ~3-4s before the agent_status
                // event we'd otherwise wait for. Resume the pending
                // continuation here so the new conversation pops in faster.
                if !knownAgentIds.contains(agentId),
                   let cont = pendingCreationContinuation {
                    pendingCreationContinuation = nil
                    cont.resume(returning: agentId)
                }
            case .turnCompleted:
                EventLogger.shared.log("turn", "completed", ["agent": agentId])
            case .turnFailed:
                EventLogger.shared.log("turn", "failed", ["agent": agentId])
            case .turnCanceled:
                EventLogger.shared.log("turn", "canceled", ["agent": agentId])
            case .attentionRequired(let reason):
                EventLogger.shared.log("turn", "attention", ["agent": agentId, "reason": reason])
            case .permissionRequested:
                EventLogger.shared.log("turn", "permission_requested", ["agent": agentId])
            default: break
            }
            let currentModel = agents.first(where: { $0.id == agentId })?.model
            let vm = conversation(for: agentId)
            vm.apply(
                streamEvent: msg.payload.event,
                seq: msg.payload.seq,
                timestamp: msg.payload.timestamp,
                currentModel: currentModel
            )
            // turn_completed used to trigger a 1.5s-delayed full refreshAgents.
            // The agent_status stream that follows already updates the snapshot
            // in place (see case .agentStatus below), so the full refresh is
            // redundant — drop it to save an RPC roundtrip per turn.
        case .agentStatus(let msg):
            if let snap = msg.payload.info {
                if let idx = agents.firstIndex(where: { $0.id == snap.id }) {
                    // Status pings often carry only the live status fields and
                    // leave model/provider/title/usage as null. A naive
                    // overwrite drops those, which kills the live "Opus · 2m"
                    // status bar (currentModel resolves via agents[idx].model).
                    // Merge non-nil snap fields into the existing snapshot.
                    agents[idx] = agents[idx].merging(snap)
                } else {
                    agents.insert(snap, at: 0)
                    // Seed the per-bubble model chip for the freshly-created
                    // agent. turn_started for new agents arrives ~1ms before
                    // this agent_status, so the apply(streamEvent:) call
                    // already saw currentModel: nil — without seeding here
                    // the first reply has no model and no duration chip.
                    if let m = snap.model {
                        conversations[snap.id]?.seedTurnModel(m)
                    }
                    if !knownAgentIds.contains(snap.id),
                       let cont = pendingCreationContinuation {
                        pendingCreationContinuation = nil
                        cont.resume(returning: snap.id)
                    }
                }
            }
            liveStatus[msg.payload.agentId] = LiveStatus(
                status: msg.payload.status,
                requiresAttention: msg.payload.info?.requiresAttention ?? false,
                attentionReason: msg.payload.info?.attentionReason
            )
            EventLogger.shared.log("status", msg.payload.status, ["agent": msg.payload.agentId])
            // Recover from missed turn_completed events: if the daemon now
            // reports idle but the conversation VM thinks it's still working,
            // reconcile so the spinner clears without restarting the app.
            conversations[msg.payload.agentId]?.reconcileAgentStatus(msg.payload.status)
        case .serverInfo(let info):
            daemonVersion = info.version
            daemonHostname = info.hostname
            versionMismatchDismissed = false
        case .status, .fetchAgentsResponse, .fetchAgentTimelineResponse,
             .sendAgentMessageResponse, .setAgentModeResponse, .setAgentModelResponse,
             .setAgentThinkingResponse, .getProvidersSnapshotResponse, .cancelAgentResponse,
             .unknown:
            break
        }
    }

    private func applyLiveStatus(agentId: String, event: AgentStreamEvent) {
        var live = liveStatus[agentId] ?? LiveStatus(
            status: agents.first(where: { $0.id == agentId })?.status ?? "idle",
            requiresAttention: false,
            attentionReason: nil
        )
        switch event {
        case .turnStarted:
            live.status = "running"
            live.requiresAttention = false
        case .turnCompleted:
            live.status = "idle"
        case .turnFailed, .turnCanceled:
            live.status = "idle"
            live.requiresAttention = true
        case .attentionRequired(let reason):
            live.requiresAttention = true
            live.attentionReason = reason
        case .permissionRequested:
            live.requiresAttention = true
            live.attentionReason = "permission"
        case .permissionResolved, .threadStarted, .timelineUpdated, .other:
            break
        }
        liveStatus[agentId] = live
    }
}

// MARK: - Snapshot mutation helpers

private extension AgentSnapshot {
    func withMode(_ modeId: String) -> AgentSnapshot {
        AgentSnapshot(
            id: id, provider: provider, cwd: cwd, status: status, title: title,
            createdAt: createdAt, updatedAt: updatedAt, lastUserMessageAt: lastUserMessageAt,
            model: model, thinkingOptionId: thinkingOptionId,
            effectiveThinkingOptionId: effectiveThinkingOptionId,
            currentModeId: modeId, availableModes: availableModes,
            lastUsage: lastUsage,
            archivedAt: archivedAt, requiresAttention: requiresAttention,
            attentionReason: attentionReason
        )
    }
    func withModel(_ modelId: String?) -> AgentSnapshot {
        AgentSnapshot(
            id: id, provider: provider, cwd: cwd, status: status, title: title,
            createdAt: createdAt, updatedAt: updatedAt, lastUserMessageAt: lastUserMessageAt,
            model: modelId, thinkingOptionId: thinkingOptionId,
            effectiveThinkingOptionId: effectiveThinkingOptionId,
            currentModeId: currentModeId, availableModes: availableModes,
            lastUsage: lastUsage,
            archivedAt: archivedAt, requiresAttention: requiresAttention,
            attentionReason: attentionReason
        )
    }
    func withThinking(_ optId: String?) -> AgentSnapshot {
        AgentSnapshot(
            id: id, provider: provider, cwd: cwd, status: status, title: title,
            createdAt: createdAt, updatedAt: updatedAt, lastUserMessageAt: lastUserMessageAt,
            model: model, thinkingOptionId: optId,
            effectiveThinkingOptionId: optId,
            currentModeId: currentModeId, availableModes: availableModes,
            lastUsage: lastUsage,
            archivedAt: archivedAt, requiresAttention: requiresAttention,
            attentionReason: attentionReason
        )
    }

    /// Merge another snapshot into this one. Non-nil scalar fields and
    /// always-present strings (status / updatedAt) come from `other`; any
    /// nil-in-other field falls back to the receiver. Used for `agent_status`
    /// stream pings that often only carry `status`/`updatedAt` and leave
    /// model/title/usage as null — a naive overwrite there blanks out the
    /// live "model · duration" status bar.
    func merging(_ other: AgentSnapshot) -> AgentSnapshot {
        AgentSnapshot(
            id: other.id,
            provider: other.provider ?? provider,
            cwd: other.cwd.isEmpty ? cwd : other.cwd,
            status: other.status,
            title: other.title ?? title,
            createdAt: other.createdAt.isEmpty ? createdAt : other.createdAt,
            updatedAt: other.updatedAt.isEmpty ? updatedAt : other.updatedAt,
            lastUserMessageAt: other.lastUserMessageAt ?? lastUserMessageAt,
            model: other.model ?? model,
            thinkingOptionId: other.thinkingOptionId ?? thinkingOptionId,
            effectiveThinkingOptionId: other.effectiveThinkingOptionId ?? effectiveThinkingOptionId,
            currentModeId: other.currentModeId ?? currentModeId,
            availableModes: other.availableModes ?? availableModes,
            lastUsage: other.lastUsage ?? lastUsage,
            archivedAt: other.archivedAt ?? archivedAt,
            requiresAttention: other.requiresAttention ?? requiresAttention,
            attentionReason: other.attentionReason ?? attentionReason
        )
    }
}


// MARK: - Stats data

struct ClaudeStatsData {
    struct DailyEntry: Identifiable {
        var id: String { date }
        let date: String
        let messageCount: Int
        let sessionCount: Int
        let toolCallCount: Int
        let tokensByModel: [String: Int]
        var totalTokens: Int { tokensByModel.values.reduce(0, +) }

        var displayDate: String {
            let parts = date.split(separator: "-")
            guard parts.count == 3,
                  let month = Int(parts[1]),
                  let day = Int(parts[2]),
                  month >= 1, month <= 12 else { return date }
            let months = ["Jan","Feb","Mar","Apr","May","Jun",
                          "Jul","Aug","Sep","Oct","Nov","Dec"]
            return "\(months[month - 1]) \(day)"
        }
    }

    struct ModelUsage: Identifiable {
        var id: String { modelId }
        let modelId: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheWriteTokens: Int

        var displayName: String {
            let l = modelId.lowercased()
            if l.contains("opus")   { return "Opus" }
            if l.contains("haiku")  { return "Haiku" }
            if l.contains("sonnet") { return "Sonnet" }
            return modelId
        }

        var apiEquivCostUSD: Double {
            let (pi, po, pr, pw) = pricing
            return Double(inputTokens)      / 1_000_000 * pi
                 + Double(outputTokens)     / 1_000_000 * po
                 + Double(cacheReadTokens)  / 1_000_000 * pr
                 + Double(cacheWriteTokens) / 1_000_000 * pw
        }

        private var pricing: (Double, Double, Double, Double) {
            let l = modelId.lowercased()
            if l.contains("opus")  { return (15,   75,   1.50, 3.75) }
            if l.contains("haiku") { return (0.80,  4,   0.08, 1.00) }
            return                          (3,     15,  0.30, 0.75)
        }
    }

    let lastComputedDate: String
    let daily: [DailyEntry]
    let modelUsage: [ModelUsage]
    let totalMessages: Int
    let totalSessions: Int

    static func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) }
        if n >= 1_000_000     { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000         { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }

    static func fmtCost(_ usd: Double) -> String {
        if usd >= 10_000 { return String(format: "$%.0fK", usd / 1000) }
        if usd >= 100    { return String(format: "$%.0f",  usd) }
        if usd >= 1      { return String(format: "$%.1f",  usd) }
        return String(format: "$%.2f", usd)
    }
}
