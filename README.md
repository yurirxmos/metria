# Metria

*A native macOS app that tracks your AI coding assistant usage in real time.*

<p align="center">
  <img src="https://i.imgur.com/LuYjNBr.gif" alt="Metria demo" width="720" />
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

Metria shows current session and monthly usage percentages for supported AI providers.

- **Floating sidebar** — hover a provider logo to preview its usage card.
- **Menu bar** — compact text labels for each provider.
- **Dashboard popover** — ring gauges plus detailed per-provider cards.

The native app stores provider selection, display mode, sidebar position, and opacity in macOS `UserDefaults`.

## Download

Pick your platform, open the installer, and you're all set. Browse macOS installers on the [Releases page](https://github.com/yurirxmos/metria/releases).

Download the native `.dmg` for Apple Silicon or Intel Macs.

## To do

- Build native iOS and Android apps to improve usage update delivery and replace the existing PWA.

### Shared

- Add usage-aware sounds and animations.

## Providers

Providers are enabled automatically only when their local credentials or usage files are detected. Providers that are not installed remain available in Settings with setup guidance.

- **Claude** — OAuth token read from the macOS Keychain, usage fetched from the Anthropic usage endpoint.
- **Codex / OpenCode** — credentials read from `~/.local/share/opencode/auth.json` and local session files.
- **OpenCode Go** — API key read from the same `auth.json`, usage fetched from the OpenCode Go endpoint.
- **Cursor** — JWT read from Cursor's `state.vscdb` (VS Code global storage SQLite database), usage fetched from Cursor's dashboard endpoint. This endpoint is not published by Cursor and can change without notice, outside this project's control.

The native app reads credentials at runtime from the Keychain and local configuration files. See the [native provider sources](apps/macos-native/Sources/Metria/Providers/).

Credentials are never committed. The native app reads them at runtime from its documented local sources.

## Mobile PWA

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

## Requirements

- macOS 13 or later
- A Swift toolchain (Swift 5.9+) for building from source
- Xcode 26.0+ and XcodeGen for opening and building the Xcode project

## Quick start

Download the latest native macOS `.dmg` from [GitHub Releases](https://github.com/yurirxmos/metria/releases), choosing the package for your Mac:

- **Apple Silicon** — M-series Macs.
- **Intel** — Intel-based Macs.

Open the disk image, drag `Metria.app` to `Applications`, and launch it from Finder or Spotlight. Metria runs in the menu bar and does not open a regular application window.

> **macOS warns that Metria can't be opened or is from an unidentified developer?** Releases are ad hoc signed but not yet notarized with an Apple Developer ID (see [note below](#run-in-development)), so macOS Gatekeeper flags the downloaded app — this does not mean the file is corrupted. Open **System Settings → Privacy & Security**, scroll to the Metria warning, and choose **Open Anyway**, then confirm in the dialog that follows. If that option isn't available, remove the quarantine attribute in Terminal instead:
>
> ```sh
> xattr -cr /Applications/Metria.app
> ```
>
> Then launch the app normally.

### Run in development

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

This creates `dist/Metria-<version>-<architecture>.zip` and `.dmg`. GitHub Releases build Intel and Apple Silicon archives automatically when a `macos-v*` tag is pushed, then publish a signed Sparkle appcast per architecture through the dedicated `macos-latest` update channel (Sparkle's `generate_appcast` cannot mix two architectures under one bundle version, so each build points at its own feed). Configure `SPARKLE_PUBLIC_ED_KEY` and `SPARKLE_PRIVATE_ED_KEY` for automatic updates. Apple Developer ID signing and notarization are optional while the project is in development; without them, the archive is only ad hoc signed and macOS Gatekeeper will still show an unidentified-developer warning.

To publish a native macOS release:

```sh
git tag macos-v0.2.0
git push origin macos-v0.2.0
```

## Project layout

- `apps/macos-native/Sources/Metria/MetriaApp.swift` — native macOS entrypoint, AppKit coordinator, pairing, and views.
- `apps/macos-native/Sources/Metria/Providers/` — native macOS provider implementations and credential readers.
- `apps/macos-native/Sources/MetriaCore/UsageStore.swift` — native usage state, provider seam, and refresh/retry logic.
- `apps/macos-native/Resources/AppIcon.icon` — Icon Composer source for the native app icon.
- `apps/macos-native/scripts/package-macos.sh` — reproducible native macOS app bundle and archive builder.

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

- Run `swift build` from the repository root.
- Runtime-test native macOS changes on macOS 13 or later.

### Mobile PWA

- Build the stylesheet with `cd apps/pwa && npm ci && npm run build`.
- Deploy changes with `npm run deploy` from `apps/pwa` when appropriate.

See the [project layout](#project-layout) to find where each change belongs. Thanks for helping out!

## License

Metria is open source under MIT; see [LICENSE](LICENSE).
