import Foundation
import MetriaCore

/// Fetches Claude usage using the OAuth token Claude Code stores in the macOS Keychain.
struct ClaudeProvider: UsageProvider {
    let kind = ProviderKind.claude
    var isAvailable: Bool { KeychainReader.hasClaudeCredentials }
    let setupHint = String(localized: "Install Claude Code and sign in to make usage available.")
    static let fiveHourLimitTitle = String(localized: "5-hour limit")
    static let weeklyLimitTitle = String(localized: "Weekly limit")
    let usageWindowTitles = [fiveHourLimitTitle, weeklyLimitTitle]
    private static let accountEmailCache = ClaudeAccountEmailCache()
    func fetch() async -> ProviderFetchResult {
        do {
            let credentials = try KeychainReader.readClaudeCredentials()
            var accessToken = credentials.accessToken
            let data: Data
            do {
                data = try await requestUsage(token: accessToken)
            } catch ProviderError.http(401) {
                accessToken = try await refreshToken(using: credentials)
                data = try await requestUsage(token: accessToken)
            }
            let value = try JSONDecoder().decode(ClaudeResponse.self, from: data)
            let accountEmail: String?
            if let localEmail = KeychainReader.accountEmail(from: credentials) {
                accountEmail = localEmail
            } else if let cachedEmail = await Self.accountEmailCache.value {
                accountEmail = cachedEmail
            } else {
                let email = try? await requestAccountEmail(token: accessToken)
                await Self.accountEmailCache.store(email)
                accountEmail = email
            }
            return .loaded(ProviderUsage(kind: kind, accountLabel: accountEmail, planLabel: KeychainReader.planLabel(from: credentials), windows: [
                UsageWindow(title: Self.fiveHourLimitTitle, percent: value.fiveHour.utilization, resetDate: value.fiveHour.resetDate),
                UsageWindow(title: Self.weeklyLimitTitle, percent: value.sevenDay.utilization, resetDate: value.sevenDay.resetDate)
            ], updatedAt: Date(), error: nil))
        } catch {
            let providerError = error as? ProviderError
            FileHandle.standardError.write("[Claude] error: \(error.localizedDescription)\n".data(using: .utf8)!)
            return .failed(kind, error.localizedDescription, retryAfter: providerError?.retryAfter)
        }
    }

    private func refreshToken(using credentials: KeychainReader.ClaudeCredentials) async throws -> String {
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
        ]
        if let scopes = credentials.scopes, !scopes.isEmpty {
            body["scope"] = scopes.joined(separator: " ")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else { throw ProviderError.http(status) }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        return token.accessToken
    }
    private func requestUsage(token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as? HTTPURLResponse
        let status = httpResponse?.statusCode ?? -1
        guard status != 429 else {
            let retryAfter = httpResponse?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
            throw ProviderError.rateLimited(retryAfter: retryAfter)
        }
        guard status == 200 else { throw ProviderError.http(status) }
        return data
    }

    private func requestAccountEmail(token: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/profile")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ProviderError.unavailable }
        return try JSONDecoder().decode(ProfileResponse.self, from: data).account.email
    }
    private struct ClaudeResponse: Decodable {
        let fiveHour: Limit
        let sevenDay: Limit
        enum CodingKeys: String, CodingKey { case fiveHour = "five_hour"; case sevenDay = "seven_day" }
        struct Limit: Decodable {
            let utilization: Double
            let resetsAt: String?
            var resetDate: Date? {
                guard let resetsAt else { return nil }
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                return formatter.date(from: resetsAt) ?? {
                    formatter.formatOptions = [.withInternetDateTime]
                    return formatter.date(from: resetsAt)
                }()
            }
            enum CodingKeys: String, CodingKey { case utilization; case resetsAt = "resets_at" }
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
        }
    }

    private struct ProfileResponse: Decodable {
        struct Account: Decodable {
            let email: String?
        }

        let account: Account
    }
}

private actor ClaudeAccountEmailCache {
    private var email: String?

    var value: String? { email }

    func store(_ email: String?) {
        if let email {
            self.email = email
        }
    }
}
