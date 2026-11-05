import Foundation
import Testing
@testable import TokeyyCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let codexFixture = Data(#"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":31,"reset_at":1800003600,"limit_window_seconds":18000},"secondary_window":{"used_percent":16,"reset_at":1800400000,"limit_window_seconds":604800}}}"#.utf8)
private let claudeFixture = Data(#"{"five_hour":{"utilization":48.3,"resets_at":"2027-01-15T10:00:00.123Z"},"seven_day":{"utilization":38,"resets_at":"2027-01-19T10:00:00Z"}}"#.utf8)

@Test func codexUsageIsRemainingNotUsed() throws {
    let snapshot = try UsageParser.parse(codexFixture, provider: .openai, now: now)
    #expect(snapshot.session?.percentage == 69)
    #expect(snapshot.weekly?.percentage == 84)
    #expect(snapshot.session?.resetsAt == now.addingTimeInterval(3600))
    #expect(snapshot.plan == "plus")
    #expect(snapshot.fetchedAt == now)
}

@Test func claudeSupportsFractionalUtilizationAndBothDateFormats() throws {
    let snapshot = try UsageParser.parse(claudeFixture, provider: .anthropic)
    #expect(snapshot.session?.percentage == 51)
    #expect(snapshot.weekly?.percentage == 62)
    #expect(snapshot.session?.resetsAt != nil)
    #expect(snapshot.weekly?.resetsAt != nil)
}

@Test(arguments: [-20.0, 0, 69, 100, 120]) func percentagesAreClamped(used: Double) throws {
    let value = try UsageWindow(used: used, resetsAt: nil)
    #expect((0...100).contains(value.percentage))
    #expect(value.remaining == min(100, max(0, 100 - used)))
}

@Test func nonFiniteUsageIsRejected() {
    #expect(throws: UsageError.invalidResponse) { try UsageWindow(used: .nan, resetsAt: nil) }
    #expect(throws: UsageError.invalidResponse) { try UsageWindow(used: .infinity, resetsAt: nil) }
}

@Test(arguments: ["{}", "not json", #"{"rate_limit":null}"#, #"{"rate_limit":{"primary_window":{"used_percent":"bad"}}}"#])
func malformedOpenAIUsageIsNotZeroOrFull(_ json: String) {
    #expect(throws: UsageError.invalidResponse) { try UsageParser.parse(Data(json.utf8), provider: .openai) }
}

@Test func missingWindowsStayUnknown() throws {
    let snapshot = try UsageParser.parse(Data(#"{"five_hour":null,"seven_day":{"utilization":0,"resets_at":null}}"#.utf8), provider: .anthropic)
    #expect(snapshot.session == nil)
    #expect(snapshot.weekly?.percentage == 100)
    #expect(snapshot.weekly?.resetsAt == nil)
}

@Test func weeklyOnlyOpenAIPlanIsNotMislabeled() throws {
    let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":604800}}}"#.utf8)
    let snapshot = try UsageParser.parse(data, provider: .openai)
    #expect(snapshot.session == nil)
    #expect(snapshot.weekly?.percentage == 80)
}

@Test func relativeOpenAIReset() throws {
    let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":10,"reset_after_seconds":30}}}"#.utf8)
    let snapshot = try UsageParser.parse(data, provider: .openai, now: now)
    #expect(snapshot.session?.resetsAt == now.addingTimeInterval(30))
}

@Test(arguments: [(30.0, "Resets in 1m"), (1320, "Resets in 22m"), (8640, "Resets in 2h 24m"), (414000, "Resets in 4d 19h"), (-30, "Awaiting reset")])
func resetLabels(_ pair: (Double, String)) throws {
    let window = try UsageWindow(used: 0, resetsAt: now.addingTimeInterval(pair.0))
    #expect(window.resetDescription(now: now) == pair.1)
}

@Test func staleDataIsDetected() throws {
    let snapshot = try UsageParser.parse(codexFixture, provider: .openai, now: now)
    #expect(!snapshot.isStale(now: now.addingTimeInterval(599)))
    #expect(snapshot.isStale(now: now.addingTimeInterval(601)))
}

@Test func parsesCodexSubscriptionCredentials() throws {
    let credentials = try Credentials.parse(Data(#"{"tokens":{"access_token":"test-token","account_id":"account-123"}}"#.utf8), provider: .openai)
    #expect(credentials.accessToken == "test-token")
    #expect(credentials.accountID == "account-123")
}

@Test func apiKeysCannotStandInForSubscriptions() {
    #expect(throws: UsageError.invalidCredentials(.openai)) {
        try Credentials.parse(Data(#"{"OPENAI_API_KEY":"sk-test"}"#.utf8), provider: .openai)
    }
    #expect(throws: UsageError.invalidCredentials(.anthropic)) {
        try Credentials.parse(Data(#"{"mcpOAuth":{}}"#.utf8), provider: .anthropic)
    }
}

@Test func parsesClaudeMillisecondExpiry() throws {
    let credentials = try Credentials.parse(Data(#"{"claudeAiOauth":{"accessToken":"test-token","expiresAt":1800000000000}}"#.utf8), provider: .anthropic)
    #expect(credentials.expiresAt == now)
}

@Test func parsesJWTExpiry() throws {
    let payload = Data(#"{"exp":1800000000}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
    let data = Data("{\"tokens\":{\"access_token\":\"header.\(payload).signature\"}}".utf8)
    let credentials = try Credentials.parse(data, provider: .openai)
    #expect(credentials.expiresAt == now)
}

@Test func emptyTokensAreRejected() {
    #expect(throws: UsageError.invalidCredentials(.openai)) {
        try Credentials.parse(Data(#"{"tokens":{"access_token":"   "}}"#.utf8), provider: .openai)
    }
}

@Test func requestsUseCorrectEndpointsAndHeaders() throws {
    let credentials = try Credentials.parse(Data(#"{"tokens":{"access_token":"test","account_id":"acct"}}"#.utf8), provider: .openai)
    let openai = UsageClient.request(.openai, credentials: credentials)
    #expect(openai.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
    #expect(openai.httpMethod == "GET")
    #expect(openai.value(forHTTPHeaderField: "Authorization") == "Bearer test")
    #expect(openai.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct")
    let anthropic = UsageClient.request(.anthropic, credentials: credentials)
    #expect(anthropic.url?.host == "api.anthropic.com")
    #expect(anthropic.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
    #expect(anthropic.value(forHTTPHeaderField: "ChatGPT-Account-Id") == nil)
}

private func response(_ code: Int, headers: [String: String] = [:]) -> HTTPURLResponse {
    HTTPURLResponse(url: Provider.openai.dashboard, statusCode: code, httpVersion: nil, headerFields: headers)!
}

@Test func authenticationErrorsAreActionable() {
    #expect(throws: UsageError.expired(.openai)) { try UsageClient.validate(response(401), provider: .openai) }
    #expect(throws: UsageError.expired(.anthropic)) { try UsageClient.validate(response(403), provider: .anthropic) }
    #expect(throws: UsageError.server(503)) { try UsageClient.validate(response(503), provider: .openai) }
}

@Test func retryAfterSupportsSecondsAndHTTPDates() {
    #expect(throws: UsageError.rateLimited(seconds: 120)) {
        try UsageClient.validate(response(429, headers: ["Retry-After": "120"]), provider: .openai)
    }
    #expect(throws: UsageError.rateLimited(seconds: 300)) {
        try UsageClient.validate(response(429), provider: .anthropic)
    }
    #expect(throws: UsageError.rateLimited(seconds: 60)) {
        try UsageClient.validate(response(429, headers: ["Retry-After": "-1"]), provider: .anthropic)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    #expect(throws: UsageError.rateLimited(seconds: 600)) {
        try UsageClient.validate(response(429, headers: ["Retry-After": formatter.string(from: now.addingTimeInterval(600))]), provider: .openai, now: now)
    }
}

private struct StubClient: UsageFetching {
    let result: Result<UsageSnapshot, UsageError>
    func fetch(_ provider: Provider, allowKeychainPrompt: Bool) async throws -> UsageSnapshot { try result.get() }
}

private actor SuspendedClient: UsageFetching {
    private var continuation: CheckedContinuation<UsageSnapshot, any Error>?
    private(set) var calls = 0
    func fetch(_ provider: Provider, allowKeychainPrompt: Bool) async throws -> UsageSnapshot {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ snapshot: UsageSnapshot) { continuation?.resume(returning: snapshot); continuation = nil }
}

@MainActor @Test func disconnectedAppNeverShowsInventedUsage() {
    let store = UsageStore(defaults: nil)
    #expect(!store.current.connected)
    #expect(store.menuPercentage == nil)
}

@MainActor @Test func connectFetchesAndDisconnectClearsData() async throws {
    let snapshot = try UsageParser.parse(codexFixture, provider: .openai)
    let store = UsageStore(defaults: nil, client: StubClient(result: .success(snapshot)))
    await store.connect(.openai)
    #expect(store.current.connected)
    #expect(store.current.snapshot?.session?.percentage == 69)
    #expect(!store.current.isLoading)
    store.disconnect(.openai)
    #expect(!store.current.connected)
    #expect(store.current.snapshot == nil)
    #expect(store.menuPercentage == nil)
}

@MainActor @Test func failedConnectionShowsErrorNotPercentage() async {
    let store = UsageStore(defaults: nil, client: StubClient(result: .failure(.expired(.openai))))
    await store.connect(.openai)
    #expect(store.current.error?.contains("expired") == true)
    #expect(!store.current.isLoading)
    #expect(store.menuPercentage == nil)
}

@MainActor @Test func previewProviderAndPeriodSelection() throws {
    let store = UsageStore(defaults: nil, demo: true)
    #expect(store.menuPercentage == 69)
    store.selected = .anthropic
    #expect(store.menuPercentage == 52)
    store.period = .weekly
    #expect(store.menuPercentage == 62)
}

@MainActor @Test func rateLimitBlocksRepeatedRequests() async {
    let store = UsageStore(defaults: nil, client: StubClient(result: .failure(.rateLimited(seconds: 600))))
    await store.connect(.anthropic)
    let retryAfter = store.current.retryAfter
    #expect(retryAfter != nil)
    await store.refresh(.anthropic)
    #expect(store.current.retryAfter == retryAfter)
}

@MainActor @Test func disconnectDuringFetchCannotRestoreData() async throws {
    let client = SuspendedClient()
    let store = UsageStore(defaults: nil, client: client)
    let request = Task { await store.connect(.openai) }
    while await client.calls == 0 { await Task.yield() }
    store.disconnect(.openai)
    await client.finish(try UsageParser.parse(codexFixture, provider: .openai))
    await request.value
    #expect(!store.current.connected)
    #expect(store.current.snapshot == nil)
    #expect(!store.current.isLoading)
}

@MainActor @Test func concurrentRefreshesAreCoalesced() async throws {
    let client = SuspendedClient()
    let store = UsageStore(defaults: nil, client: client)
    let request = Task { await store.connect(.openai) }
    while await client.calls == 0 { await Task.yield() }
    await store.refresh(.openai)
    #expect(await client.calls == 1)
    await client.finish(try UsageParser.parse(codexFixture, provider: .openai))
    await request.value
}

@MainActor @Test func preferencesPersistButDemoNeverWrites() async {
    let name = "TokeyyTests.\(UUID())"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    let store = UsageStore(defaults: defaults, client: StubClient(result: .failure(.noCredentials(.anthropic))))
    store.appearance = .dark
    store.period = .weekly
    store.refreshInterval = .twoMinutes
    store.showAvailableResets = true
    await store.connect(.anthropic)
    let restored = UsageStore(defaults: defaults)
    #expect(restored.appearance == .dark)
    #expect(restored.period == .weekly)
    #expect(restored.refreshInterval == .twoMinutes)
    #expect(restored.showAvailableResets)
    #expect(restored.selected == .anthropic)
    #expect(restored.current.connected)
    let demo = UsageStore(defaults: defaults, demo: true)
    demo.appearance = .light
    demo.refreshInterval = .fifteenMinutes
    demo.showAvailableResets = false
    #expect(defaults.bool(forKey: "showAvailableResets"))
    #expect(defaults.integer(forKey: "refreshInterval") == 120)
    #expect(defaults.string(forKey: "appearance") == "dark")
    #expect(defaults.dictionaryRepresentation().values.allSatisfy { !(($0 as? String)?.contains("test-token") ?? false) })
}

@Test func credentialFilesAreReadWithoutModification() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let codex = directory.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    let file = codex.appendingPathComponent("auth.json")
    let data = Data(#"{"tokens":{"access_token":"fixture-only"}}"#.utf8)
    try data.write(to: file)
    let reader = CredentialReader(home: directory, environment: [:])
    #expect(try reader.read(.openai).accessToken == "fixture-only")
    #expect(try Data(contentsOf: file) == data)
    #expect(throws: UsageError.noCredentials(.openai)) {
        try CredentialReader(home: directory.appendingPathComponent("missing"), environment: [:]).read(.openai)
    }
}

@Test func expiredClaudeCredentialsFailBeforeNetworking() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(#"{"claudeAiOauth":{"accessToken":"fixture-only","expiresAt":1000}}"#.utf8)
        .write(to: directory.appendingPathComponent(".credentials.json"))
    #expect(throws: UsageError.expired(.anthropic)) {
        try CredentialReader(home: directory, environment: ["CLAUDE_CONFIG_DIR": directory.path]).read(.anthropic)
    }
}
