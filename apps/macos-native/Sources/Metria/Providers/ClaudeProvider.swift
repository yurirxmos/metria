import Foundation
import MetriaCore

/// Fetches Claude usage using the OAuth token Claude Code stores in the macOS Keychain.
///
/// One instance per `ClaudeProfile`: each profile is its own account with its own token, its
/// own keychain service, its own sessions folder and its own ring in the notch. A profile's
/// credential is read and refreshed independently of its siblings.
struct ClaudeProvider: UsageProvider {
    let profile: ClaudeProfile

    var kind: ProviderKind { .claude }
    var id: ProviderID { profile.providerID }
    var isAvailable: Bool { KeychainReader.hasClaudeCredentials(for: profile) }
    let setupHint = String(localized: "Install Claude Code and sign in to make usage available.")
    static let fiveHourLimitTitle = String(localized: "5-hour limit")
    static let weeklyLimitTitle = String(localized: "Weekly limit")
    let usageWindowTitles = [ClaudeProvider.fiveHourLimitTitle, ClaudeProvider.weeklyLimitTitle]

    init(profile: ClaudeProfile = .default()) {
        self.profile = profile
    }

    private static let accountEmailCache = ClaudeAccountEmailCache()
    private static let requestTimeout = 20.0

    func fetch() async -> ProviderFetchResult {
        do {
            var credentials = try KeychainReader.readClaudeCredentials(for: profile)
            var accessToken = credentials.accessToken
            let data: Data
            do {
                data = try await requestUsage(token: accessToken)
            } catch ProviderError.http(401) {
                do {
                    let refreshedToken = try await refreshToken(using: credentials)
                    accessToken = refreshedToken.accessToken
                    KeychainReader.storeClaudeCredentials(
                        credentials,
                        accessToken: refreshedToken.accessToken,
                        refreshToken: refreshedToken.refreshToken,
                        for: profile
                    )
                } catch ProviderError.http(400) {
                    KeychainReader.invalidateClaudeCredentialsCache(for: profile)
                    credentials = try KeychainReader.readClaudeCredentials(for: profile)
                    accessToken = credentials.accessToken
                }
                data = try await requestUsage(token: accessToken)
            }
            let value = try JSONDecoder().decode(ClaudeResponse.self, from: data)
            let accountEmail = await resolvedAccountEmail(credentials, accessToken: accessToken)
            return .loaded(ProviderUsage(
                id: id,
                accountLabel: accountEmail,
                planLabel: KeychainReader.planLabel(from: credentials),
                windows: [
                    UsageWindow(title: Self.fiveHourLimitTitle, percent: value.fiveHour.utilization, resetDate: value.fiveHour.resetDate),
                    UsageWindow(title: Self.weeklyLimitTitle, percent: value.sevenDay.utilization, resetDate: value.sevenDay.resetDate)
                ],
                updatedAt: Date(),
                error: nil
            ))
        } catch {
            let providerError = error as? ProviderError
            FileHandle.standardError.write("[Claude \(id.rawValue)] error: \(error.localizedDescription)\n".data(using: .utf8)!)
            return .failed(id, error.localizedDescription, retryAfter: providerError?.retryAfter)
        }
    }

    /// Which account is signed in, in the order worth trusting: the address Claude Code
    /// cached in `.claude.json` (readable without a keychain prompt), then the one embedded
    /// in the token, then a cached network answer, then the profile endpoint itself.
    private func resolvedAccountEmail(_ credentials: KeychainReader.ClaudeCredentials, accessToken: String) async -> String? {
        if let address = profile.signedInAddress() { return address }
        if let email = KeychainReader.accountEmail(from: credentials) { return email }
        if let cached = await Self.accountEmailCache.value(for: id) { return cached }
        let email = try? await requestAccountEmail(token: accessToken)
        await Self.accountEmailCache.store(email, for: id)
        return email
    }

    private func refreshToken(using credentials: KeychainReader.ClaudeCredentials) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://platform.claude.com/v1/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
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
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
    private func requestUsage(token: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = Self.requestTimeout
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
        request.timeoutInterval = Self.requestTimeout
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
        let refreshToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
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
    private var emails: [String: String] = [:]

    func value(for id: ProviderID) -> String? { emails[id.rawValue] }

    func store(_ email: String?, for id: ProviderID) {
        if let email {
            emails[id.rawValue] = email
        }
    }
}
