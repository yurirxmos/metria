import CryptoKit
import Foundation
import MetriaCore
import SQLite3

/// Fetches OpenCode Go usage using credentials from OpenCode's V2 database, with the
/// legacy auth file retained as a fallback for V1 installations.
struct OpenCodeGoProvider: UsageProvider {
    let kind = ProviderKind.openCodeGo
    var supportsAccountFingerprint: Bool { true }
    var isAvailable: Bool { !readCredentials().isEmpty }
    let setupHint = String(localized: "Sign in to OpenCode Go to make usage available.")
    static let fiveHourLimitTitle = String(localized: "5-hour limit")
    static let weeklyLimitTitle = String(localized: "Weekly limit")
    static let monthlyLimitTitle = String(localized: "Monthly limit")
    let usageWindowTitles = [fiveHourLimitTitle, weeklyLimitTitle, monthlyLimitTitle]

    private static let authURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/share/opencode/auth.json")

    static var databaseURL: URL {
        let environment = ProcessInfo.processInfo.environment
        if let configuredPath = environment["OPENCODE_DB"], !configuredPath.isEmpty {
            return URL(fileURLWithPath: (configuredPath as NSString).expandingTildeInPath)
        }
        let dataHome = environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share", isDirectory: true)
        return dataHome.appendingPathComponent("opencode/opencode.db")
    }

    func accountFingerprint() -> String? {
        let identities = readCredentials().map(\.identity).sorted()
        guard !identities.isEmpty else { return nil }
        return Self.hash(identities.joined(separator: "|"))
    }

    func fetch() async -> ProviderFetchResult {
        let credentials = readCredentials()
        guard !credentials.isEmpty else {
            return .failed(kind, setupHint, retryAfter: nil)
        }

        var lastAuthenticationError: Error?
        for credential in credentials {
            do {
                let data = try await requestUsage(key: credential.key)
                let usage = try JSONDecoder().decode(OpenCodeGoResponse.self, from: data).usage
                return .loaded(
                    ProviderUsage(
                        kind: kind,
                        accountLabel: credential.accountLabel,
                        accountFingerprint: accountFingerprint(),
                        windows: [
                            UsageWindow(title: Self.fiveHourLimitTitle, percent: usage.rolling.percent, resetDate: usage.rolling.resetDate),
                            UsageWindow(title: Self.weeklyLimitTitle, percent: usage.weekly.percent, resetDate: usage.weekly.resetDate),
                            UsageWindow(title: Self.monthlyLimitTitle, percent: usage.monthly.percent, resetDate: usage.monthly.resetDate),
                        ],
                        updatedAt: Date(),
                        error: nil))
            } catch let error as ProviderError {
                switch error {
                case .http(401), .http(403), .expiredOpenCodeGoKey:
                    lastAuthenticationError = error
                    continue
                default:
                    return .failed(kind, error.localizedDescription, retryAfter: error.retryAfter)
                }
            } catch {
                return .failed(kind, error.localizedDescription, retryAfter: nil)
            }
        }

        let error = lastAuthenticationError ?? ProviderError.unavailable
        let providerError = error as? ProviderError
        return .failed(kind, error.localizedDescription, retryAfter: providerError?.retryAfter)
    }

    private func requestUsage(key: String) async throws -> Data {
        for attempt in 0..<3 {
            var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? -1
            if status == 429 {
                let retryAfter = httpResponse?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    ?? pow(2, Double(attempt + 1))
                guard attempt < 2 else { throw ProviderError.rateLimited(retryAfter: retryAfter) }
                try await Task.sleep(for: .seconds(min(retryAfter, 30)))
                continue
            }
            guard status == 200 else {
                if status == 401, Self.isExpiredAPIKey(data) { throw ProviderError.expiredOpenCodeGoKey }
                throw ProviderError.http(status)
            }
            return data
        }
        throw ProviderError.unavailable
    }

    private func readCredentials() -> [GoCredential] {
        var credentials = readDatabaseCredentials()
        if let legacyKey = readLegacyAPIKey(), !credentials.contains(where: { $0.key == legacyKey }) {
            credentials.append(GoCredential(key: legacyKey, identity: "key:\(Self.hash(legacyKey))", accountLabel: Self.maskedKey(legacyKey)))
        }
        return credentials
    }

