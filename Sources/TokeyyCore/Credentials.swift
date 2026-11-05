import Foundation
import Security
import LocalAuthentication

/// Access tokens stay in memory. Tokeyy never copies, refreshes, or modifies CLI credentials.
public struct Credentials: Sendable {
    public let accessToken: String
    public let accountID: String?
    public let expiresAt: Date?

    public static func parse(_ data: Data, provider: Provider) throws -> Credentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidCredentials(provider)
        }
        switch provider {
        case .openai:
            guard let tokens = root["tokens"] as? [String: Any],
                  let token = nonEmpty(tokens["access_token"]) else {
                throw UsageError.invalidCredentials(provider)
            }
            return Credentials(accessToken: token, accountID: nonEmpty(tokens["account_id"]),
                               expiresAt: jwtExpiration(token))
        case .anthropic:
            guard let oauth = root["claudeAiOauth"] as? [String: Any],
                  let token = nonEmpty(oauth["accessToken"]) else {
                throw UsageError.invalidCredentials(provider)
            }
            let expiry = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
            return Credentials(accessToken: token, accountID: nil, expiresAt: expiry)
        }
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jwtExpiration(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let expiry = json["exp"] as? Double else { return nil }
        return Date(timeIntervalSince1970: expiry)
    }
}

public struct CredentialReader: Sendable {
    private let home: URL
    private let environment: [String: String]

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.home = home
        self.environment = environment
    }

    public func read(_ provider: Provider, allowKeychainPrompt: Bool = false) throws -> Credentials {
        let credentials: Credentials
        switch provider {
        case .openai:
            let directory = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".codex")
            credentials = try readFile(directory.appendingPathComponent("auth.json"), provider: provider)
        case .anthropic:
            let directory = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? home.appendingPathComponent(".claude")
            let file = directory.appendingPathComponent(".credentials.json")
            if FileManager.default.fileExists(atPath: file.path) {
                credentials = try readFile(file, provider: provider)
            } else {
                credentials = try Credentials.parse(readClaudeKeychain(allowPrompt: allowKeychainPrompt), provider: provider)
            }
        }
        if let expiry = credentials.expiresAt, expiry <= .now { throw UsageError.expired(provider) }
        return credentials
    }

    private func readFile(_ url: URL, provider: Provider) throws -> Credentials {
        guard FileManager.default.fileExists(atPath: url.path) else { throw UsageError.noCredentials(provider) }
        guard let data = try? Data(contentsOf: url) else { throw UsageError.invalidCredentials(provider) }
        return try Credentials.parse(data, provider: provider)
    }

    private func readClaudeKeychain(allowPrompt: Bool) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        let context = LAContext()
        context.interactionNotAllowed = !allowPrompt
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw UsageError.noCredentials(.anthropic) }
        guard status == errSecSuccess, let data = result as? Data else { throw UsageError.keychainDenied }
        return data
    }
}
