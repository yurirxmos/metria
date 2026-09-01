# Plan 002: Add a Cursor usage provider to the native macOS app

> **Executor instructions**: Follow this plan in order. Phase 0 is a research
> gate that must run on a real Mac with Cursor installed and signed in; it
> cannot be completed from CI or from a container. If a gate fails, stop and
> record the evidence in this file's decision log. Do not ship a provider that
> guesses at a response shape, and do not work around credential encryption.
>
> **Drift check (run first)**:
> `git diff --stat a16b53b..HEAD -- Package.swift apps/macos-native/Sources apps/pwa/public plans`
> If any listed path has changed, compare the current behavior described below
> with the live code and update this plan before implementation.

## Status

- **Priority**: P2
- **Effort**: M (one provider, one new local-storage reader, one research gate)
- **Risk**: MEDIUM (credential location and usage endpoints are undocumented and
  can change without notice; both are outside this project's control)
- **Depends on**: none
- **Category**: feature
- **Planned at**: commit `a16b53b`, 2026-09-01

## Decision

Add **Cursor** as a fourth `ProviderKind` in the native macOS app, following the
existing provider contract exactly: discover a local credential, call the
vendor's usage endpoint, and map the answer onto `UsageWindow` values. Cursor
differs from the three current providers in one way only, and that difference
drives most of this plan: Cursor does not keep its credential in a JSON file or
in the Keychain the way Claude Code, Codex, and OpenCode do. It is an
Electron/VS Code derivative, so its signed-in state lives in the VS Code global
storage database:

```
~/Library/Application Support/Cursor/User/globalStorage/state.vscdb
```

That file is SQLite, with a single relevant table `ItemTable(key, value)` and
keys under the `cursorAuth/` prefix. Metria therefore needs a small read-only
SQLite reader before it can have a Cursor provider at all.

Read that database through the system `SQLite3` module (available in the macOS
SDK, so no new package dependency), opening the live file read-only via a
`file:...?mode=ro` URI. Do not add a SQLite package and do not shell out to
`/usr/bin/sqlite3`.

The credential itself is a plain JWT in `ItemTable` under
`cursorAuth/accessToken`; usage comes from the same Connect-RPC endpoint the
Cursor dashboard calls, `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`,
which answers with `planUsage.totalPercentUsed` and the billing-cycle bounds —
exactly the percent-plus-reset-date shape Metria's cards already render. Both
facts are corroborated by shipping third-party tools; see "Evidence" below.

## Why this matters

Cursor is the most requested provider Metria does not cover, and it is the only
mainstream assistant in this category whose usage is quota-shaped in the same
way the existing cards already render (a percentage plus a reset date). The
provider surface is already designed for this: `ProviderRegistry` documents a
four-step recipe (`apps/macos-native/Sources/Metria/Providers/ProviderRegistry.swift:3-9`),
`UsageStore` handles availability, caching, retry-after, and per-provider
failure without any provider-specific code, and the settings, notch rail, menu
bar, and PWA all iterate `ProviderKind.allCases`. The work is therefore not in
the UI; it is in credential discovery and in being honest about an endpoint the
vendor does not publish.

## Verified current state

1. `ProviderKind` has exactly three cases and is the single source of truth for
   the UI, persistence, and the PWA payload
   (`apps/macos-native/Sources/MetriaCore/UsageStore.swift:16-22`).
2. A provider is four members: `kind`, `isAvailable`, `setupHint`, and an async
   `fetch()` returning `ProviderFetchResult`
   (`apps/macos-native/Sources/MetriaCore/UsageStore.swift:47-52`).
   `OpenCodeGoProvider` is the closest template: read a local credential, one
   HTTPS call with a bearer token, 429 handling with `Retry-After`, decode into
   windows (`apps/macos-native/Sources/Metria/Providers/OpenCodeGoProvider.swift:5-46`).
3. Registration is a single line in `ProviderRegistry.makeProviders()`
   (`apps/macos-native/Sources/Metria/Providers/ProviderRegistry.swift:10-17`).
4. Presentation is a set of exhaustive switches — `symbol`, `reconnectCommand`,
   `logoName`, `sidebarProgressGradient` — that will fail to compile until the
   new case is handled, which is the intended safety net
   (`apps/macos-native/Sources/Metria/Providers/ProviderKind+Presentation.swift:8-38`).
5. "Reconnect" copies `reconnectCommand` to the pasteboard and runs it in
   Terminal via AppleScript (`apps/macos-native/Sources/Metria/MetriaApp.swift:1626-1638`).
   Cursor has no `login` CLI verb, so the command must be something a shell can
   actually execute.
6. Enabled providers are persisted as raw strings under `enabledProviderKinds`.
   On launch, a **non-empty** saved set wins outright; the available-kinds union
   is used only when nothing was saved
   (`apps/macos-native/Sources/MetriaCore/UsageStore.swift:84-87`). Every
   existing user has a non-empty saved set, so a newly added provider is
   silently disabled for all of them unless this plan changes that.
7. SwiftPM lists provider sources and bundled logos file by file
   (`Package.swift:22-33`, `Package.swift:35-40`), while the XcodeGen target
   globs `Sources/Metria` (`apps/macos-native/project.yml:26-35`). New files
   must be added to `Package.swift` or `swift build` will not see them.
8. The PWA maps provider names to logo files in its own table
   (`apps/pwa/public/app.js:71`), and `Package.swift:19` excludes each PWA logo
   individually.

## Phase 0 — Confirm the mechanism on the target machine (short)

The mechanism is no longer an open question; it is documented in the "Evidence"
section at the end of this plan and implemented by shipping third-party tools.
What remains is confirming it against the Cursor version the developer is
running, because none of it is a published contract.

1. Confirm the token is present and readable:
   ```sh
   sqlite3 "$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb" \
     "SELECT key FROM ItemTable WHERE key LIKE 'cursorAuth/%';"
   ```
   Expect `cursorAuth/accessToken`, `cursorAuth/refreshToken`,
   `cursorAuth/cachedEmail`, and a membership key. The access token is a plain
   JWT string in `ItemTable`, not an Electron `safeStorage` blob.
2. Confirm the usage endpoint answers for this account:
   ```sh
   TOKEN=$(sqlite3 "$HOME/Library/Application Support/Cursor/User/globalStorage/state.vscdb" \
     "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken';")
   curl -s -X POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage \
     -H "Authorization: Bearer $TOKEN" \
     -H "Content-Type: application/json" \
     -H "Connect-Protocol-Version: 1" \
     -d '{}'
   ```
   Expect `planUsage.totalPercentUsed` and the `billingCycleStart` /
   `billingCycleEnd` millisecond strings.
3. Record the Cursor version and the response shape in the decision log. If the
   account is request-based (a Team plan) rather than spend-based,
   `planUsage.totalPercentUsed` may be absent — see Phase 2's fallback.
4. **Gate**: both commands answer. If the token is missing or the endpoint
   refuses it, stop and record which one failed; do not guess a replacement.

## Phase 1 — Read-only access to Cursor's state database

New file `apps/macos-native/Sources/Metria/Providers/CursorStateStore.swift`.

- `import SQLite3` — the system module in the macOS SDK, so no package
  dependency.
- Open **read-only through a URI**, without copying the file:
  `file:<path>?mode=ro` first, falling back to `file:<path>?immutable=1`, with
  flags `SQLITE_OPEN_READONLY | SQLITE_OPEN_URI`. This works while Cursor is
  running and holding the WAL; a plain read-only open of the live file is the
  proven path (see Evidence), so do not copy the database unless step 2 of
  Phase 0 shows otherwise.
- Read with a prepared `SELECT value FROM ItemTable WHERE key = ? LIMIT 1`.
- Expose `readItem(_ key: String) -> String?` and nothing else; return `nil` on
  every failure (missing file, missing table, missing key) so the provider maps
  it to one clear `ProviderError.unavailable`.
- Keep the type free of AppKit so it can be exercised against a synthetic
  database with the same schema.
- **Gate**: `swift build` passes and a throwaway harness reads a key from a
  hand-made SQLite file.

## Phase 2 — The provider

New file `apps/macos-native/Sources/Metria/Providers/CursorProvider.swift`,
modeled on `OpenCodeGoProvider`.

- `isAvailable`: `state.vscdb` exists **and** `cursorAuth/accessToken` is
  present. File existence alone is true for anyone who ever opened Cursor once,
  which would show a permanently failing card.
- `setupHint`: "Sign in to Cursor to make usage available."
- Before the request, decode the JWT's `exp` claim (base64url of the second
  segment, no signature verification — Metria is not validating the token, only
  avoiding a pointless call) and fail early with a "sign in to Cursor again"
  message when it has passed.
