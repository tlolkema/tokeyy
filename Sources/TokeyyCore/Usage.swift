import Foundation

public enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case openai, anthropic
    public var id: String { rawValue }
    public var name: String { self == .openai ? "OpenAI" : "Anthropic" }
    public var product: String { self == .openai ? "Codex" : "Claude" }
    public var loginCommand: String { self == .openai ? "codex login" : "claude auth login" }
    public var dashboard: URL {
        URL(string: self == .openai
            ? "https://chatgpt.com/settings/usage"
            : "https://claude.ai/settings/usage")!
    }
}

public enum UsagePeriod: String, Codable, CaseIterable, Identifiable, Sendable {
    case session, weekly
    public var id: String { rawValue }
    public var title: String { self == .session ? "Session" : "Weekly" }
}

public struct UsageWindow: Equatable, Sendable {
    public let remaining: Double
    public let resetsAt: Date?
    public var percentage: Int { Int(remaining.rounded(.down)) }

    public init(used: Double, resetsAt: Date?) throws {
        guard used.isFinite else { throw UsageError.invalidResponse }
        self.remaining = min(100, max(0, 100 - used))
        if let resetsAt, resetsAt.timeIntervalSince1970.isFinite,
           (0...253_402_300_799).contains(resetsAt.timeIntervalSince1970) {
            self.resetsAt = resetsAt
        } else {
            self.resetsAt = nil
        }
    }

    public func resetDescription(now: Date = .now) -> String {
        guard let resetsAt else { return "Reset time unavailable" }
        let seconds = resetsAt.timeIntervalSince(now)
        guard seconds > 0 else { return "Awaiting reset" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes < 60 { return "Resets in \(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return "Resets in \(hours)h" + (remainder > 0 ? " \(remainder)m" : "")
        }
        let days = hours / 24
        let remainder = hours % 24
        return "Resets in \(days)d" + (remainder > 0 ? " \(remainder)h" : "")
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public let session: UsageWindow?
    public let weekly: UsageWindow?
    public let plan: String?
    public let fetchedAt: Date
    public let resets: ResetInventory?

    public init(session: UsageWindow?, weekly: UsageWindow?, plan: String?, fetchedAt: Date = .now,
                resets: ResetInventory? = nil) {
        self.session = session
        self.weekly = weekly
        self.plan = plan
        self.fetchedAt = fetchedAt
        self.resets = resets
    }

    public func withResets(_ inventory: ResetInventory?) -> UsageSnapshot {
        UsageSnapshot(session: session, weekly: weekly, plan: plan, fetchedAt: fetchedAt, resets: inventory)
    }

    public subscript(period: UsagePeriod) -> UsageWindow? {
        period == .session ? session : weekly
    }

    public func isStale(now: Date = .now, maximumAge: TimeInterval = 600) -> Bool {
        now.timeIntervalSince(fetchedAt) > maximumAge
    }
}

public enum UsageError: Error, LocalizedError, Equatable, Sendable {
    case noCredentials(Provider)
    case invalidCredentials(Provider)
    case expired(Provider)
    case keychainDenied
    case invalidResponse
    case rateLimited(seconds: Int)
    case server(Int)

    public var errorDescription: String? {
        switch self {
        case .noCredentials(let provider):
            "Sign in to \(provider.product) on this Mac, then connect again."
        case .invalidCredentials(let provider):
            "No subscription sign-in found. Sign in to \(provider.product) with a subscription account, then retry."
        case .expired(let provider):
            "Your sign-in expired. Open \(provider.product) to renew it, then refresh Tokeyy."
        case .keychainDenied:
            "Keychain access was denied. Allow Tokeyy to read the Claude Code sign-in, then try again."
        case .invalidResponse:
            "The provider returned usage data Tokeyy cannot read. Try again later."
        case .rateLimited(let seconds):
            "The provider requested a pause. Try again in \(max(1, Int(ceil(Double(seconds) / 60)))) minutes."
        case .server(let code):
            "Usage is unavailable (HTTP \(code)). Try again later."
        }
    }
}

public enum UsageParser {
    public static func parse(_ data: Data, provider: Provider, now: Date = .now) throws -> UsageSnapshot {
        do {
            switch provider {
            case .openai:
                let response = try JSONDecoder().decode(OpenAIResponse.self, from: data)
                let primary = response.rate_limit?.primary_window
                let secondary = response.rate_limit?.secondary_window
                // A weekly-only plan must not be mislabeled as a five-hour session.
                let primaryIsWeekly = (primary?.limit_window_seconds ?? 0) >= 6 * 24 * 3600
                let session = try primaryIsWeekly ? nil : primary?.window(now: now)
                let weekly = try (primaryIsWeekly ? primary : secondary)?.window(now: now)
                guard session != nil || weekly != nil else { throw UsageError.invalidResponse }
                return UsageSnapshot(session: session, weekly: weekly, plan: response.plan_type, fetchedAt: now)
            case .anthropic:
                let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
                let session = try response.five_hour?.window()
                let weekly = try response.seven_day?.window()
                guard session != nil || weekly != nil else { throw UsageError.invalidResponse }
                return UsageSnapshot(session: session, weekly: weekly, plan: nil, fetchedAt: now,
                                     resets: ResetParser.anthropic(data))
            }
        } catch let error as UsageError { throw error }
        catch { throw UsageError.invalidResponse }
    }

    private struct OpenAIResponse: Decodable {
        let plan_type: String?
        let rate_limit: Limits?
        struct Limits: Decodable {
            let primary_window: Window?
            let secondary_window: Window?
        }
        struct Window: Decodable {
            let used_percent: Double
            let reset_at: Double?
            let reset_after_seconds: Double?
            let limit_window_seconds: Double?
            func window(now: Date) throws -> UsageWindow {
                let date = reset_at.map(Date.init(timeIntervalSince1970:))
                    ?? reset_after_seconds.map { now.addingTimeInterval($0) }
                return try UsageWindow(used: used_percent, resetsAt: date)
            }
        }
    }

    private struct AnthropicResponse: Decodable {
        let five_hour: Window?
        let seven_day: Window?
        struct Window: Decodable {
            let utilization: Double
            let resets_at: String?
            func window() throws -> UsageWindow {
                var date: Date?
                if let resets_at {
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    date = formatter.date(from: resets_at)
                    if date == nil {
                        formatter.formatOptions = [.withInternetDateTime]
                        date = formatter.date(from: resets_at)
                    }
                }
                return try UsageWindow(used: utilization, resetsAt: date)
            }
        }
    }
}
