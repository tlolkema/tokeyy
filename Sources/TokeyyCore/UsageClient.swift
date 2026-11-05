import Foundation

public protocol UsageFetching: Sendable {
    func fetch(_ provider: Provider, allowKeychainPrompt: Bool) async throws -> UsageSnapshot
    func fetch(_ provider: Provider, allowKeychainPrompt: Bool, includeResets: Bool) async throws -> UsageSnapshot
}

public extension UsageFetching {
    func fetch(_ provider: Provider, allowKeychainPrompt: Bool, includeResets: Bool) async throws -> UsageSnapshot {
        try await fetch(provider, allowKeychainPrompt: allowKeychainPrompt)
    }
}

private actor ResetCooldown {
    private var until: Date?
    func canRequest() -> Bool { until.map { $0 <= .now } ?? true }
    func record(_ error: any Error) {
        let seconds: Int
        if case UsageError.rateLimited(let value) = error { seconds = value } else { seconds = 300 }
        until = .now.addingTimeInterval(Double(seconds))
    }
}

/// Usage requests must never send subscription tokens to a redirect destination.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct UsageClient: UsageFetching {
    private let reader: CredentialReader
    private let session: URLSession
    private let resetCooldown = ResetCooldown()

    public init(reader: CredentialReader = CredentialReader(), session: URLSession? = nil) {
        self.reader = reader
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    public func fetch(_ provider: Provider, allowKeychainPrompt: Bool = false) async throws -> UsageSnapshot {
        try await fetch(provider, allowKeychainPrompt: allowKeychainPrompt, includeResets: false)
    }

    public func fetch(_ provider: Provider, allowKeychainPrompt: Bool = false, includeResets: Bool) async throws -> UsageSnapshot {
        let credentials = try reader.read(provider, allowKeychainPrompt: allowKeychainPrompt)
        var request = Self.request(provider, credentials: credentials, includeResets: includeResets)
        var (data, response) = try await session.data(for: request)
        // Older Claude accounts can reject the optional inventory query. Preserve ordinary usage.
        if provider == .anthropic, includeResets,
           let http = response as? HTTPURLResponse, [400, 403].contains(http.statusCode) {
            try Task.checkCancellation()
            request = Self.request(provider, credentials: credentials)
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        try Self.validate(http, provider: provider)
        let snapshot = try UsageParser.parse(data, provider: provider)
        guard includeResets else { return snapshot.withResets(nil) }
        guard provider == .openai else { return snapshot }
        guard await resetCooldown.canRequest() else { return snapshot }
        do {
            let (resetData, resetResponse) = try await session.data(for: Self.resetRequest(credentials: credentials))
            guard let resetHTTP = resetResponse as? HTTPURLResponse else { throw UsageError.invalidResponse }
            try Self.validate(resetHTTP, provider: provider)
            return snapshot.withResets(ResetParser.openai(resetData))
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            // An optional reset request must not hide valid session and weekly usage.
            await resetCooldown.record(error)
            return snapshot
        }
    }

    public static func resetRequest(credentials: Credentials) -> URLRequest {
        var request = Self.request(.openai, credentials: credentials)
        request.url = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!
        request.timeoutInterval = 5
        request.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        return request
    }

    public static func request(_ provider: Provider, credentials: Credentials, includeResets: Bool = false) -> URLRequest {
        let url = URL(string: provider == .openai
            ? "https://chatgpt.com/backend-api/wham/usage"
            : "https://api.anthropic.com/api/oauth/usage")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        if provider == .anthropic, includeResets {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "cedar_ember", value: "1")]
            request.url = components.url
        }
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Tokeyy/0.1", forHTTPHeaderField: "User-Agent")
        if provider == .openai, let accountID = credentials.accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        if provider == .anthropic {
            request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        }
        return request
    }

    public static func validate(_ response: HTTPURLResponse, provider: Provider, now: Date = .now) throws {
        switch response.statusCode {
        case 200: return
        case 401, 403: throw UsageError.expired(provider)
        case 429:
            let header = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            var interval = Double(header)
            if interval == nil {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                interval = formatter.date(from: header)?.timeIntervalSince(now)
            }
            let seconds = (interval?.isFinite == true ? interval! : 300)
            throw UsageError.rateLimited(seconds: Int(min(86400, max(60, seconds))))
        default: throw UsageError.server(response.statusCode)
        }
    }
}
