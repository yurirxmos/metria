import Foundation

/// Errors surfaced by usage providers when a request fails or a required
/// resource (credentials, session files) is unavailable.
enum ProviderError: Error, LocalizedError {
    case unavailable
    case http(Int)
    case expiredOpenCodeGoKey
    case rateLimited(retryAfter: TimeInterval?)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return String(localized: "Provider data is unavailable.")
        case .http(401):
            return String(localized: "Authentication expired and could not be refreshed.")
        case .http(403):
            return String(localized: "The provider rejected the stored credentials.")
        case .expiredOpenCodeGoKey:
            return String(localized: "The OpenCode Go API key expired. Create a new key in OpenCode Console.")
        case .http(let status):
            return String(localized: "The provider returned HTTP \(status).")
        case .rateLimited:
            return String(localized: "The provider is rate limited.")
        }
    }

    var retryAfter: TimeInterval? {
        switch self {
        case .rateLimited(let delay): return max(60, delay ?? 300)
        default: return nil
        }
    }
}
