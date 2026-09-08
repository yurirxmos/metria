import Foundation
import MetriaCore
import Security

/// Reads credentials that other apps store in the macOS Keychain on the user's behalf.
///
/// Claude Code creates its OAuth credential as a Keychain generic password owned by Claude
/// Code, not by Metria. macOS therefore shows an authorization prompt the first time Metria
/// reads it — and because Metria's release builds are unsigned (`CODE_SIGNING_ALLOWED: NO`),
/// macOS treats every rebuild as a different app and re-prompts each time. To avoid that, the
/// first authorized read is cached to a file Metria owns; later launches read that file and
/// never touch the Keychain again, exactly like the Antigravity/Codex providers do.
///
/// Every read is scoped to a `ClaudeProfile`: each profile keeps its own credential, its own
/// on-disk cache file (matching the one Claude Code files its token under), and its own
/// in-memory copy, so two `~/.claude-<slug>` logins never collide.
enum KeychainReader {
    private static let lock = NSLock()
    private static var cachedClaudeCredentials: [String: ClaudeCredentials] = [:]  // key: ProviderID.rawValue
    private static var attemptedClaudeCredentialsReads: Set<String> = []

    static func hasClaudeCredentials(for profile: ClaudeProfile) -> Bool {
        lock.lock()
        let isReadSuccessful = cachedClaudeCredentials[profile.providerID.rawValue] != nil
        let hasAttemptedRead = attemptedClaudeCredentialsReads.contains(profile.providerID.rawValue)
        lock.unlock()
        // Do not probe the Keychain while UsageStore is being initialized. The first actual
        // provider fetch performs the single protected read instead.
        return isReadSuccessful || !hasAttemptedRead
    }

    static func readClaudeCredentials(for profile: ClaudeProfile) throws -> ClaudeCredentials {
        let id = profile.providerID
        lock.lock()
        defer { lock.unlock() }
        if let cached = cachedClaudeCredentials[id.rawValue] { return cached }
        guard !attemptedClaudeCredentialsReads.contains(id.rawValue) else { throw ProviderError.unavailable }
        attemptedClaudeCredentialsReads.insert(id.rawValue)

        // The disk cache (written after the very first authorized Keychain read) is the normal
        // path — it never prompts. Only fall through to the Keychain when there is no cache.
        if let cachedDocument = ClaudeCredentialCache.load(for: id),
           let credentials = makeCredentials(from: cachedDocument) {
            cachedClaudeCredentials[id.rawValue] = credentials
            return credentials
        }

        if let document = readKeychainDocument(services: profile.keychainServices),
           let credentials = makeCredentials(from: document) {
            cachedClaudeCredentials[id.rawValue] = credentials
            ClaudeCredentialCache.save(for: id, document)
            return credentials
        }
        throw ProviderError.unavailable
    }

    /// Reads the newest Keychain generic password across the candidate service names a
    /// profile may use, so the live token wins over a stale, unsuffixed duplicate.
    private static func readKeychainDocument(services: [String]) -> [String: Any]? {
        var newestItem: (date: Date, document: [String: Any])?
        for service in services {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnAttributes as String: true,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let item = result as? [String: Any],
                  let data = item[kSecValueData as String] as? Data,
                  let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let modified = item[kSecAttrModificationDate as String] as? Date
            else { continue }
            if newestItem == nil || modified > newestItem!.date {
                newestItem = (modified, document)
            }
        }
        return newestItem?.document
    }

    static func storeClaudeCredentials(
        _ credentials: ClaudeCredentials,
        accessToken: String,
        refreshToken: String?,
        for profile: ClaudeProfile
    ) {
        let id = profile.providerID
        lock.lock()
        defer { lock.unlock() }
        guard var oauth = credentials.document["claudeAiOauth"] as? [String: Any] else { return }

        oauth["accessToken"] = accessToken
        if let refreshToken {
            oauth["refreshToken"] = refreshToken
        }
        var document = credentials.document
        document["claudeAiOauth"] = oauth
        guard let updatedCredentials = makeCredentials(from: document) else { return }

        cachedClaudeCredentials[id.rawValue] = updatedCredentials
        ClaudeCredentialCache.save(for: id, document)
    }

    static func invalidateClaudeCredentialsCache(for profile: ClaudeProfile) {
        let id = profile.providerID
        lock.lock()
        cachedClaudeCredentials[id.rawValue] = nil
        attemptedClaudeCredentialsReads.remove(id.rawValue)
        lock.unlock()
        ClaudeCredentialCache.remove(for: id)
    }

