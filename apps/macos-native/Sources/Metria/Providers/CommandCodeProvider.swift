import Foundation
import MetriaCore

/// Fetches Command Code usage using the API key Command Code keeps in its local auth file
/// (`~/.commandcode/auth.json`), calling the same `/alpha` endpoints the `cmd` CLI calls to
/// draw its own `/usage` meters.
///
/// Command Code is the second provider (after Cursor) whose windows are measured in money:
/// the credits endpoint reports each window's used and cap as dollar amounts, so a card can
/// print "$17.57 / $35" beside the percentage. Those two windows are the plan's own rolling
/// limits, sent by the server, so nothing here is derived from a plan table Metria would have
/// to keep in sync as Command Code changes its tiers.
struct CommandCodeProvider: UsageProvider {
    let kind = ProviderKind.commandCode
    let setupHint = String(localized: "Sign in to Command Code to create a local API credential.")
    static let fiveHourLimitTitle = String(localized: "5-hour limit")
    static let weeklyLimitTitle = String(localized: "Weekly limit")
    let usageWindowTitles = [fiveHourLimitTitle, weeklyLimitTitle]

    private static let apiHost = "https://api.commandcode.ai"
    private static let creditsPath = "/alpha/billing/credits"
    private static let whoamiPath = "/alpha/whoami"
    /// The CLI resolves these ahead of the auth file, so a key exported for a
    /// terminal-launched build wins here too; an app started from Finder simply has no such
    /// variable set. `COMMAND_CODE_API_KEY` is the name the CLI documents and reads;
    /// `COMMANDCODE_API_KEY` is the spelling seen in the wild (scripts and app configs that
    /// drop the underscore), so both are honored.
    private static let apiKeyEnvironmentVariables = ["COMMAND_CODE_API_KEY", "COMMANDCODE_API_KEY"]

    private var authURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".commandcode/auth.json")
    }

    var isAvailable: Bool {
        environmentAPIKey != nil || FileManager.default.fileExists(atPath: authURL.path)
    }

    func fetch() async -> ProviderFetchResult {
        do {
            let key = try readAPIKey()
            let data = try await requestUsage(path: Self.creditsPath, key: key)
            let windows = try JSONDecoder().decode(CreditsResponse.self, from: data).windows
            guard !windows.isEmpty else { throw ProviderError.unavailable }
            return .loaded(
                ProviderUsage(
                    kind: kind, accountLabel: await accountLabel(key: key), windows: windows,
                    updatedAt: Date(), error: nil))
        } catch {
            let providerError = error as? ProviderError
            let message: String
            switch providerError {
            case .http(401), .http(403):
                message = String(localized: "Sign in to Command Code again to refresh usage.")
            default: message = error.localizedDescription
            }
            return .failed(kind, message, retryAfter: providerError?.retryAfter)
        }
    }

    /// Best effort: the account name is only a label on the card, so a failing `whoami` must
    /// never cost the usage numbers themselves.
    private func accountLabel(key: String) async -> String? {
        guard let data = try? await requestUsage(path: Self.whoamiPath, key: key) else { return nil }
        return (try? JSONDecoder().decode(WhoamiResponse.self, from: data))?.user.userName
    }

    private func requestUsage(path: String, key: String) async throws -> Data {
        for attempt in 0..<3 {
            var request = URLRequest(url: URL(string: Self.apiHost + path)!)
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? -1
            if status == 429 {
                let retryAfter =
                    httpResponse?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
                    ?? pow(2, Double(attempt + 1))
                guard attempt < 2 else { throw ProviderError.rateLimited(retryAfter: retryAfter) }
                try await Task.sleep(for: .seconds(min(retryAfter, 30)))
                continue
            }
            guard status == 200 else { throw ProviderError.http(status) }
            return data
        }
        throw ProviderError.unavailable
    }

    /// The CLI's own resolution order, mirrored: `COMMAND_CODE_API_KEY` first, then the auth
    /// file `cmd login` writes. Only the production file is read — the CLI's staging and local
    /// auth files belong to its own development environments, not to a usage reading.
    private func readAPIKey() throws -> String {
        if let environmentAPIKey { return environmentAPIKey }
        let data = try Data(contentsOf: authURL)
        let key = try JSONDecoder().decode(CommandCodeAuth.self, from: data).apiKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ProviderError.unavailable }
        return key
    }

    private var environmentAPIKey: String? {
        for name in Self.apiKeyEnvironmentVariables {
            guard let key = ProcessInfo.processInfo.environment[name]?
                .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
            else { continue }
            return key
        }
        return nil
    }

    private struct CommandCodeAuth: Decodable {
        let apiKey: String
    }

    private struct WhoamiResponse: Decodable {
        let user: User

        struct User: Decodable {
            let userName: String?
        }
    }

    /// `/alpha/billing/credits`. Amounts are the plan's credit value in dollars — the same
    /// units the CLI's `/usage` meters print — and `resetAt` is an epoch timestamp in
    /// milliseconds, unlike the seconds every other provider here reports.
    private struct CreditsResponse: Decodable {
        let windowLimits: WindowLimits

        struct WindowLimits: Decodable {
            let fiveHour: Window?
            let weekly: Window?
        }

        struct Window: Decodable {
            let used: Double
            let cap: Double
            let exceeded: Bool?
            let resetAt: Double?
        }

        var windows: [UsageWindow] {
            [
                windowLimits.fiveHour.map { window($0, title: CommandCodeProvider.fiveHourLimitTitle) },
                windowLimits.weekly.map { window($0, title: CommandCodeProvider.weeklyLimitTitle) },
            ].compactMap { $0 }
        }

        /// A window with no cap has no percentage worth drawing, and `exceeded` is then the
        /// only authoritative signal left — the server sets it while the window is blocking
        /// requests, exactly as the CLI's own limit message reports.
        private func window(_ raw: Window, title: String) -> UsageWindow {
            let resetDate = raw.resetAt.map { Date(timeIntervalSince1970: Self.seconds(fromEpoch: $0)) }
            guard raw.cap > 0 else {
                return UsageWindow(title: title, percent: raw.exceeded == true ? 100 : 0, resetDate: resetDate)
            }
            return UsageWindow(
                title: title, percent: min(max(raw.used / raw.cap * 100, 0), 100), resetDate: resetDate,
                usedCents: raw.used * 100, limitCents: raw.cap * 100)
        }

        /// Epoch milliseconds today, epoch seconds in the community tools' older captures of
        /// this endpoint. Anything below the millisecond range is treated as seconds, so a
        /// server-side switch back does not make every reset date land in 1970.
        private static func seconds(fromEpoch value: Double) -> Double {
            value > 100_000_000_000 ? value / 1000 : value
        }
    }
}
