// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Metria",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "Metria", targets: ["Metria"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .target(name: "MetriaCore", path: "apps/macos-native/Sources/MetriaCore"),
        .executableTarget(
            name: "Metria",
            dependencies: ["MetriaCore", .product(name: "Sparkle", package: "Sparkle")],
             path: ".",
             exclude: ["AGENTS.md", "README.md", "LICENSE", ".build", "dist", ".github", "plans", "apps/macos-native/Resources", "apps/macos-native/Sources/MetriaCore", "apps/macos-native/Metria.xcodeproj", "apps/macos-native/project.yml", "apps/macos-native/scripts", "apps/pwa/bun.lock", "apps/pwa/src", "apps/pwa/package.json", "apps/pwa/package-lock.json", "apps/pwa/tailwind.config.js", "apps/pwa/wrangler.jsonc", "apps/pwa/public/tailwind.input.css", "apps/pwa/public/metria-logo.png", "apps/pwa/public/metria-mascot.png"],
            sources: [
                "apps/macos-native/Sources/Metria/MetriaApp.swift",
                "apps/macos-native/Sources/Metria/MetriaResources.swift",
                "apps/macos-native/Sources/Metria/LocalNetwork.swift",
                 "apps/macos-native/Sources/Metria/LocalPWAServer.swift",
                 "apps/macos-native/Sources/Metria/ProviderActivityMonitor.swift",
                "apps/macos-native/Sources/Metria/Providers/AntigravityProvider.swift",
                "apps/macos-native/Sources/Metria/Providers/ClaudeProvider.swift",
                "apps/macos-native/Sources/Metria/Providers/CodexProvider.swift",
                "apps/macos-native/Sources/Metria/Providers/CursorProvider.swift",
                "apps/macos-native/Sources/Metria/Providers/CursorStateStore.swift",
                "apps/macos-native/Sources/Metria/Providers/KeychainReader.swift",
                "apps/macos-native/Sources/Metria/Providers/OpenCodeGoProvider.swift",
                "apps/macos-native/Sources/Metria/Providers/ProviderError.swift",
                 "apps/macos-native/Sources/Metria/Providers/ProviderKind+Presentation.swift",
                  "apps/macos-native/Sources/Metria/Providers/ProviderRegistry.swift",
                 "apps/macos-native/Sources/Metria/Updater.swift",
                 "apps/macos-native/Sources/Metria/OnboardingView.swift"
             ],
              resources: [
                  .process("apps/macos-native/Sources/Metria/Localizable.xcstrings"),
                  .copy("Assets/antigravity-logo.png"),
                  .copy("Assets/claude-logo.png"),
                .copy("Assets/codex-logo.png"),
                .copy("Assets/cursor-logo.png"),
                .copy("Assets/metria-logo.png"),
                .copy("Assets/metria-mascot.png"),
                .copy("Assets/opencode-logo.png"),
                 .copy("apps/pwa/public/app.css"),
                 .copy("apps/pwa/public/app.js"),
                 .copy("apps/pwa/public/icon.svg"),
                 .copy("apps/pwa/public/index.html"),
                 .copy("apps/pwa/public/jsQR.js"),
                 .copy("apps/pwa/public/manifest.json"),
                 .copy("apps/pwa/public/pairing.js"),
                 .copy("apps/pwa/public/scanner.js"),
                 .copy("apps/pwa/public/sw.js"),
                 .copy("apps/pwa/public/wordlist.js")
            ]
        )
    ]
)
