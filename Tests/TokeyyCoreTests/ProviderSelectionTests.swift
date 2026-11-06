import Foundation
import Testing
@testable import TokeyyCore

private struct ConnectedClient: UsageFetching {
    func fetch(_ provider: Provider, allowKeychainPrompt: Bool) async throws -> UsageSnapshot {
        UsageSnapshot(session: try UsageWindow(used: 31, resetsAt: .now.addingTimeInterval(3600)),
                      weekly: nil, plan: nil)
    }
}

@MainActor @Test func noConnectionsHideProviderSwitcher() {
    let store = UsageStore(defaults: nil)
    #expect(store.connectedProviders.isEmpty)
    #expect(!store.shouldShowProviderSwitcher)
}

@MainActor @Test(arguments: Provider.allCases)
func oneConnectionShowsItsUsageWithoutSwitcher(_ provider: Provider) async {
    let store = UsageStore(defaults: nil, client: ConnectedClient())
    await store.connect(provider)
    #expect(store.connectedProviders == [provider])
    #expect(!store.shouldShowProviderSwitcher)
    #expect(store.selected == provider)
    #expect(store.menuPercentage == 69)
}

@MainActor @Test func switcherOnlyAppearsWhileBothProvidersAreConnected() async {
    let store = UsageStore(defaults: nil, client: ConnectedClient())
    await store.connect(.openai)
    await store.connect(.anthropic)
    #expect(store.connectedProviders == Provider.allCases)
    #expect(store.shouldShowProviderSwitcher)
    store.disconnect(.anthropic)
    #expect(!store.shouldShowProviderSwitcher)
    #expect(store.selected == .openai)
    #expect(store.menuPercentage == 69)
    store.disconnect(.openai)
    #expect(store.connectedProviders.isEmpty)
    #expect(!store.shouldShowProviderSwitcher)
}

@MainActor @Test(arguments: Provider.allCases)
func startupSelectsTheOnlyConnectedProvider(_ provider: Provider) {
    let name = "TokeyyTests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    defaults.set(provider == .openai ? "anthropic" : "openai", forKey: "provider")
    defaults.set(true, forKey: "connected.\(provider.rawValue)")
    let store = UsageStore(defaults: defaults)
    #expect(store.selected == provider)
    #expect(store.current.connected)
    #expect(!store.shouldShowProviderSwitcher)
}
