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
        [
            ClaudeProvider(),
            CodexProvider(),
            OpenCodeGoProvider(),
            CursorProvider(),
            AntigravityProvider()
        ]
    }
}
