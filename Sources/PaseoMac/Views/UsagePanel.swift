import SwiftUI
import Foundation

// MARK: - Data

struct ClaudeUsageData {
    let planName: String
    let fiveHour: Int?
    let sevenDay: Int?
    let fiveHourResetAt: Date?
    let sevenDayResetAt: Date?
}

// MARK: - API response

private struct UsageResponse: Decodable {
    let fiveHour: Period?
    let sevenDay: Period?
    let subscriptionType: String?

    struct Period: Decodable {
        let utilization: Double?
        let resetsAt: String?
        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }
    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case subscriptionType = "subscription_type"
    }
}

// MARK: - ViewModel

@MainActor
@Observable
final class UsageViewModel {
    enum State { case idle, loading, loaded(ClaudeUsageData), unconfigured, failed(String) }

    var state: State = .idle
    private var lastFetchedAt: Date? = nil

    private let urlKey   = "paseomac.usageApiUrl"
    private let tokenKey = "paseomac.usageApiToken"

    func refreshIfNeeded() async {
        switch state {
        case .loading, .unconfigured: return
        case .loaded:
            if let last = lastFetchedAt, Date().timeIntervalSince(last) < 300 { return }
        case .idle, .failed: break
        }
        await fetch()
    }

    func fetch() async {
        let urlString = UserDefaults.standard.string(forKey: urlKey) ?? ""
        let token     = UserDefaults.standard.string(forKey: tokenKey) ?? ""

        guard !urlString.isEmpty, let url = URL(string: urlString) else {
            state = .unconfigured
            return
        }

        state = .loading
        do {
            var req = URLRequest(url: url)
            if !token.isEmpty {
                req.setValue(token, forHTTPHeaderField: "X-Usage-Token")
            }
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let parsed = try JSONDecoder().decode(UsageResponse.self, from: data)
            state = .loaded(ClaudeUsageData(
                planName: makePlanName(parsed.subscriptionType ?? ""),
                fiveHour: parsed.fiveHour?.utilization.map { clamp($0) },
                sevenDay: parsed.sevenDay?.utilization.map { clamp($0) },
                fiveHourResetAt: parsed.fiveHour?.resetsAt.flatMap(parseISO),
                sevenDayResetAt: parsed.sevenDay?.resetsAt.flatMap(parseISO)
            ))
            lastFetchedAt = Date()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func clamp(_ v: Double) -> Int { Int(max(0, min(100, v.rounded()))) }

    private func makePlanName(_ sub: String) -> String {
        let l = sub.lowercased()
        if l.contains("max")  { return "Max"  }
        if l.contains("pro")  { return "Pro"  }
        if l.contains("team") { return "Team" }
        return sub.isEmpty ? "Claude.ai" : sub.capitalized
    }
}

private func parseISO(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
}

// MARK: - View

struct UsagePanel: View {
    @State private var vm = UsageViewModel()

    var body: some View {
        // Color.clear with fixed height ensures this view always has presence in
        // the hierarchy, so .onAppear fires even before data is loaded.
        Color.clear
            .frame(height: 0)
            .onAppear { Task { await vm.refreshIfNeeded() } }
            .onChange(of: vm.state.isLoaded) { _, loaded in
                _ = loaded  // observe state changes
            }

        if case .loaded(let usage) = vm.state {
            loadedView(usage)
        }
    }

    private func loadedView(_ usage: ClaudeUsageData) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(usage.planName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { Task { await vm.fetch() } } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Refresh usage")
            }
            if let pct = usage.fiveHour {
                UsageBar(label: "5h", percent: pct, resetAt: usage.fiveHourResetAt)
            }
            if let pct = usage.sevenDay {
                UsageBar(label: "7d", percent: pct, resetAt: usage.sevenDayResetAt)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}

private extension UsageViewModel.State {
    var isLoaded: Bool {
        if case .loaded = self { return true }
        return false
    }
}

private struct UsageBar: View {
    let label: String
    let percent: Int
    let resetAt: Date?

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(width: 14, alignment: .leading)
            ProgressView(value: Double(percent), total: 100)
                .progressViewStyle(.linear)
                .tint(barColor)
            Text("\(percent)%")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(barColor)
                .frame(width: 30, alignment: .trailing)
        }
        .help(helpText)
    }

    private var barColor: Color {
        percent >= 90 ? .red : percent >= 70 ? .orange : .blue
    }

    private var helpText: String {
        guard let reset = resetAt else { return "" }
        let interval = reset.timeIntervalSinceNow
        if interval <= 0 { return "Resetting…" }
        let h = Int(interval / 3600)
        let m = Int(interval.truncatingRemainder(dividingBy: 3600) / 60)
        if h >= 24 { return "Resets in \(h / 24)d \(h % 24)h" }
        if h > 0   { return "Resets in \(h)h \(m)m" }
        return "Resets in \(m)m"
    }
}