- Primary request:
  ```
  POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage
  Authorization: Bearer <cursorAuth/accessToken>
  Content-Type: application/json
  Connect-Protocol-Version: 1
  body: {}
  ```
  This is Cursor's own dashboard call over Connect RPC's JSON encoding, so
  `URLSession` and `JSONDecoder` are enough — no protobuf or Connect library.
  Reuse the existing three-attempt / `Retry-After` / `ProviderError.http(status)`
  handling (`apps/macos-native/Sources/Metria/Providers/OpenCodeGoProvider.swift:28-46`).
- Map the response:
  - `planUsage.totalPercentUsed` → the percent of the primary window;
  - `billingCycleEnd` (a **string** of milliseconds) → `resetDate`;
  - title the window from the cycle, e.g. "This cycle", not "Current session" —
    Cursor's quota is a billing period, and reusing Claude's five-hour label
    would misdescribe it;
  - `planUsage.autoPercentUsed` and `apiPercentUsed` are available for a second
    window if the card should split included vs. API usage; `totalSpend` is in
    cents.
- Fallback for request-based (Team) plans, where `planUsage.totalPercentUsed`
  can be absent: `GET https://cursor.com/api/usage?user=<userId>` with
  `Cookie: WorkosCursorSessionToken=<userId>%3A%3A<accessToken>`, where
  `<userId>` is the `user_...` half of the JWT's `sub` claim
  (`auth0|user_XXXXXXXX`). It returns per-model `numRequests` /
  `maxRequestUsage` plus `startOfMonth`; derive the percent from those two.
  Implement this only if Phase 0 shows the primary call returning no percentage
  for the account at hand — do not build both paths speculatively.