    private static func makeCredentials(from document: [String: Any]) -> ClaudeCredentials? {
        guard let oauth = document["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              let refreshToken = oauth["refreshToken"] as? String else { return nil }
        return ClaudeCredentials(
            document: document,
            accessToken: accessToken,
            refreshToken: refreshToken,
            scopes: oauth["scopes"] as? [String]
        )
    }

    /// One on-disk copy per profile of Claude Code's credential, kept restricted to the
    /// current user. Deliberately JSON so the same loading logic used for the Keychain
    /// document can read it. The default profile keeps the original, unsuffixed file name so
    /// an existing cache survives the multi-account change untouched.
    private enum ClaudeCredentialCache {
        private static var directoryURL: URL {
            FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Metria", isDirectory: true)
        }

        static func fileURL(for id: ProviderID) -> URL {
            let name = id.isDefaultAccount
                ? "claude-credentials"
                : "claude-credentials-\(id.slug!)"
            return directoryURL.appendingPathComponent("\(name).json")
        }

        static func load(for id: ProviderID) -> [String: Any]? {
            guard let data = try? Data(contentsOf: fileURL(for: id)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return object
        }

        static func save(for id: ProviderID, _ document: [String: Any]) {
            do {
                try FileManager.default.createDirectory(
                    at: directoryURL, withIntermediateDirectories: true)
                let data = try JSONSerialization.data(
                    withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: fileURL(for: id), options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: fileURL(for: id).path)
            } catch {
                // Best-effort. If the write fails the provider still works; it just re-reads the
                // Keychain (and re-prompts) next launch.
                FileHandle.standardError.write(
                    "[KeychainReader] cache save failed: \(error)\n".data(using: .utf8)!)
            }
        }

        static func remove(for id: ProviderID) {
            try? FileManager.default.removeItem(at: fileURL(for: id))
        }
    }

    static func accountEmail(from credentials: ClaudeCredentials) -> String? {
        if let oauth = credentials.document["claudeAiOauth"] as? [String: Any],
           let email = oauth["email"] as? String,
           email.contains("@") {
            return email
        }
        return tokenEmail(credentials.accessToken)
    }

    /// Reads the plan name Claude Code caches locally next to the OAuth tokens: prefers
    /// `subscriptionType` (e.g. "max", "claude_pro_2025"), falling back to `rateLimitTier`
    /// (e.g. "default_claude_max_5x") when that's missing. Best-effort — both fields are
    /// undocumented and have been observed absent in some Claude Code versions.
    static func planLabel(from credentials: ClaudeCredentials) -> String? {
        guard let oauth = credentials.document["claudeAiOauth"] as? [String: Any] else { return nil }
        if let subscriptionType = oauth["subscriptionType"] as? String, !subscriptionType.isEmpty {
            return planDisplayName(subscriptionType)
        }
        if let rateLimitTier = oauth["rateLimitTier"] as? String, !rateLimitTier.isEmpty {
            return planDisplayName(rateLimitTier)
        }
        return nil
    }

    private static func planDisplayName(_ raw: String) -> String {
        let normalized = raw.lowercased()
        let multiplier = normalized.range(of: #"\d+x"#, options: .regularExpression).map { String(normalized[$0]) }
        if normalized.contains("max") { return ["Max", multiplier].compactMap { $0 }.joined(separator: " ") }
        if normalized.contains("enterprise") { return "Enterprise" }
        // Team plan seats come in two tiers ("Standard" and "Premium"); check the more
        // specific "premium" match first so it isn't swallowed by the generic "team" check.
        if normalized.contains("team") {
            if normalized.contains("premium") { return "Team Premium" }
            if normalized.contains("standard") { return "Team Standard" }
            return "Team"
        }
        if normalized.contains("pro") { return "Pro" }
        return raw.capitalized
    }

    static func tokenEmail(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let data = Data(base64Encoded: String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + String(repeating: "=", count: (4 - parts[1].count % 4) % 4)),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ["email", "preferred_username", "unique_name"].compactMap { claims[$0] as? String }.first { $0.contains("@") }
    }

    struct ClaudeCredentials {
        fileprivate let document: [String: Any]
        let accessToken: String
        let refreshToken: String
        let scopes: [String]?
    }
}
