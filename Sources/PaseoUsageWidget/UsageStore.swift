import Foundation
import Combine

/// Subscription usage snapshot for the active claude.ai plan, mirroring the
/// shape PaseoMac uses so the rendering code can be copied verbatim.
struct ClaudeUsageData: Sendable {
    let planName: String
    let fiveHour: Int?
    let sevenDay: Int?
    let fiveHourResetAt: Date?
    let sevenDayResetAt: Date?
    let sevenDaySonnet: Int?
    let sevenDaySonnetResetAt: Date?
    let sevenDayOpus: Int?
    let sevenDayOpusResetAt: Date?
    let fetchedAt: Date

    var fetchedTimestamp: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: fetchedAt)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var usage: ClaudeUsageData? = nil
    @Published var lastError: String? = nil
    @Published var isRefreshing: Bool = false

    /// API endpoint + token are looked up first from this widget's own
    /// defaults; if not set, we fall back to PaseoMac's UserDefaults
    /// (suite name `sh.paseo.mac.client`) so the user only has to configure
    /// the proxy in one place. The widget exposes the same two keys for
    /// people who want to point it at a different endpoint independently.
    private static let urlKey = "usageApiUrl"
    private static let tokenKey = "usageApiToken"
    private static let paseoMacSuite = "sh.paseo.mac.client"
    private static let paseoMacUrlKey = "paseomac.usageApiUrl"
    private static let paseoMacTokenKey = "paseomac.usageApiToken"

    func resolvedEndpoint() -> (url: URL, token: String)? {
        let ud = UserDefaults.standard
        var urlString = ud.string(forKey: Self.urlKey) ?? ""
        var token = ud.string(forKey: Self.tokenKey) ?? ""
        if urlString.isEmpty || token.isEmpty,
           let suite = UserDefaults(suiteName: Self.paseoMacSuite) {
            if urlString.isEmpty {
                urlString = suite.string(forKey: Self.paseoMacUrlKey) ?? ""
            }
            if token.isEmpty {
                token = suite.string(forKey: Self.paseoMacTokenKey) ?? ""
            }
        }
        guard !urlString.isEmpty, let url = URL(string: urlString), !token.isEmpty else {
            return nil
        }
        return (url, token)
    }

    func refresh() async {
        guard let resolved = resolvedEndpoint() else {
            lastError = "Set Usage API URL + token in PaseoMac, or via `defaults write sh.paseo.usage-widget …`"
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        var req = URLRequest(url: resolved.url)
        req.setValue(resolved.token, forHTTPHeaderField: "X-Usage-Token")
        req.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                lastError = "HTTP \(http.statusCode)"
                return
            }
            let parsed = try JSONDecoder().decode(Resp.self, from: data)
            usage = ClaudeUsageData(
                planName: planName(parsed.subscriptionType ?? ""),
                fiveHour: parsed.fiveHour?.utilization.map { clamp($0) },
                sevenDay: parsed.sevenDay?.utilization.map { clamp($0) },
                fiveHourResetAt: parsed.fiveHour?.resetsAt.flatMap(Self.parseISO),
                sevenDayResetAt: parsed.sevenDay?.resetsAt.flatMap(Self.parseISO),
                sevenDaySonnet: parsed.sevenDaySonnet?.utilization.flatMap { $0 > 0 ? clamp($0) : nil },
                sevenDaySonnetResetAt: parsed.sevenDaySonnet?.resetsAt.flatMap(Self.parseISO),
                sevenDayOpus: parsed.sevenDayOpus?.utilization.flatMap { $0 > 0 ? clamp($0) : nil },
                sevenDayOpusResetAt: parsed.sevenDayOpus?.resetsAt.flatMap(Self.parseISO),
                fetchedAt: Date()
            )
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func clamp(_ v: Double) -> Int { Int(max(0, min(100, v.rounded()))) }
    private func planName(_ sub: String) -> String {
        let l = sub.lowercased()
        if l.contains("max") { return "Max" }
        if l.contains("pro") { return "Pro" }
        if l.contains("team") { return "Team" }
        return sub.isEmpty ? "Claude.ai" : sub.capitalized
    }

    private static let isoFull: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseISO(_ s: String) -> Date? {
        isoFull.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    /// Wire shape of the VPS proxy response. Matches PaseoMac's `fetchUsage`.
    private struct Resp: Decodable {
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
}
