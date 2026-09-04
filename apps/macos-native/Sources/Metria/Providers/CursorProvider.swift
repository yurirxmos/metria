import Foundation
import MetriaCore

/// Fetches Cursor usage using the JWT Cursor stores in its VS Code-derived
/// global storage database, calling the same Connect-RPC endpoint the
/// Cursor dashboard uses. See plans/002-cursor-provider-macos.md for the
/// research this is based on.
struct CursorProvider: UsageProvider {
    let kind = ProviderKind.cursor
    let setupHint = String(localized: "Sign in to Cursor to make usage available.")
    static let autoUsageTitle = String(localized: "Auto usage")
    static let apiUsageTitle = String(localized: "API usage")
    static let thisCycleTitle = String(localized: "This cycle")
    let usageWindowTitles = [autoUsageTitle, apiUsageTitle]

    private var stateStore: CursorStateStore {
        CursorStateStore(databaseURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb"))
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: stateStore.databaseURL.path) && stateStore.readItem("cursorAuth/accessToken") != nil
    }

    func fetch() async -> ProviderFetchResult {
        do {
            guard let token = stateStore.readItem("cursorAuth/accessToken") else { throw ProviderError.unavailable }
            guard !Self.isExpired(token) else { throw ProviderError.http(401) }
            let data = try await requestUsage(token: token)
            let usage = try JSONDecoder().decode(CursorUsageResponse.self, from: data)
            let windows = usage.windows(resetDate: usage.billingCycleEndDate)
            guard !windows.isEmpty else { throw ProviderError.unavailable }
            return .loaded(ProviderUsage(kind: kind, windows: windows, updatedAt: Date(), error: nil))
        } catch {
            let providerError = error as? ProviderError
            let message: String
            switch providerError {
            case .http(401), .http(403): message = String(localized: "Sign in to Cursor again to refresh usage.")
            default: message = error.localizedDescription
            }
            return .failed(kind, message, retryAfter: providerError?.retryAfter)
        }
    }

    private func requestUsage(token: String) async throws -> Data {
        for attempt in 0..<3 {
            var request = URLRequest(url: URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue("Metria/0.1", forHTTPHeaderField: "User-Agent")
            request.httpBody = Data(Self.usageRequestBody.utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            let httpResponse = response as? HTTPURLResponse
            let status = httpResponse?.statusCode ?? -1
            if status == 429 {
                let retryAfter = httpResponse?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? pow(2, Double(attempt + 1))
                guard attempt < 2 else { throw ProviderError.rateLimited(retryAfter: retryAfter) }
                try await Task.sleep(for: .seconds(min(retryAfter, 30)))
                continue
            }
            guard status == 200 else { throw ProviderError.http(status) }
            return data
        }
        throw ProviderError.unavailable
    }

    /// Decodes the JWT's `exp` claim without verifying its signature — Metria
    /// only wants to skip a pointless network call for a token it already
    /// knows has expired.
    private static func isExpired(_ token: String) -> Bool {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return false }
        var base64 = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let payloadData = Data(base64Encoded: base64),
              let payload = try? JSONDecoder().decode(JWTPayload.self, from: payloadData),
              let exp = payload.exp else { return false }
        return Date(timeIntervalSince1970: exp) < Date()
    }

    private struct JWTPayload: Decodable { let exp: Double? }

    /// Without `includePooledUsage`, a team or enterprise account gets a stub
    /// answer back — no `planUsage`, no `spendLimitUsage`, and a billing cycle
    /// whose start and end are the same instant — which reads as "this account
    /// has no usage". The flag is what makes the server fill in the seat's real
    /// spend and limit.
    private static let usageRequestBody = #"{"includePooledUsage":true}"#

    private struct CursorUsageResponse: Decodable {
        let planUsage: PlanUsage?
        let spendLimitUsage: SpendLimitUsage?
        let billingCycleEnd: String?

        var billingCycleEndDate: Date? {
            billingCycleEnd.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        }

        struct Measure {
            let percent: Double
            var usedCents: Double?
            var limitCents: Double?
        }

        /// Follows the order Cursor's own usage bar uses: a plan with a real
        /// included limit is measured against that limit, and an account whose
        /// quota lives in a seat spend limit — team and enterprise seats, which
        /// report a `planUsage` of all zeroes — is measured against the seat's
        /// individual, then overall, limit. Every amount Cursor sends is in cents,
        /// and the pair that produced the percent travels with it so a card can
        /// print "$130 / $250" for the same bar. The last fallback is a bare
        /// percentage, which carries no amounts to show.
        var measure: Measure? {
            spent(planUsage?.includedSpend, planUsage?.limit)
                ?? spent(spendLimitUsage?.individualUsed, spendLimitUsage?.individualLimit)
                ?? spent(spendLimitUsage?.overallUsed, spendLimitUsage?.overallLimit)
                ?? planUsage?.totalPercentUsed.map { Measure(percent: $0) }
        }

        private func spent(_ used: Double?, _ limit: Double?) -> Measure? {
            guard let used, let limit, limit > 0 else { return nil }
            return Measure(percent: min(used / limit * 100, 100), usedCents: used, limitCents: limit)
        }

        struct PlanUsage: Decodable {
            let includedSpend: Double?
            let limit: Double?
            let autoPercentUsed: Double?
            let apiPercentUsed: Double?
            let totalPercentUsed: Double?
        }

        struct SpendLimitUsage: Decodable {
            let individualUsed: Double?
            let individualLimit: Double?
            let overallUsed: Double?
            let overallLimit: Double?
        }

        func windows(resetDate: Date?) -> [UsageWindow] {
            let percentWindows = [
                planUsage?.autoPercentUsed.map { UsageWindow(title: CursorProvider.autoUsageTitle, percent: clamped($0), resetDate: resetDate) },
                planUsage?.apiPercentUsed.map { UsageWindow(title: CursorProvider.apiUsageTitle, percent: clamped($0), resetDate: resetDate) }
            ].compactMap { $0 }
            guard percentWindows.isEmpty else { return percentWindows }
            guard let measure else { return [] }
            return [UsageWindow(title: CursorProvider.thisCycleTitle, percent: measure.percent, resetDate: resetDate,
                                usedCents: measure.usedCents, limitCents: measure.limitCents)]
        }

        private func clamped(_ percent: Double) -> Double {
            min(max(percent, 0), 100)
        }
    }
}
