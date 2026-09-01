# Metria

*A native macOS app and parallel Electron app that track your AI coding assistant usage in real time.*

<p align="center">
  <img src="https://i.imgur.com/JrV7abR.png" alt="Metria banner" width="480" />
</p>

<p align="center">
  <a href="https://github.com/yurirxmos/metria/stargazers"><img src="https://img.shields.io/github/stars/yurirxmos/metria?style=flat-square" alt="Stars" /></a>
  <a href="https://github.com/yurirxmos/metria/releases"><img src="https://img.shields.io/github/v/tag/yurirxmos/metria?label=version&style=flat-square" alt="Version" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square" alt="License" /></a>
  <a href="https://github.com/yurirxmos/metria/commits"><img src="https://img.shields.io/github/commit-activity/m/yurirxmos/metria?style=flat-square" alt="Commits" /></a>
</p>

## Contents

- [What it does](#what-it-does)
- [Download](#download)
- [To do](#to-do)
- [Providers](#providers)
- [Mobile PWA](#mobile-pwa)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Project layout](#project-layout)
- [Contributing](#contributing)
- [License](#license)

## What it does

Both desktop versions show current session and monthly usage percentages for supported AI providers.

### Mac version

- **Floating sidebar** — hover a provider logo to preview its usage card.
- **Menu bar** — compact text labels for each provider.
- **Dashboard popover** — ring gauges plus detailed per-provider cards.

The native app stores provider selection, display mode, sidebar position, and opacity in macOS `UserDefaults`.

### Electron version

- **Usage widget** — a right-edge widget for provider usage cards on Windows and Linux.
- **System tray** — compact access to provider usage and controls.
- **Dashboard window** — detailed per-provider cards and usage gauges.

The Electron app stores its settings in its own `com.metria.electron` application-data namespace.

## Download

Pick your platform, open the installer, and you're all set. Browse all installers on the [Releases page](https://github.com/yurirxmos/metria/releases).

### Mac version

Download the native `.dmg` for Apple Silicon or Intel Macs.

### Electron version

Download the Windows `.exe` or Linux `.AppImage`. Electron releases are for Windows and Linux only; macOS is served by the native app.

## To do

### Mac version

- Build native iOS and Android apps to improve usage update delivery and replace the existing PWA.

### Electron version

- Improve Metria compatibility and runtime support for Windows and Linux.

### Shared

- Add usage-aware sounds and animations.

## Providers

Providers are enabled automatically only when their local credentials or usage files are detected. Providers that are not installed remain available in Settings with setup guidance.

### Mac version

- **Claude** — OAuth token read from the macOS Keychain, usage fetched from the Anthropic usage endpoint.
- **Codex / OpenCode** — credentials read from `~/.local/share/opencode/auth.json` and local session files.
- **OpenCode Go** — API key read from the same `auth.json`, usage fetched from the OpenCode Go endpoint.

The native app reads credentials at runtime from the Keychain and local configuration files. See the [native provider sources](apps/macos-native/Sources/Metria/Providers/).

### Electron version

- **Claude** — credentials read from `~/.claude/.credentials.json` on Unix and from the equivalent host or WSL location on Windows.
- **Codex** — credentials and the newest session read from `CODEX_HOME`/`~/.codex`, including WSL locations on Windows.
- **OpenCode Go** — credentials read from `XDG_DATA_HOME`/`~/.local/share/opencode/auth.json` on Unix, `%APPDATA%` on Windows, or the WSL path.

Electron discovers provider data on the host filesystem and, on Windows, in installed WSL distributions. See the [Electron provider documentation](apps/electron/README.md).

Credentials are never committed. Both versions read them at runtime from their documented local sources.

## Mobile PWA

### Mac version

Metria's companion PWA works on compatible iPhone and Android browsers. Start the native Mac app, then scan the QR code in **Settings > Phone** while the phone and Mac are on the same Wi-Fi network. The local server port defaults to `8973` and can be changed in Settings; if it is in use, Metria tries subsequent ports automatically.

The local HTTP server is available for same-network pairing, but browsers require HTTPS to install a PWA or use Web Push. Metria uses the hosted Cloudflare PWA by default at `https://metria-pwa.yuriramos2406.workers.dev`. Clear **Settings > Phone > Custom PWA URL** to pair through the local server instead. Build and deploy the static files with:

```sh
cd apps/pwa
npm ci
npm run build
npm run deploy
```

You can replace the Cloudflare URL in **Settings > Phone > Custom PWA URL** with any HTTPS static host.

#### Mobile alerts

Install the Cloudflare-hosted PWA on your phone, open it, and select **Enable alerts**. Metria sends the current provider usage whenever the Mac app publishes a new snapshot. The local HTTP server cannot provide system notifications because Web Push requires HTTPS.

### Electron version

The Electron version does not include phone pairing, the local PWA server, QR pairing, or mobile alerts.

## Requirements

### Mac version

- macOS 13 or later
- A Swift toolchain (Swift 5.9+) for building from source
- Xcode 26.0+ and XcodeGen for opening and building the Xcode project

### Electron version

- Windows or Linux for the supported desktop application
- Node.js 22+ and npm for building from source
- Windows and Linux builds must be created and runtime-tested on their respective platforms

## Quick start

### Mac version

Download the latest native macOS `.dmg` from [GitHub Releases](https://github.com/yurirxmos/metria/releases), choosing the package for your Mac:

- **Apple Silicon** — M-series Macs.
- **Intel** — Intel-based Macs.

Open the disk image, drag `Metria.app` to `Applications`, and launch it from Finder or Spotlight. Metria runs in the menu bar and does not open a regular application window.

### Electron version

The Electron version supports Windows and Linux. Download the installer for your operating system from [GitHub Releases](https://github.com/yurirxmos/metria/releases). You can also build it on that operating system:

```sh
cd apps/electron
npm ci
npm run package
```

The host-native installer is created in `apps/electron/release/`. See the [Electron documentation](apps/electron/README.md) for current platform support and provider limitations.

### Run in development

#### Mac version

```sh
swift build
swift run Metria
```

To create a local macOS application archive for installation:

```sh
bash apps/macos-native/scripts/package-macos.sh
```

Packaging requires Xcode 26 or later because the app icon is authored with
Icon Composer. The Xcode asset compiler also generates fallback icon assets for
macOS 13–25.

To build the Xcode application without Apple Developer signing credentials:

```sh
xcodegen generate --spec apps/macos-native/project.yml
xcodebuild -project apps/macos-native/Metria.xcodeproj -scheme Metria -configuration Release -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

The generated `Metria.app` is at `.build/xcode/Build/Products/Release/Metria.app`.
The Xcode project disables signing by default for local development. A future
Developer ID build can override `CODE_SIGNING_ALLOWED`, `CODE_SIGNING_REQUIRED`,
and `CODE_SIGN_IDENTITY` from the command line or an xcconfig.

This creates `dist/Metria-<version>-<architecture>.zip` and `.dmg`. GitHub Releases build Intel and Apple Silicon archives automatically when a `v*` tag is pushed, then publish the signed Sparkle appcast as `releases/latest/download/appcast.xml`. Configure `SPARKLE_PUBLIC_ED_KEY` and `SPARKLE_PRIVATE_ED_KEY` for automatic updates. Apple Developer ID signing and notarization are optional while the project is in development; without them, the archive is unsigned and macOS may show a Gatekeeper warning.

#### Electron version

Run the Electron app on Windows or Linux:

```sh
cd apps/electron
npm ci
npm run dev
```

Run the Electron checks and create a host-native installer with:

```sh
npm run check
npm run package
```

Electron artifacts are written to `apps/electron/release/`. macOS packaging is not configured for Electron.

## Project layout

### Mac version

- `apps/macos-native/Sources/Metria/MetriaApp.swift` — native macOS entrypoint, AppKit coordinator, pairing, and views.
- `apps/macos-native/Sources/Metria/Providers/` — native macOS provider implementations and credential readers.
- `apps/macos-native/Sources/MetriaCore/UsageStore.swift` — native usage state, provider seam, and refresh/retry logic.
- `apps/macos-native/Resources/AppIcon.icon` — Icon Composer source for the native app icon.
- `apps/macos-native/scripts/package-macos.sh` — reproducible native macOS app bundle and archive builder.

### Electron version

- `apps/electron/` — parallel Windows/Linux implementation with secure main/preload/renderer boundaries.

### Mobile PWA

- `apps/pwa/` — mobile companion PWA and its Cloudflare Worker (`public/` holds the static site, `src/worker.js` the Worker).

## Contributing

Contributions are welcome! Feel free to open an issue to report a bug or suggest a feature, or open a pull request with your changes.

- Fork the repository and create a branch from `main`.
- Keep changes focused and follow the existing code style.
- Keep all repository text in en-US (comments, UI strings, commit messages, docs).
- Do not commit credentials, generated build output, or local configuration.

Join the Metria contributors group on WhatsApp to ask questions, share feedback, and help shape the project.

<p align="center">
  <a href="https://chat.whatsapp.com/KE2hbxgNmWYAyrUrjvU6Br?s=cl&p=i&mlu=4">
    <img src="https://img.shields.io/badge/WhatsApp%20Group-Contributors-25D366?style=for-the-badge&logo=whatsapp&logoColor=white" alt="Join the WhatsApp contributors group" />
  </a>
</p>

### Mac version

- Run `swift build` from the repository root.
- Runtime-test native macOS changes on macOS 13 or later.

### Electron version

- Run `cd apps/electron && npm ci && npm run check`.
- Create and runtime-test Windows and Linux packages on their respective platforms.
- Do not claim Electron macOS support; macOS uses the native app.

### Mobile PWA

- Build the stylesheet with `cd apps/pwa && npm ci && npm run build`.
- Deploy changes with `npm run deploy` from `apps/pwa` when appropriate.

See the [project layout](#project-layout) to find where each change belongs. Thanks for helping out!

## License

Metria is open source under MIT; see [LICENSE](LICENSE).
