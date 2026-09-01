import Foundation
import MetriaCore

/// Fetches Cursor usage using the JWT Cursor stores in its VS Code-derived
/// global storage database, calling the same Connect-RPC endpoint the
/// Cursor dashboard uses. See plans/002-cursor-provider-macos.md for the
/// research this is based on.
struct CursorProvider: UsageProvider {
    let kind = ProviderKind.cursor
    let setupHint = "Sign in to Cursor to make usage available."
    let usageWindowTitles = ["This cycle"]

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
            guard let percent = usage.planUsage?.totalPercentUsed else { throw ProviderError.unavailable }
            return .loaded(ProviderUsage(kind: kind, windows: [
                UsageWindow(title: "This cycle", percent: percent, resetDate: usage.billingCycleEndDate)
            ], updatedAt: Date(), error: nil))
        } catch {
            let providerError = error as? ProviderError
            let message: String
            switch providerError {
            case .http(401), .http(403): message = "Sign in to Cursor again to refresh usage."
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
            request.httpBody = Data("{}".utf8)
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

    private struct CursorUsageResponse: Decodable {
        let planUsage: PlanUsage?
        let billingCycleEnd: String?

        var billingCycleEndDate: Date? {
            billingCycleEnd.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        }

        struct PlanUsage: Decodable {
            let totalPercentUsed: Double?
        }
    }
}
