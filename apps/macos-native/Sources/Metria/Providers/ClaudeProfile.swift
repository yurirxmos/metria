import CryptoKit
import Foundation
import MetriaCore

/// One Claude Code configuration directory, and so one account.
///
/// Claude Code keeps everything for an account under a single directory: `~/.claude` by
/// default, or wherever `CLAUDE_CONFIG_DIR` points. People who keep a personal and a work
/// login apart do it by aliasing the second one to `~/.claude-work`, `~/.claude-client`,
/// and so on — each with its own token in the keychain and its own sessions folder.
/// Reading only `~/.claude` shows one of those accounts and is blind to the others: a work
/// session never spins the ring, and the work limit is never drawn at all.
///
/// A profile is the *convention* `~/.claude-<slug>`, not the environment variable: the app
/// is launched from Finder, so the alias's variable never reaches it, and the directories
/// are the only trace the profiles leave.
struct ClaudeProfile: Equatable, Hashable {
    /// What every profile directory starts with.
    static let directoryPrefix = ".claude"

    /// Nil for `~/.claude`; the part after `.claude-` otherwise.
    let slug: String?
    let configDirectory: URL

    /// The account-scoped identity this profile reads as — `Claude` for the default,
    /// `Claude-<slug>` for the rest. Doubles as the usage provider id, so a profile's
    /// sessions land in its own ring.
    var providerID: ProviderID { ProviderID(kind: .claude, slug: slug) }

    var displayName: String { providerID.displayName }

    /// `~/.claude`, whether or not it exists — the app has always read it.
    static func `default`(home: URL = homeDirectory) -> ClaudeProfile {
        ClaudeProfile(
            slug: nil,
            configDirectory: home.appendingPathComponent(directoryPrefix))
    }

    static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// The default profile followed by every `~/.claude-<slug>` that Claude Code has
    /// actually used, slugs in alphabetical order so the rings never swap places between
    /// launches.
    ///
    /// "Actually used" is judged by the files Claude Code writes on its first run — an
    /// empty directory, or a stray one someone made by hand, would otherwise put a
    /// permanent "sign in" ring in the notch for an account that does not exist.
    static func discover(
        home: URL = homeDirectory,
        fileManager: FileManager = .default
    ) -> [ClaudeProfile] {
        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        let extras = names
            .compactMap { name -> ClaudeProfile? in
                guard let slug = slug(fromDirectoryName: name) else { return nil }
                let directory = home.appendingPathComponent(name)
                guard isProfileDirectory(directory, fileManager: fileManager) else { return nil }
                return ClaudeProfile(slug: slug, configDirectory: directory)
            }
        return [ClaudeProfile.default(home: home)]
            + extras.sorted { $0.slug! < $1.slug! }
    }

    /// `.claude-work` → `work`; anything else → nil. The bare `.claude` is the default and
    /// is handled separately; `.claude.json` is a file that lives beside it and is not a
    /// profile at all.
    static func slug(fromDirectoryName name: String) -> String? {
        let prefix = directoryPrefix + "-"
        guard name.hasPrefix(prefix) else { return nil }
        let slug = String(name.dropFirst(prefix.count))
        return slug.isEmpty ? nil : slug
    }

    /// Any of the files Claude Code creates the first time it runs against a directory. One
    /// is enough: they are not all present on every version.
    private static let markers = [
        "sessions", "projects", "settings.json", "history.jsonl", ".claude.json",
    ]

    static func isProfileDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return false }
        return markers.contains {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    // MARK: - What Claude Code keeps where

    /// Where Claude Code writes one file per running process.
    var sessionsDirectory: URL { configDirectory.appendingPathComponent("sessions") }

    /// Where Claude Code keeps its agent-transcript projects.
    var projectsDirectory: URL { configDirectory.appendingPathComponent("projects") }

    /// Claude Code's own settings file, which carries the signed-in address.
    ///
    /// The default profile keeps it *beside* the directory, at `~/.claude.json`; a profile
    /// reached through `CLAUDE_CONFIG_DIR` keeps it *inside* its own directory. Reading the
    /// wrong one shows the personal account against the work ring, so the distinction
    /// matters more than it looks.
    var accountFileURL: URL {
        slug == nil
            ? configDirectory.deletingLastPathComponent().appendingPathComponent(".claude.json")
            : configDirectory.appendingPathComponent(".claude.json")
    }

    /// Who is signed in, read from that file.
    ///
    /// Worth having because the keychain token does not carry an address, so until now the
    /// settings row could not say *which* account a ring was for — the one question two
    /// Claude rings actually raise. It is also readable without a keychain prompt, which is
    /// the whole point of asking here.
    func signedInAddress() -> String? {
        struct Config: Decodable {
            struct Account: Decodable { let emailAddress: String? }
            let oauthAccount: Account?
        }
        guard
            let data = try? Data(contentsOf: accountFileURL),
            let config = try? JSONDecoder().decode(Config.self, from: data),
            let address = config.oauthAccount?.emailAddress,
            !address.isEmpty
        else { return nil }
        return address
    }

    /// Every keychain service a profile's token might be filed under, in the order to prefer
    /// them — newest wins across the lot at read time.
    ///
    /// A profile's token is filed under the bare name plus a suffix: the first eight hex
    /// digits of the SHA-256 of the directory's absolute path, no trailing slash. That is
    /// Claude Code's rule, not ours. The subtlety is *when* Claude Code applies it to the
    /// default directory: it suffixes whenever `CLAUDE_CONFIG_DIR` is set in the shell it
    /// runs from, and a shell that exports the variable exports it even when it points at
    /// the default `~/.claude` — so the default profile's live token can sit under
    /// `Claude Code-credentials-<hash of ~/.claude>` rather than the bare name. Older Claude
    /// Code, and an unset variable, keep the bare name for the default. Reading only the
    /// bare name therefore finds a stale, months-old duplicate on such a machine and the
    /// ring waits for a first reading that never comes, while a current token sits one
    /// service name away.
    ///
    /// So the default profile offers both, suffixed first; a named profile is only ever
    /// written suffixed. `KeychainReader` picks the most recently written item across them.
    var keychainServices: [String] {
        let suffixed =
            "\(Self.defaultKeychainService)-\(Self.keychainSuffix(forPath: configDirectory.path))"
        return slug == nil ? [suffixed, Self.defaultKeychainService] : [suffixed]
    }

    /// The primary service — the first candidate. Retained for callers and tests that name a
    /// single service.
    var keychainService: String { keychainServices.first! }

    static let defaultKeychainService = "Claude Code-credentials"

    static func keychainSuffix(forPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    // MARK: - Copy

    /// Which tool the credential is borrowed from, said so that two Claude rows in Settings
    /// can be told apart.
    var sourceName: String {
        slug == nil ? "Claude Code" : "Claude Code in ~/.claude-\(slug!)"
    }

    /// The command that signs this profile in, for the row that has no button.
    var signInCommand: String {
        slug == nil ? "claude" : "CLAUDE_CONFIG_DIR=\(displayPath) claude"
    }

    /// The directory as a person would type it.
    var displayPath: String { Self.tilde(configDirectory.path) }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }
}
