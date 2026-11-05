import Foundation

/// Read-only reset counts and validity bounds. Redemption identifiers are never decoded or stored.
public struct ResetInventory: Equatable, Sendable {
    struct Grant: Equatable, Sendable {
        let count: Int
        let startsAt: Date?
        let expiresAt: Date?
    }
    private let grants: [Grant]

    public init(count: Int) {
        grants = [Grant(count: max(0, count), startsAt: nil, expiresAt: nil)]
    }

    init(grants: [Grant]) { self.grants = grants }

    public func availableCount(at now: Date = .now) -> Int {
        grants.reduce(0) { total, grant in
            guard grant.startsAt.map({ $0 <= now }) ?? true,
                  grant.expiresAt.map({ $0 > now }) ?? true else { return total }
            return total + grant.count
        }
    }
}

public enum ResetParser {
    public static func openai(_ data: Data) -> ResetInventory? {
        guard let response = try? JSONDecoder().decode(OpenAIResets.self, from: data),
              (0...1000).contains(response.available_count) else { return nil }
        guard let credits = response.credits else { return ResetInventory(count: response.available_count) }
        guard credits.count <= 1000 else { return nil }
        let available = credits.filter { $0.status == "available" }
        guard available.count == response.available_count else { return nil }
        do {
            return ResetInventory(grants: try available.map {
                .init(count: 1, startsAt: nil, expiresAt: try date($0.expires_at))
            })
        } catch { return nil }
    }

    public static func anthropic(_ data: Data) -> ResetInventory? {
        guard let response = try? JSONDecoder().decode(AnthropicResets.self, from: data),
              let status = response.cedar_ember, status.eligible, status.grants.count <= 200 else { return nil }
        var grants: [ResetInventory.Grant] = []
        var total = 0
        do {
            for grant in status.grants {
                guard (0...50).contains(grant.resets_left),
                      grant.resets_total.map({ $0 >= grant.resets_left }) ?? true else { return nil }
                let startsAt = try date(grant.starts_at)
                let expiresAt = try date(grant.ends_at)
                guard !grant.paused else { continue }
                total += grant.resets_left
                guard total <= 50 else { return nil }
                grants.append(.init(count: grant.resets_left, startsAt: startsAt, expiresAt: expiresAt))
            }
            return ResetInventory(grants: grants)
        } catch { return nil }
    }

    private static func date(_ value: String?) throws -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        guard let result = formatter.date(from: value) else { throw UsageError.invalidResponse }
        return result
    }

    private struct OpenAIResets: Decodable {
        let available_count: Int
        let credits: [Credit]?
        struct Credit: Decodable {
            let status: String
            let expires_at: String?
        }
    }

    private struct AnthropicResets: Decodable {
        let cedar_ember: Status?
        struct Status: Decodable {
            let eligible: Bool
            let grants: [Grant]
        }
        struct Grant: Decodable {
            let resets_left: Int
            let resets_total: Int?
            let paused: Bool
            let starts_at: String?
            let ends_at: String?
        }
    }
}
