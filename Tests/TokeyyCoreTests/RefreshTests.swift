import Foundation
import Testing
@testable import TokeyyCore

private actor RefreshClient: UsageFetching {
    private(set) var calls = 0
    let snapshot: UsageSnapshot
    init(age: TimeInterval = 0) throws {
        snapshot = UsageSnapshot(session: try UsageWindow(used: 31, resetsAt: .now.addingTimeInterval(3600)),
                                 weekly: nil, plan: nil, fetchedAt: .now.addingTimeInterval(-age))
    }
    func fetch(_ provider: Provider, allowKeychainPrompt: Bool) async throws -> UsageSnapshot {
        calls += 1
        return snapshot
    }
}

@Test func providerSettingsLinksAreCorrect() {
    #expect(Provider.openai.dashboard.absoluteString == "https://chatgpt.com/settings/usage")
    #expect(Provider.anthropic.dashboard.absoluteString == "https://claude.ai/settings/usage")
}

@MainActor @Test(arguments: RefreshInterval.allCases)
func automaticRefreshRespectsSelectedInterval(_ interval: RefreshInterval) async throws {
    let client = try RefreshClient()
    let store = UsageStore(defaults: nil, client: client)
    store.refreshInterval = interval
    let started = Date.now
    await store.connect(.openai)
    await store.refreshDue(now: started.addingTimeInterval(interval.seconds - 1))
    #expect(await client.calls == 1)
    await store.refreshDue(now: started.addingTimeInterval(interval.seconds + 1))
    #expect(await client.calls == 2)
    await store.refreshDue(now: started.addingTimeInterval(interval.seconds + 2))
    #expect(await client.calls == 2)
}

@MainActor @Test func longerIntervalDoesNotPrematurelyHideUsage() async throws {
    let store = UsageStore(defaults: nil, client: try RefreshClient(age: 901))
    await store.connect(.openai)
    #expect(store.menuPercentage == nil)
    store.refreshInterval = .fifteenMinutes
    #expect(store.menuPercentage == 69)
}

@MainActor @Test func invalidSavedRefreshIntervalUsesDefault() {
    let name = "TokeyyTests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(-1, forKey: "refreshInterval")
    #expect(UsageStore(defaults: defaults).refreshInterval == .fiveMinutes)
    #expect(UsageStore(defaults: nil).refreshInterval == .fiveMinutes)
}