- **No refresh flow.** Cursor's session JWT is long-lived and Metria has no
  documented refresh grant for it; on 401/403, report "sign in to Cursor again"
  and re-read the database on the next refresh. Never write to Cursor's
  database.
- Register the instance in `ProviderRegistry.makeProviders()`.

## Phase 3 — Kind, presentation, and assets

- Add `case cursor = "Cursor"` to `ProviderKind`
  (`apps/macos-native/Sources/MetriaCore/UsageStore.swift:16-22`).
- Handle the new case in all four switches in
  `ProviderKind+Presentation.swift`: `symbol` (`cursorarrow.rays` is a
  reasonable SF Symbol fallback), `logoName` (`cursor-logo`),
  `sidebarProgressGradient`, and `reconnectCommand`. For reconnect, use
  `open -a Cursor` — it is a real shell command, which is what
  `reconnectProvider` requires; a fake `cursor login` string would paste a
  command that fails.
- Add `Assets/cursor-logo.png` and register it in `Package.swift` `resources:`
  (`Package.swift:35-40`). The Xcode target copies `Assets/*.png` wholesale
  (`apps/macos-native/project.yml:31-35`), so no change is needed there.
- Add both new source files to `Package.swift` `sources:` (`Package.swift:22-33`).

## Phase 4 — Enablement migration for existing installs

Without this, every current user gets a Cursor entry that is permanently off.