    private func readDatabaseCredentials() -> [GoCredential] {
        var database: OpaquePointer?
        defer { if database != nil { sqlite3_close(database) } }
        let path = Self.databaseURL.path
        var allowedPathCharacters = CharacterSet.urlPathAllowed
        allowedPathCharacters.remove(charactersIn: "?#")
        guard let encodedPath = path.addingPercentEncoding(withAllowedCharacters: allowedPathCharacters),
              sqlite3_open_v2("file:\(encodedPath)?mode=ro", &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
              let database else { return [] }
        sqlite3_busy_timeout(database, 1000)

        let query = """
            SELECT integration_id, label, value, active, time_updated
            FROM credential
            WHERE integration_id IN ('opencode-go', 'opencode')
            ORDER BY COALESCE(active, 0) DESC, time_updated DESC
            """
        var statement: OpaquePointer?
        defer { if statement != nil { sqlite3_finalize(statement) } }
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }

        var goCredentials: [GoCredential] = []
        var consoleCredentials: [GoCredential] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let integration = Self.text(statement, column: 0),
                  let value = Self.text(statement, column: 2)?.data(using: .utf8),
                  let stored = try? JSONDecoder().decode(StoredCredential.self, from: value),
                  stored.type == "key" || stored.type == "oauth" else { continue }

            if integration == "opencode-go", stored.type == "key", let key = stored.key, !key.isEmpty {
                let label = Self.maskedKey(key)
                let identity = "key:\(Self.hash(key))"
                if !goCredentials.contains(where: { $0.key == key }) {
                    goCredentials.append(GoCredential(key: key, identity: identity, accountLabel: label))
                }
            } else if integration == "opencode", stored.type == "oauth", sqlite3_column_int(statement, 3) == 1,
                      let accessToken = stored.access, !accessToken.isEmpty {
                let metadata = stored.metadata
                let accountParts = [metadata?.accountID, metadata?.orgID].compactMap { $0 }
                let identity = accountParts.isEmpty ? "oauth:\(Self.hash(accessToken))" : "oauth:\(accountParts.joined(separator: ":"))"
                if !consoleCredentials.contains(where: { $0.key == accessToken }) {
                    consoleCredentials.append(GoCredential(key: accessToken, identity: identity, accountLabel: metadata?.email))
                }
            }
        }
        return goCredentials + consoleCredentials
    }

    private func readLegacyAPIKey() -> String? {
        guard let data = try? Data(contentsOf: Self.authURL),
              let auth = try? JSONDecoder().decode(LegacyOpenCodeAuth.self, from: data),
              !auth.openCodeGo.key.isEmpty else { return nil }
        return auth.openCodeGo.key
    }

    private static func isExpiredAPIKey(_ data: Data) -> Bool {
        guard let response = try? JSONDecoder().decode(APIErrorResponse.self, from: data) else { return false }
        return response.error.code == "api_key_expired"
    }

    private static func text(_ statement: OpaquePointer, column: Int32) -> String? {
        guard let value = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: value)
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func maskedKey(_ key: String) -> String {
        guard key.count > 8 else { return "****" }
        return "\(key.prefix(4))...\(key.suffix(4))"
    }

    private struct GoCredential {
        let key: String
        let identity: String
        let accountLabel: String?
    }

    private struct StoredCredential: Decodable {
        let type: String?
        let key: String?
        let access: String?
        let metadata: Metadata?

        struct Metadata: Decodable {
            let accountID: String?
            let orgID: String?
            let email: String?
        }
    }

    private struct LegacyOpenCodeAuth: Decodable {
        let openCodeGo: LegacyCredential
        enum CodingKeys: String, CodingKey { case openCodeGo = "opencode-go" }
    }

    private struct LegacyCredential: Decodable { let key: String }

    private struct APIErrorResponse: Decodable {
        struct APIError: Decodable { let code: String? }
        let error: APIError
    }

    private struct OpenCodeGoResponse: Decodable {
        let usage: Usage

        struct Usage: Decodable {
            let rolling: Limit
            let weekly: Limit
            let monthly: Limit
        }

        struct Limit: Decodable {
            let percent: Double
            let resetsAt: String

            var resetDate: Date? {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: resetsAt)
            }
        }
    }
}
