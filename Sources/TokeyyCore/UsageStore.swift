import Foundation
import Observation

public enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case system, light, dark
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum RefreshInterval: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60, twoMinutes = 120, fiveMinutes = 300, fifteenMinutes = 900
    public var id: Int { rawValue }
    public var seconds: TimeInterval { TimeInterval(rawValue) }
    public var title: String { rawValue == 60 ? "1 minute" : "\(rawValue / 60) minutes" }
}

public struct ProviderState: Sendable {
    public var connected = false
    public var isLoading = false
    public var snapshot: UsageSnapshot?
    public var error: String?
    public var retryAfter: Date?
    fileprivate var lastAttemptAt: Date?
    fileprivate var generation = UUID()
    public init() {}
}

@MainActor @Observable
public final class UsageStore {
    public var selected: Provider { didSet { defaults?.set(selected.rawValue, forKey: "provider") } }
    public var period: UsagePeriod { didSet { defaults?.set(period.rawValue, forKey: "period") } }
    public var appearance: Appearance { didSet { defaults?.set(appearance.rawValue, forKey: "appearance") } }
    public var refreshInterval: RefreshInterval { didSet { defaults?.set(refreshInterval.rawValue, forKey: "refreshInterval") } }
    public var showAvailableResets: Bool { didSet { defaults?.set(showAvailableResets, forKey: "showAvailableResets") } }
    public private(set) var states: [Provider: ProviderState]
    public let isDemo: Bool
    @ObservationIgnored private let defaults: UserDefaults?
    @ObservationIgnored private let client: any UsageFetching

    public init(defaults: UserDefaults? = .standard, client: any UsageFetching = UsageClient(), demo: Bool = false) {
        self.defaults = demo ? nil : defaults
        self.client = client
        self.isDemo = demo
        selected = Provider(rawValue: defaults?.string(forKey: "provider") ?? "") ?? .openai
        period = UsagePeriod(rawValue: defaults?.string(forKey: "period") ?? "") ?? .session
        appearance = Appearance(rawValue: defaults?.string(forKey: "appearance") ?? "") ?? .system
        refreshInterval = RefreshInterval(rawValue: defaults?.integer(forKey: "refreshInterval") ?? 0) ?? .fiveMinutes
        showAvailableResets = defaults?.bool(forKey: "showAvailableResets") ?? false
        states = Dictionary(uniqueKeysWithValues: Provider.allCases.map { provider in
            var state = ProviderState()
            state.connected = !demo && (defaults?.bool(forKey: "connected.\(provider.rawValue)") ?? false)
            return (provider, state)
        })
        if demo {
            selected = .openai
            period = .session
            appearance = .system
            refreshInterval = .fiveMinutes
            showAvailableResets = false
            for provider in Provider.allCases {
                var state = ProviderState()
                state.connected = true
                state.snapshot = UsageSnapshot(
                    session: try! UsageWindow(used: provider == .openai ? 31 : 48, resetsAt: .now.addingTimeInterval(2 * 3600 + 24 * 60)),
                    weekly: try! UsageWindow(used: provider == .openai ? 16 : 38, resetsAt: .now.addingTimeInterval(4 * 86400 + 19 * 3600)),
                    plan: provider == .openai ? "plus" : "pro", resets: ResetInventory(count: 2))
                states[provider] = state
            }
        }
    }

    public var current: ProviderState { states[selected] ?? ProviderState() }
    public var menuPercentage: Int? {
        guard current.connected, current.error == nil, let snapshot = current.snapshot,
              !snapshot.isStale(maximumAge: max(600, refreshInterval.seconds * 2)), let window = snapshot[period],
              window.resetsAt.map({ $0 > .now }) ?? true else { return nil }
        return window.percentage
    }

    public func connect(_ provider: Provider) async {
        guard !isDemo else { return }
        states[provider]?.connected = true
        defaults?.set(true, forKey: "connected.\(provider.rawValue)")
        selected = provider
        await refresh(provider, allowKeychainPrompt: true)
    }

    public func disconnect(_ provider: Provider) {
        states[provider] = ProviderState()
        defaults?.set(false, forKey: "connected.\(provider.rawValue)")
        if selected == provider, let other = Provider.allCases.first(where: { states[$0]?.connected == true }) {
            selected = other
        }
    }

    public func refreshDue(now: Date = .now) async {
        await refreshAll(minimumAge: refreshInterval.seconds, now: now)
    }

    public func refreshAll(minimumAge: TimeInterval = 60, now: Date = .now) async {
        await withTaskGroup(of: Void.self) { group in
            for provider in Provider.allCases where states[provider]?.connected == true {
                guard states[provider]?.lastAttemptAt.map({ now.timeIntervalSince($0) >= minimumAge }) ?? true else { continue }
                group.addTask { await self.refresh(provider, now: now) }
            }
        }
    }

    public func refresh(_ provider: Provider, allowKeychainPrompt: Bool = false, now: Date = .now) async {
        guard !isDemo, let state = states[provider], state.connected, !state.isLoading,
              state.retryAfter.map({ $0 <= now }) ?? true else { return }
        let generation = state.generation
        let includeResets = showAvailableResets
        states[provider]?.isLoading = true
        states[provider]?.lastAttemptAt = now
        defer {
            if states[provider]?.generation == generation {
                states[provider]?.isLoading = false
                if !includeResets && showAvailableResets {
                    Task { await self.refresh(provider) }
                }
            }
        }
        do {
            let snapshot = try await client.fetch(provider, allowKeychainPrompt: allowKeychainPrompt, includeResets: includeResets)
            guard states[provider]?.generation == generation else { return }
            states[provider]?.snapshot = snapshot
            states[provider]?.error = nil
            states[provider]?.retryAfter = nil
        } catch {
            guard states[provider]?.generation == generation else { return }
            if error is CancellationError { return }
            if case UsageError.rateLimited(let seconds) = error {
                states[provider]?.retryAfter = now.addingTimeInterval(Double(seconds))
            }
            states[provider]?.error = (error as? UsageError)?.localizedDescription
                ?? "Could not reach \(provider.name). Check your internet connection and try again."
        }
    }
}
