import Foundation
import Testing
@testable import TokeyyCore

@Test func resetDisplayIsOffByDefault() async {
    await MainActor.run { #expect(!UsageStore(defaults: nil).showAvailableResets) }
}

@Test func openAIResetsUseReportedInventory() {
    let data = Data(#"{"available_count":2,"credits":[{"id":"never-stored","status":"available"},{"status":"available","expires_at":"2099-01-01T00:00:00Z"},{"status":"redeemed"}]}"#.utf8)
    #expect(ResetParser.openai(data)?.availableCount() == 2)
    #expect(ResetParser.openai(Data(#"{"available_count":0,"credits":[]}"#.utf8))?.availableCount() == 0)
}

@Test(arguments: ["{}", #"{"available_count":-1}"#, #"{"available_count":true}"#, #"{"available_count":1001}"#, #"{"available_count":2,"credits":[]}"#, #"{"available_count":1,"credits":[{"status":"available","expires_at":"invalid"}]}"#])
func invalidResetCountsRemainUnknown(_ value: String) {
    #expect(ResetParser.openai(Data(value.utf8)) == nil)
}

@Test func expiredResetsAreNotCounted() {
    let data = Data(#"{"available_count":2,"credits":[{"status":"available","expires_at":"2020-01-01T00:00:00Z"},{"status":"available","expires_at":"2099-01-01T00:00:00.123Z"}]}"#.utf8)
    #expect(ResetParser.openai(data)?.availableCount() == 1)
}

@Test func anthropicResetsExcludePausedExpiredAndFutureGrants() {
    let data = Data(#"{"cedar_ember":{"eligible":true,"grants":[{"resets_left":2,"resets_total":2,"paused":false},{"resets_left":2,"paused":true},{"resets_left":1,"paused":false,"ends_at":"2020-01-01T00:00:00Z"},{"resets_left":1,"paused":false,"starts_at":"2099-01-01T00:00:00Z"}]}}"#.utf8)
    #expect(ResetParser.anthropic(data)?.availableCount() == 2)
}

@Test(arguments: ["{}", #"{"cedar_ember":{"eligible":false,"grants":[]}}"#, #"{"cedar_ember":{"eligible":true,"grants":[{"resets_left":1}]}}"#, #"{"cedar_ember":{"eligible":true,"grants":[{"resets_left":51,"paused":false}]}}"#, #"{"cedar_ember":{"eligible":true,"grants":[{"resets_left":2,"resets_total":1,"paused":false}]}}"#])
func invalidAnthropicInventoryRemainsUnknown(_ value: String) {
    #expect(ResetParser.anthropic(Data(value.utf8)) == nil)
}

@Test func malformedOptionalResetsCannotBreakUsage() throws {
    let data = Data(#"{"five_hour":{"utilization":31},"cedar_ember":{"eligible":"bad"}}"#.utf8)
    let snapshot = try UsageParser.parse(data, provider: .anthropic)
    #expect(snapshot.session?.percentage == 69)
    #expect(snapshot.resets == nil)
}

private actor OptionClient: UsageFetching {
    private(set) var options: [Bool] = []
    func fetch(_ provider: Provider, allowKeychainPrompt: Bool) async throws -> UsageSnapshot {
        try await fetch(provider, allowKeychainPrompt: allowKeychainPrompt, includeResets: false)
    }
    func fetch(_ provider: Provider, allowKeychainPrompt: Bool, includeResets: Bool) async throws -> UsageSnapshot {
        options.append(includeResets)
        return UsageSnapshot(session: try UsageWindow(used: 31, resetsAt: .now.addingTimeInterval(3600)),
                             weekly: nil, plan: nil, resets: includeResets ? ResetInventory(count: 2) : nil)
    }
}

@MainActor @Test func resetSettingControlsFetchEnrichment() async throws {
    let client = OptionClient()
    let store = UsageStore(defaults: nil, client: client)
    await store.connect(.openai)
    #expect(store.current.snapshot?.resets == nil)
    store.showAvailableResets = true
    await store.refresh(.openai)
    #expect(store.current.snapshot?.resets?.availableCount() == 2)
    store.showAvailableResets = false
    await store.refresh(.openai)
    #expect(store.current.snapshot?.resets == nil)
    #expect(await client.options == [false, true, false])
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: [URLRequest]] = [:]
    func record(_ request: URLRequest) {
        lock.withLock { entries[request.value(forHTTPHeaderField: "Authorization") ?? "", default: []].append(request) }
    }
    func requests(token: String) -> [URLRequest] { lock.withLock { entries["Bearer \(token)"] ?? [] } }
}

private final class ResetProtocol: URLProtocol, @unchecked Sendable {
    static let log = RequestLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.log.record(request)
        let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let isReset = request.url!.path.hasSuffix("rate-limit-reset-credits")
        let isAnthropic = request.url!.host == "api.anthropic.com"
        let legacyQuery = isAnthropic && token.contains("legacy") && request.url!.query != nil
        let status = legacyQuery ? 400 : isReset && token.contains("failure") ? 429 : 200
        let payload: String
        if isReset {
            payload = #"{"available_count":2,"credits":[{"status":"available"},{"status":"available"}]}"#
        } else if isAnthropic {
            payload = #"{"five_hour":{"utilization":31},"cedar_ember":{"eligible":true,"grants":[{"resets_left":2,"paused":false}]}}"#
        } else {
            payload = #"{"rate_limit":{"primary_window":{"used_percent":31,"reset_after_seconds":3600}}}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json", "Retry-After": "600"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct Harness {
    let directory: URL
    let session: URLSession
    let client: UsageClient
    let token: String
    init(provider: Provider, behavior: String = "success") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        token = "fixture-\(behavior)-\(UUID())"
        if provider == .openai {
            try Data("{\"tokens\":{\"access_token\":\"\(token)\",\"account_id\":\"fixture\"}}".utf8)
                .write(to: directory.appendingPathComponent("auth.json"))
        } else {
            try Data("{\"claudeAiOauth\":{\"accessToken\":\"\(token)\"}}".utf8)
                .write(to: directory.appendingPathComponent(".credentials.json"))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResetProtocol.self]
        session = URLSession(configuration: configuration)
        client = UsageClient(reader: CredentialReader(home: directory, environment: [
            "CODEX_HOME": directory.path, "CLAUDE_CONFIG_DIR": directory.path,
        ]), session: session)
    }
    func clean() { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: directory) }
}

@Test func openAIResetRequestIsOptInAndUsesSameAccount() async throws {
    let harness = try Harness(provider: .openai)
    defer { harness.clean() }
    let plain = try await harness.client.fetch(.openai)
    #expect(plain.resets == nil)
    #expect(ResetProtocol.log.requests(token: harness.token).count == 1)
    let enriched = try await harness.client.fetch(.openai, includeResets: true)
    #expect(enriched.session?.percentage == 69)
    #expect(enriched.resets?.availableCount() == 2)
    let requests = ResetProtocol.log.requests(token: harness.token)
    #expect(requests.count == 3)
    #expect(requests.last?.url?.path == "/backend-api/wham/rate-limit-reset-credits")
    #expect(requests.last?.httpMethod == "GET")
    #expect(requests.last?.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "fixture")
    #expect(requests.last?.value(forHTTPHeaderField: "OpenAI-Beta") == "codex-1")
}

@Test func optionalResetRateLimitPreservesUsageAndPausesInventoryRequests() async throws {
    let harness = try Harness(provider: .openai, behavior: "failure")
    defer { harness.clean() }
    for _ in 0..<2 {
        let snapshot = try await harness.client.fetch(.openai, includeResets: true)
        #expect(snapshot.session?.percentage == 69)
        #expect(snapshot.resets == nil)
    }
    #expect(ResetProtocol.log.requests(token: harness.token).filter { $0.url!.path.hasSuffix("rate-limit-reset-credits") }.count == 1)
}

@Test func anthropicInventoryQueryIsOptIn() async throws {
    let harness = try Harness(provider: .anthropic)
    defer { harness.clean() }
    #expect(try await harness.client.fetch(.anthropic).resets == nil)
    #expect(try await harness.client.fetch(.anthropic, includeResets: true).resets?.availableCount() == 2)
    let requests = ResetProtocol.log.requests(token: harness.token)
    #expect(requests.map { $0.url?.query } == [nil, "cedar_ember=1"])
}

@Test func rejectedAnthropicInventoryFallsBackToOrdinaryUsage() async throws {
    let harness = try Harness(provider: .anthropic, behavior: "legacy")
    defer { harness.clean() }
    let snapshot = try await harness.client.fetch(.anthropic, includeResets: true)
    #expect(snapshot.session?.percentage == 69)
    let requests = ResetProtocol.log.requests(token: harness.token)
    #expect(requests.map { $0.url?.query } == ["cedar_ember=1", nil])
}