- Add a `knownProviderKinds` key to `UsageStore`. On init, compute
  `newKinds = availableKinds - knownKinds` and union those into
  `enabledProviderKinds` before persisting `knownProviderKinds =
  ProviderKind.allCases`.
- A provider the user explicitly turned off must stay off: only kinds that were
  never known before may be auto-enabled.
- **Gate**: with a `UserDefaults` suite pre-seeded as
  `enabledProviderKinds = ["Claude"]`, a store built with a Cursor provider that
  reports available ends up enabled for Cursor and still disabled for Codex and
  OpenCode Go.

## Phase 5 — Companion PWA and documentation

- Add `cursor-logo.png` to `apps/pwa/public/`, extend the logo map
  (`apps/pwa/public/app.js:71`), and add the file to the `Package.swift:19`
  exclude list, matching how the other three logos are handled.
- Update the README "Providers → Mac version" list with the Cursor entry and its
  credential source, and this repository's provider count wherever it is stated.
- Note in the README that Cursor usage comes from an endpoint Cursor does not
  publish, so it can break outside Metria's control.

## Risks

1. **Undocumented endpoints.** The Cursor dashboard API is not a public contract.
   Mitigation: one provider, one decode site, failures isolated per provider by
   `UsageStore`; the card degrades to an error string rather than breaking the
   app.
2. **Credential storage moves.** The token is plaintext in `ItemTable` today,
   but Cursor could move it into Electron `safeStorage` or the Keychain in any
   release — its `cursor-agent` CLI already keeps a `cursor-access-token`
   Keychain item. Mitigation: `isAvailable` checks the key, not the file, so the
   provider drops out quietly instead of failing loudly, and the Keychain item
   is the obvious second source to add if that happens (`KeychainReader`
   already exists for Claude).
3. **Plan shapes differ.** Pro, Business, and usage-based accounts report
   different quantities. Mitigation: derive window titles from the response;
   never render a percentage Metria had to invent.
4. **Reading another app's database.** Mitigation: copy-then-read, read-only
   open, no writes to Cursor's directory ever.
5. **Scope creep into a Cursor sign-in flow.** Out of scope. Metria reads
   credentials that other apps created; it does not authenticate on their behalf.

## Alternatives considered and rejected

- **Adding a SQLite Swift package** (GRDB, SQLite.swift): rejected. The system
  `SQLite3` module covers a single-table point read, and the app currently has
  exactly one dependency (Sparkle).
- **Shelling out to `/usr/bin/sqlite3`**: rejected. It is not guaranteed present
  on a signed, notarized app's supported systems in the future, and process
  spawning for a point read is worse than a prepared statement.
- **Parsing the SQLite file format by hand** to avoid the import: rejected as
  unmaintainable.
- **Decrypting anything Cursor chose to encrypt.** Not needed today (the token
  is plaintext), and rejected as an approach: Metria reads credentials other
  apps left readable; it does not defeat another app's encryption. If Cursor
  ever encrypts the token, add the `cursor-agent` Keychain item as a source or
  drop the provider — do not decrypt.
- **Counting local Cursor session files** the way `CodexProvider` falls back
  (`apps/macos-native/Sources/Metria/Providers/CodexProvider.swift:54-56`):
  rejected as the primary source. Cursor's local chat storage records requests,
  not the account quota, so any percentage would be fabricated.
- **Cursor's official team Admin API** (`https://api.cursor.com/teams/...`):
  rejected as the default. It is the only *documented* API, but it needs a team
  admin key that individual accounts do not have, so it cannot serve Metria's
  typical user. Keep it as a separate, opt-in "paste your admin key" plan if
  team dashboards are ever wanted.

## Verification

```sh
swift build                       # required repository verification (AGENTS.md)
```

Manual checks on a Mac with Cursor signed in:

1. Cursor appears in Settings → Providers, enabled, with usage inside one refresh
   interval.
2. Sign out of Cursor: the card becomes unavailable with the setup hint, and the
   other three providers keep updating.
