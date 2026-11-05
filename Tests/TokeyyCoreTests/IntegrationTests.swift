import Foundation
import Testing
@testable import TokeyyCore

private let fixture = Data(#"{"rate_limit":{"primary_window":{"used_percent":31,"reset_after_seconds":7200},"secondary_window":{"used_percent":16,"reset_after_seconds":604800}}}"#.utf8)

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "chatgpt.com",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only" else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let status = request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "reject" ? 401 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: fixture)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Test(arguments: [false, true]) func fullCredentialToHTTPToUsagePipeline(reject: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let auth = Data("{\"tokens\":{\"access_token\":\"fixture-only\",\"account_id\":\"\(reject ? "reject" : "test")\"}}".utf8)
    try auth.write(to: directory.appendingPathComponent("auth.json"))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [FixtureProtocol.self]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let reader = CredentialReader(home: directory, environment: ["CODEX_HOME": directory.path])
    let client = UsageClient(reader: reader, session: session)
    if reject {
        await #expect(throws: UsageError.expired(.openai)) { try await client.fetch(.openai) }
    } else {
        let snapshot = try await client.fetch(.openai)
        #expect(snapshot.session?.percentage == 69)
        #expect(snapshot.weekly?.percentage == 84)
    }
    #expect(try Data(contentsOf: directory.appendingPathComponent("auth.json")) == auth)
}

private actor SequenceClient: UsageFetching {
    private(set) var calls = 0
    let snapshot: UsageSnapshot
    init(snapshot: UsageSnapshot) { self.snapshot = snapshot }
    func fetch(_ provider: Provider, allowKeychainPrompt: Bool) async throws -> UsageSnapshot {
        calls += 1
        if calls > 1 { throw UsageError.server(503) }
        return snapshot
    }
}

@MainActor @Test func failedRefreshRetainsLastSuccessButHidesMenuPercentage() async throws {
    let snapshot = try UsageParser.parse(fixture, provider: .openai)
    let client = SequenceClient(snapshot: snapshot)
    let store = UsageStore(defaults: nil, client: client)
    await store.connect(.openai)
    #expect(store.menuPercentage == 69)
    await store.refresh(.openai)
    #expect(store.current.snapshot == snapshot)
    #expect(store.current.error != nil)
    #expect(store.menuPercentage == nil)
}

@MainActor @Test func repeatedOpensDoNotHammerUsageEndpoint() async throws {
    let client = SequenceClient(snapshot: try UsageParser.parse(fixture, provider: .openai))
    let store = UsageStore(defaults: nil, client: client)
    await store.connect(.openai)
    await store.refreshAll()
    await store.refreshAll()
    #expect(await client.calls == 1)
}

@MainActor @Test func staleAndResetSnapshotsNeverShowFreshMenuPercentage() async throws {
    for age in [601.0, 0] {
        let snapshot = UsageSnapshot(
            session: try UsageWindow(used: 31, resetsAt: .now.addingTimeInterval(age == 0 ? -1 : 1000)),
            weekly: nil, plan: nil, fetchedAt: .now.addingTimeInterval(-age))
        let store = UsageStore(defaults: nil, client: SequenceClient(snapshot: snapshot))
        await store.connect(.openai)
        #expect(store.current.snapshot != nil)
        #expect(store.menuPercentage == nil)
    }
}

@MainActor @Test func disconnectFallsBackToOtherConnectedProvider() async throws {
    let client = SequenceClient(snapshot: try UsageParser.parse(fixture, provider: .openai))
    let store = UsageStore(defaults: nil, client: client)
    await store.connect(.openai)
    await store.connect(.anthropic)
    store.disconnect(.anthropic)
    #expect(store.selected == .openai)
    #expect(store.menuPercentage == 69)
}

@Test(arguments: ["{}", #"{"five_hour":null,"seven_day":null}"#, #"{"five_hour":{"utilization":"unknown"}}"#])
func invalidAnthropicDataIsNeverInvented(_ value: String) {
    #expect(throws: UsageError.invalidResponse) { try UsageParser.parse(Data(value.utf8), provider: .anthropic) }
}

@Test func extremeResetDatesCannotCrashCountdown() throws {
    let window = try UsageWindow(used: 25, resetsAt: Date(timeIntervalSince1970: 1e100))
    #expect(window.resetsAt == nil)
    #expect(window.resetDescription() == "Reset time unavailable")
}
