import Foundation
import CryptoKit
import MetriaCore

/// Fetches Codex usage from the native Codex CLI credentials, falling back to local
/// Codex CLI session files when those credentials are missing.
struct CodexProvider: UsageProvider {
    let kind = ProviderKind.codex
    var supportsAccountFingerprint: Bool { true }
    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: codexAuthURL.path) || FileManager.default.fileExists(atPath: sessionsURL.path)
    }
    let setupHint = String(localized: "Sign in to Codex to create local usage data.")
    static let fiveHourLimitTitle = String(localized: "5-hour limit")
    static let weeklyLimitTitle = String(localized: "Weekly limit")
    let usageWindowTitles = [fiveHourLimitTitle, weeklyLimitTitle]

    func accountFingerprint() -> String? {
        guard let data = try? Data(contentsOf: codexAuthURL),
              let auth = try? JSONDecoder().decode(CodexAuth.self, from: data),
              let accountId = auth.tokens?.accountId else { return nil }
        return Self.fingerprint(accountId)
    }

    private var codexAuthURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json") }
    private var sessionsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions") }

    private static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func fetch() async -> ProviderFetchResult {
        if let remoteResult = await fetchCodexUsage() {
            switch remoteResult {
            case .loaded(_), .empty(_):
                return remoteResult
            case .failed(_, let message, let retryAfter):
                if case .loaded(var localUsage) = fetchLocalUsage() {
                    localUsage.error = String(localized: "\(message) Showing the latest local session data.")
                    return .loaded(localUsage)
                }
                return .failed(kind, message, retryAfter: retryAfter)
            }
        }
        return fetchLocalUsage()
    }
    private func fetchCodexUsage() async -> ProviderFetchResult? {
        guard let data = try? Data(contentsOf: codexAuthURL) else { return nil }
        guard let credentials = try? JSONDecoder().decode(CodexAuth.self, from: data).tokens else { return nil }
        guard let accountId = credentials.accountId else { return nil }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200 else {
                let error = ProviderError.http(status)
                return .failed(kind, error.localizedDescription, retryAfter: error.retryAfter)
            }
            let value = try JSONDecoder().decode(OpenAIUsageResponse.self, from: data)
            return .loaded(ProviderUsage(
                kind: kind,
                accountLabel: credentials.idToken.flatMap(KeychainReader.tokenEmail) ?? KeychainReader.tokenEmail(credentials.accessToken),
                planLabel: credentials.idToken.flatMap(planLabel),
                windows: [
                UsageWindow(title: Self.fiveHourLimitTitle, percent: value.rateLimit.primaryWindow.usedPercent, resetDate: Date(timeIntervalSince1970: Double(value.rateLimit.primaryWindow.resetAt))),
                UsageWindow(title: Self.weeklyLimitTitle, percent: value.rateLimit.secondaryWindow.usedPercent, resetDate: Date(timeIntervalSince1970: Double(value.rateLimit.secondaryWindow.resetAt)))
            ], updatedAt: Date(), error: nil))
        } catch {
            let providerError = error as? ProviderError
            return .failed(kind, error.localizedDescription, retryAfter: providerError?.retryAfter)
        }
    }
    /// Decodes the ChatGPT plan (e.g. "free", "plus", "pro", "business") from the `id_token`
    /// JWT's `https://api.openai.com/auth` claim. Best-effort — this claim is undocumented and
    /// has been observed missing from some token refresh paths.
    private func planLabel(from idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let planType = auth["chatgpt_plan_type"] as? String, !planType.isEmpty else { return nil }
        return planDisplayName(planType)
    }

    /// OpenAI's "Team" plan was renamed to "Business"; the raw claim may still use either
    /// name depending on when the account was created, so both are normalized to "Business".
    private func planDisplayName(_ raw: String) -> String {
        let normalized = raw.lowercased()
        if normalized.contains("business") || normalized.contains("team") { return "Business" }
        // Fall back to Title Case for snake_case raw values (e.g. "chatgpt_plus" -> "Chatgpt Plus").
        return normalized.split(separator: "_").map { $0.capitalized }.joined(separator: " ")
    }
    private func fetchLocalUsage() -> ProviderFetchResult {
        let candidates = findCandidates()
        for candidate in candidates.sorted(by: { $0.0 > $1.0 }) {
            guard let text = try? String(contentsOf: candidate.1, encoding: .utf8) else { continue }
            let lines = text.split(separator: "\n").reversed()
            for line in lines {
                guard line.contains("rate_limits"), let data = line.data(using: .utf8), let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let payload = event["payload"] as? [String: Any] else { continue }
                let limits = (payload["rate_limits"] as? [String: Any]) ?? ((payload["info"] as? [String: Any])?["rate_limits"] as? [String: Any])
                guard let limits else { continue }
                let primary = parseLimit(limits["primary"] as? [String: Any], title: Self.fiveHourLimitTitle)
                let secondary = parseLimit(limits["secondary"] as? [String: Any], title: Self.weeklyLimitTitle)
                return .loaded(ProviderUsage(kind: kind, windows: [primary, secondary].compactMap { $0 }, updatedAt: candidate.0, error: nil))
            }
        }
        return .empty(ProviderUsage(kind: kind, windows: [], updatedAt: nil, error: String(localized: "No recent local usage data was found. Sign in and use Codex once to create a usage snapshot.")))
    }
    private struct CodexAuth: Decodable {
        let tokens: Tokens?

        struct Tokens: Decodable {
            let accessToken: String
            let accountId: String?
            let idToken: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case accountId = "account_id"
                case idToken = "id_token"
            }
        }
    }
    private struct OpenAIUsageResponse: Decodable {
        let rateLimit: RateLimit
        enum CodingKeys: String, CodingKey { case rateLimit = "rate_limit" }
        struct RateLimit: Decodable { let primaryWindow: Window; let secondaryWindow: Window; enum CodingKeys: String, CodingKey { case primaryWindow = "primary_window"; case secondaryWindow = "secondary_window" } }
        struct Window: Decodable { let usedPercent: Double; let resetAt: Int; enum CodingKeys: String, CodingKey { case usedPercent = "used_percent"; case resetAt = "reset_at" } }
    }
    private func findCandidates() -> [(Date, URL)] {
        let fileManager = FileManager.default
        let authModified = (try? fileManager.attributesOfItem(atPath: codexAuthURL.path)[.modificationDate]) as? Date
        let root = fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
        guard let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var candidates: [(Date, URL)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil,
               authModified == nil || date >= authModified! { candidates.append((date, url)) }
        }
        return candidates
    }
    private func parseLimit(_ raw: [String: Any]?, title: String) -> UsageWindow? {
        guard let raw, let rawPercent = raw["used_percent"] as? NSNumber else { return nil }
        let percent = rawPercent.doubleValue
        let reset = (raw["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
        return UsageWindow(title: title, percent: reset.map { $0 < Date() ? 0 : percent } ?? percent, resetDate: reset)
    }
}
