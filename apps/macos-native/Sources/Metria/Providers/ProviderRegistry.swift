import MetriaCore

/// Single place that lists every usage provider the app can fetch from.
///
/// To add a new provider:
/// 1. Add a case to `ProviderKind` in `MetriaCore/UsageStore.swift`.
/// 2. Add its symbol/logo/gradient to `ProviderKind+Presentation.swift`.
/// 3. Implement `UsageProvider` in a new file under this folder.
/// 4. Register an instance below.
enum ProviderRegistry {
    static func makeProviders() -> [any UsageProvider] {
        // Claude Code may keep several accounts apart as `~/.claude-<slug>` directories
        // (e.g. `CLAUDE_CONFIG_DIR=~/.claude-work claude`). One provider per profile is
        // registered, default first and the rest alphabetical, so each account gets its own
        // ring, its own limits and its own row in Settings.
        let claudeProviders = ClaudeProfile.discover().map { ClaudeProvider(profile: $0) }
        return claudeProviders + [
            CodexProvider(),
            OpenCodeGoProvider(),
            CursorProvider(),
            AntigravityProvider()
        ]
    }
}