3. "Diagnose" reports the real state; "Reconnect" opens Cursor.
4. The notch rail, menu bar labels, dashboard, and paired PWA all show the Cursor
   logo and percentage.

## Evidence

Researched 2026-09-01. None of this is a published Cursor contract; all of it is
corroborated by more than one independently maintained tool.

- **Token location and schema** — `state.vscdb`, table `ItemTable`, keys
  `cursorAuth/accessToken`, `cursorAuth/refreshToken`, `cursorAuth/cachedEmail`;
  paths are `~/Library/Application Support/Cursor/User/globalStorage/` on macOS,
  `%APPDATA%\Cursor\User\globalStorage\` on Windows, and
  `~/.config/Cursor/User/globalStorage/` on Linux.
  Sources: [eisbaw/cursor_api_demo](https://github.com/eisbaw/cursor_api_demo),
  [Dwtexe/cursor-stats#36](https://github.com/Dwtexe/cursor-stats/issues/36),
  [Tendo33/cursor-usage-tracker](https://github.com/Tendo33/cursor-usage-tracker).
- **The token is a plain JWT, not an encrypted blob** — read today by a plain
  `sqlite3 ... "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken'"`.
  Note that this is also why it is a known exposure: any Cursor extension can
  read it ([LayerX, "CursorJacking"](https://layerxsecurity.com/blog/cursorjacking-every-cursor-user-is-vulnerable-to-api-key-theft-by-rogue-extensions/)).
  Metria only reads it and sends it to Cursor's own host.
- **Usage endpoint** — `POST https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage`
  with `Authorization: Bearer`, `Content-Type: application/json`,
  `Connect-Protocol-Version: 1`, body `{}`; response carries
  `planUsage.totalPercentUsed`, `autoPercentUsed`, `apiPercentUsed`,
  `totalSpend` (cents), and `billingCycleStart` / `billingCycleEnd` as
  millisecond strings.
  Source: [cursor-checker/macos](https://github.com/cursor-checker/macos) —
  `Sources/CursorChecker/Services/CursorUsageClient.swift`, a Swift menu-bar app
  released 2026-07-28 that does precisely this, including the read-only
  `mode=ro` / `immutable=1` SQLite open and the JWT `exp` pre-check.
- **Request-based plans** — `GET https://cursor.com/api/usage?user=<userId>` with
  `Cookie: WorkosCursorSessionToken=<userId>%3A%3A<token>` returns per-model
  `numRequests` / `maxRequestUsage` / `startOfMonth`; `<userId>` is the
  `user_...` half of the JWT `sub` (`auth0|user_...`).
  Sources: [robinebers/openusage#244](https://github.com/robinebers/openusage/issues/244),
  [Tendo33/cursor-usage-tracker](https://github.com/Tendo33/cursor-usage-tracker).
- **Prior art at Metria's exact scope** — [openusage](https://github.com/robinebers/openusage)
  ships Cursor alongside Claude, Codex, and OpenCode, reading credentials
  already on the machine
  ([provider doc](https://github.com/robinebers/openusage/blob/main/docs/providers/cursor.md)).

## Decision log

- **Phase 0 confirmed 2026-09-01** on Cursor 3.18.9 (macOS). `state.vscdb`
  contains `cursorAuth/accessToken`, `cursorAuth/cachedEmail`,
  `cursorAuth/cachedScopedProfile`, `cursorAuth/cachedSignUpType`,
  `cursorAuth/onboardingDate`, `cursorAuth/refreshToken`,
  `cursorAuth/stripeMembershipAuthId`, `cursorAuth/stripeMembershipType`,
  `cursorAuth/stripeSubscriptionStatus`. `POST
  .../GetCurrentPeriodUsage` answered with `planUsage.totalPercentUsed: 0`,
  `autoPercentUsed: 0`, `apiPercentUsed: 0`, plus `billingCycleStart` /
  `billingCycleEnd` millisecond strings — a spend-based plan, so the
  request-based (Team) fallback in Phase 2 was **not** implemented; add it
  later if an account without `planUsage.totalPercentUsed` is observed.
