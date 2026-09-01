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
SDK, so no new package dependency), against a **copy** of the database rather
than the live file. Do not add a SQLite package, do not shell out to
`/usr/bin/sqlite3`, and do not attempt to decrypt anything Cursor chose to
encrypt.

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

## Phase 0 — Credential and endpoint discovery (BLOCKING GATE)

Runs on a Mac with Cursor installed and signed in. Produces evidence, not code.

1. Confirm the database and inspect the auth keys:
   ```sh
   DB=~/"Library/Application Support/Cursor/User/globalStorage/state.vscdb"
   sqlite3 "$DB" "select key from ItemTable where key like 'cursorAuth%' or key like '%cursor%' order by key;"
   ```
   Expected keys include `cursorAuth/accessToken`, `cursorAuth/refreshToken`,
   `cursorAuth/cachedEmail`, and a membership/plan key. Record the exact key
   names and the shape of each value; do not record the values themselves.
2. Determine whether the access token is stored in cleartext in `ItemTable`, or
   only as an Electron `safeStorage` blob backed by the "Cursor Safe Storage"
   Keychain item.
   - **Gate A**: the token is readable without decrypting anything Cursor
     encrypted. If it is not, **stop here**. Record the finding and treat the
     team Admin API path (below) as the only remaining option; do not implement
     Keychain-derived decryption of another app's secrets.
3. Establish which usage endpoint answers for a signed-in individual account,
   and capture one anonymized response body per candidate as a fixture:
   - `GET https://cursor.com/api/usage?user=<userId>` with
     `Cookie: WorkosCursorSessionToken=<userId>%3A%3A<token>`
   - `GET https://cursor.com/api/auth/me` (identity, user id, plan)
   - the monthly-invoice / filtered-usage-events dashboard endpoints, for
     usage-based ("included usage" in dollars) plans
   - `https://api.cursor.com/teams/daily-usage-data` — the **documented** Admin
     API, but it needs a team admin key that individual accounts do not have
   - **Gate B**: at least one endpoint returns, for an individual account, both
     a quota position (used vs. limit, or a percentage) and a reset boundary. If
     none does, stop: Metria cannot render a card it cannot compute.
4. Record whether the token needs a refresh flow, and if so which endpoint
   performs it. If it does, mirror `ClaudeProvider`'s 401-then-refresh-then-retry
   shape (`apps/macos-native/Sources/Metria/Providers/ClaudeProvider.swift:12-18`),
   but never write back into Cursor's database.
5. Write the findings into a "Decision log" section at the bottom of this file,
   with the date and the Cursor version they were observed on.

Phases 1-5 are authorized only after Gates A and B both pass.

## Phase 1 — Read-only access to Cursor's state database

New file `apps/macos-native/Sources/Metria/Providers/CursorStateStore.swift`.

- `import SQLite3` (system module, no package dependency).
- Copy `state.vscdb` — plus `-wal` and `-shm` siblings when present — into
  `FileManager.default.temporaryDirectory` before opening, then delete the copy.
  Cursor holds the live database open in WAL mode; copying avoids both a write
  attempt against another app's file and the stale reads that
  `immutable=1` would produce.
- Open the copy with `sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)`
  and read with a prepared `SELECT value FROM ItemTable WHERE key = ?1`. Treat
  values as `BLOB`/UTF-8 text and decode JSON only where Phase 0 recorded JSON.
- Surface every failure as `ProviderError.unavailable` rather than trapping; a
  missing table, a schema change, or a locked file must degrade to an unavailable
  provider, never a crash.
- Keep the type free of AppKit and provider-specific logic so it can be tested
  against a synthetic database.
- **Gate**: `swift build` passes and a throwaway harness reads a key from a
  hand-made SQLite file with the same schema.

## Phase 2 — The provider

New file `apps/macos-native/Sources/Metria/Providers/CursorProvider.swift`,
modeled on `OpenCodeGoProvider`.

- `isAvailable`: `state.vscdb` exists **and** the auth key recorded in Phase 0 is
  present. File existence alone is true for anyone who ever opened Cursor once,
  which would show a permanently failing card.
- `setupHint`: "Sign in to Cursor to make usage available."
- `fetch()`:
  - read the credential through `CursorStateStore`;
  - call the Phase 0 endpoint with the same three-attempt / `Retry-After` /
    `ProviderError.http(status)` handling the other providers use
    (`apps/macos-native/Sources/Metria/Providers/OpenCodeGoProvider.swift:28-46`);
  - map the response to windows. Name them from the data, not from the other
    providers: a request-quota plan yields "This month" with the billing-cycle
    reset; a usage-based plan yields spend against the included budget. If both
    are present, emit both, most-urgent first — `primary` is `windows.first`
    (`apps/macos-native/Sources/MetriaCore/UsageStore.swift:31`) and it is what
    the rail and menu bar show;
  - return `.failed(kind, message, retryAfter:)` on every error path.
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
2. **Credential storage moves.** Cursor may move the token into `safeStorage` in
   any release. Mitigation: `isAvailable` checks the key, not the file, so the
   provider silently drops out instead of failing loudly; Gate A is re-run
   whenever that happens.
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
- **Decrypting Cursor's `safeStorage` blob via the "Cursor Safe Storage" Keychain
  item**: rejected. Metria reads credentials other apps left readable; it does
  not defeat another app's encryption.
- **Counting local Cursor session files** the way `CodexProvider` falls back
  (`apps/macos-native/Sources/Metria/Providers/CodexProvider.swift:54-56`):
  rejected as the primary source. Cursor's local chat storage records requests,
  not the account quota, so any percentage would be fabricated.
- **Shipping the team Admin API only**: rejected as the default, since it
  requires a team admin key. It remains the documented fallback if Gate A fails,
  as a separate, opt-in "paste your admin key" plan.

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

## Decision log

- _(Phase 0 findings go here: Cursor version, key names, endpoint chosen,
  response shape, and the Gate A / Gate B verdicts.)_
