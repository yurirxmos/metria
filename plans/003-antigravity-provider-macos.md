# Plan 003: Add an Antigravity usage provider to the native macOS app

> **Executor instructions**: Follow this plan in order. Phase 0 is a research
> gate that must run on a real Mac with Antigravity installed and signed in; it
> cannot be completed from CI or from a container. If a gate fails, stop and
> record the evidence in this file's decision log. Do not ship a provider that
> guesses at a response shape, and do not work around credential encryption.
>
> **Drift check (run first)**:
> `git diff --stat 711778a..HEAD -- Package.swift apps/macos-native/Sources apps/pwa/public plans`
> If any listed path has changed, compare the current behavior described below
> with the live code and update this plan before implementation.

## Status

- **Priority**: P2
- **Effort**: M (one provider, no new local-storage reader, one research gate)
- **Risk**: MEDIUM (credential location and usage endpoints are undocumented and
  can change without notice; both are outside this project's control)
- **Depends on**: none
- **Category**: feature
- **Planned at**: commit `711778a`, 2026-09-04

## Decision

Add **Antigravity** as a fifth `ProviderKind` in the native macOS app, following
the existing provider contract exactly: discover a local capability, obtain the
vendor's usage answer, and map it onto `UsageWindow` values. Antigravity
differs from the four current providers in one way only, and that difference
drives most of this plan: Metria cannot touch the credential. The fresh
Antigravity token lives Keychain-only inside the `agy` CLI's own entry, and
this project's contributor constraint is **zero Keychain authorization prompts
in the shipped app** — the current app never prompts, and Antigravity support
must not start. So instead of reading a credential and calling an endpoint,
the provider shells out to the vendor's own CLI and parses its answer:

```
agy -p "/usage" </dev/null
```

which prints exactly the four windows Metria shows, as tab-separated lines
(group, window, remaining percent, ISO8601 reset):

```
Gemini Models           Weekly Limit Remaining      98%  2026-09-10T18:19:58Z
Gemini Models           Five Hour Limit Remaining   100% 2026-09-04T07:04:27Z
Claude and GPT models   Weekly Limit Remaining      100% 2026-09-11T02:04:27Z
Claude and GPT models   Five Hour Limit Remaining   100% 2026-09-04T07:04:27Z
```

The values are REMAINING fractions, so Metria maps
`percent = 100 - remaining`. Group labels map onto Metria's four windows as
follows:

| Window | Rule |
|---|---|
| 5-hour Gemini | `Gemini Models` × `Five Hour Limit Remaining` line |
| Weekly Gemini | `Gemini Models` × `Weekly Limit Remaining` line |
| 5-hour other models | `Claude and GPT models` × `Five Hour Limit Remaining` line |
| Weekly other models | `Claude and GPT models` × `Weekly Limit Remaining` line |

No horizon inference is needed: the vendor labels the windows itself, which
retires the derivation assumption the original draft of this plan carried.
`isAvailable` is "the `agy` binary exists". Credential handling — Keychain
reads, OAuth refresh grants, project discovery — stays entirely inside
Google's own binary. The direct cloud endpoint behind `/usage`
(`POST .../v1internal:retrieveUserQuotaSummary`, see Evidence) is documented
for a future revision but is NOT used: calling it from Metria would require
either a Keychain read (rejected by the zero-prompt constraint) or a vendored
OAuth client plus onboarding writes (rejected in Phase 0).

## Why this matters

Antigravity is the most requested provider Metria does not cover, and unlike
Cursor it needs no new local-storage machinery: the credential is a plain JSON
file and the quota endpoint speaks plain HTTPS + JSON, so the work is one
provider file plus the mechanical five-step registration every provider since
Cursor has followed. The provider surface is already designed for this:
`ProviderRegistry` documents the recipe
(`apps/macos-native/Sources/Metria/Providers/ProviderRegistry.swift:3-9`),
`UsageStore` handles availability, caching, retry-after, and per-provider
failure without any provider-specific code, and the settings, notch rail, menu
bar, and PWA all iterate `ProviderKind.allCases`.

## Verified current state

1. `ProviderKind` has exactly four cases and is the single source of truth for
   the UI, persistence, and the PWA payload
   (`apps/macos-native/Sources/MetriaCore/UsageStore.swift:84-91`).
2. A provider is five members: `kind`, `isAvailable`, `setupHint`,
   `usageWindowTitles`, and an async `fetch()` returning `ProviderFetchResult`
   (`apps/macos-native/Sources/MetriaCore/UsageStore.swift:122-128`).
   `OpenCodeGoProvider` is the closest template: read a local credential, one
   HTTPS call with a bearer token, 429 handling with `Retry-After`, decode into
   windows (`apps/macos-native/Sources/Metria/Providers/OpenCodeGoProvider.swift`).
3. Registration is a single line in `ProviderRegistry.makeProviders()`
   (`apps/macos-native/Sources/Metria/Providers/ProviderRegistry.swift:11-18`).
4. Presentation is a set of exhaustive switches — `symbol`, `reconnectCommand`,
   `logoName`, `sidebarProgressGradient` — that will fail to compile until the
   new case is handled, which is the intended safety net
   (`apps/macos-native/Sources/Metria/Providers/ProviderKind+Presentation.swift:7-42`).
5. "Reconnect" copies `reconnectCommand` to the pasteboard and runs it in
   Terminal via AppleScript. Antigravity has no `login` CLI verb, so the command
   must be something a shell can actually execute.
6. Enabled providers are persisted as raw strings under `enabledProviderKinds`.
   The `knownProviderKinds` migration (introduced for Cursor) auto-enables
   genuinely new kinds, so Antigravity lights up for existing installs without
   further migration work
   (`apps/macos-native/Sources/MetriaCore/UsageStore.swift:174-195`).
7. SwiftPM lists provider sources and bundled logos file by file
   (`Package.swift:19-36`, `Package.swift:37-55`), while the Xcode target copies
   `Assets/*.png` wholesale (`apps/macos-native/project.yml:40`). New files
   must be added to `Package.swift` or `swift build` will not see them; no
   `project.yml` change is needed.
8. The PWA maps provider names to logo files in its own table
   (`apps/pwa/public/app.js:82`), the PWA build copies each logo individually
   (`apps/pwa/package.json:5`), and `apps/pwa/public/.gitignore` lists the
   copied logos (note: `cursor-logo.png` is missing from that file — add both
   entries while here or leave Cursor alone; do not silently bundle unrelated
   fixes without noting them).
9. `ProviderActivityMonitor` matches running processes to providers and watches
   session directories for recent writes
   (`apps/macos-native/Sources/Metria/ProviderActivityMonitor.swift:42-60`).
   Cursor is matched on its bundle path (`cursor.app`) to avoid a macOS helper
   with a colliding name; pick Antigravity match strings with the same care.

## Phase 0 — Confirm the mechanism on the target machine (short) — CLOSED 2026-09-04

The original draft of this phase chased a direct cloud design (`oauth_creds.json`
+ `loadCodeAssist` + `fetchAvailableModels`). Running it refuted that design and
produced the CLI-subprocess design above; the steps are kept as the executed
record, with outcomes in the decision log.

1. Credential file keys (done): `~/.gemini/oauth_creds.json` holds
   `access_token`, `refresh_token`, `expiry_date` — but its token was expired.
2. Refresh + `loadCodeAssist` (done, refuted the cloud design): refresh with the
   Antigravity OAuth client fails (`unauthorized_client` — the token was minted
   for another client); refresh with the public Gemini CLI client succeeds, but
   `loadCodeAssist` under that identity returns only tiers
   (`allowedTiers: [standard-tier]`, free-tier `UNSUPPORTED_CLIENT`) with no
   project. `onboardUser` was deliberately NOT called (state-changing,
   potentially billing-related).
3. Vendor's own answer (done, confirmed the design): after the contributor
   signed in via the `agy` CLI, `agy -p "/usage" </dev/null` prints the four
   windows with vendor labels, remaining percents, and ISO8601 resets in ~3 s
   (full output in the decision log). Its quota call is
   `POST .../v1internal:retrieveUserQuotaSummary` (CLI logs + binary strings).
4. Direct `retrieveUserQuotaSummary` from outside `agy` (done, negative):
   403 under the Gemini identity, 401 with the IDE's cached `state.vscdb` key
   (stale). The fresh token is Keychain-only (`gemini`/`antigravity`), which
   the zero-prompt constraint forbids the app from reading.
5. **Gate: CLOSED.** The provider shells out to `agy` and parses its output;
   no horizon inference, no credential handling, no Keychain code.

## Phase 1 — CLI discovery (no credential handling)

Inside `AntigravityProvider.swift` (no separate store file — there is no
credential file to read, by design).

- Locate the `agy` binary: the documented installer path
  `~/.local/bin/agy` first, then each directory in `PATH`. Resolve once per
  fetch (cheap) rather than caching across launches, so installs and removals
  are picked up without a restart.
- `isAvailable`: the binary exists AND is executable. Nothing else is probed —
  in particular, never touch the Keychain and never read `~/.gemini/` or
  Antigravity's directories. The zero-prompt constraint is structural: this
  provider links no Security-framework code path that could prompt.
- `setupHint`:
   "Install the Antigravity CLI, open Antigravity, and sign in to make usage available."
- **Gate**: `swift build` passes; with the binary renamed away temporarily the
  provider reports unavailable (setup hint, no card), and the other four
  providers keep updating.

## Phase 2 — The provider

`AntigravityProvider.swift`, modeled on `OpenCodeGoProvider`'s fetch shape but
with a `Process` call instead of a `URLSession` call.

- On each fetch, launch the resolved binary with fixed arguments
  `["-p", "/usage"]`, stdin set to `/dev/null` (the command takes no input —
  a closed stdin also keeps a signed-out CLI from blocking on an auth prompt),
  and a hard timeout (30 seconds, well above the ~3 seconds observed). Capture
  stdout only; discard stderr.
- Parse stdout as tab-separated `<group> <window> <NN>% <ISO8601>` lines:
  - Group `"Gemini Models"` → Gemini windows; group `"Claude and GPT models"`
    (match case-insensitively, and treat any other group label as "other
    models" so a vendor rename degrades to two correct windows rather than
    zero) → other-model windows.
  - Window `"Five Hour Limit Remaining"` → the 5-hour window;
    `"Weekly Limit Remaining"` → the weekly window. Match on the
    `Five Hour` / `Weekly` keywords so minor label edits do not break parsing.
  - Each window: `percent = 100 - remaining`, `resetDate` from the ISO8601
    timestamp (`ISO8601DateFormatter`, same as the other providers).
  - All four titles are `String(localized:)` — `"5-hour Gemini"`,
    `"Weekly Gemini"`, `"5-hour other models"`, `"Weekly other models"` — and
    all are listed in `usageWindowTitles`.
  - A group/window with no parseable line yields no window for that slot
    rather than an invented zero — never render a percentage Metria had to
    invent. If NO line parses, return `.failed` with the setup hint (covers
    signed-out CLI, which hangs past no output, and format changes alike).
- Non-zero exit status or timeout likewise maps to `.failed` with the setup
  hint, never to a crash; per-provider failure isolation in `UsageStore` keeps
  the other four providers updating.
- `accountLabel`: the CLI prints no email, so leave it nil (the card renders
  without an account line, like a provider with no session). `planLabel`: nil.
- Register the instance in `ProviderRegistry.makeProviders()`.
- **Gate**: with the CLI signed in, `fetch()` returns `.loaded` with four
  windows whose percents equal `100 - remaining` from a manual
  `agy -p "/usage"` run; with the CLI signed out, `.failed` with the setup
  hint within the timeout.

## Phase 3 — Kind, presentation, and assets

- Add `case antigravity = "Antigravity"` to `ProviderKind`
  (`apps/macos-native/Sources/MetriaCore/UsageStore.swift:84-91`).
- Handle the new case in all four switches in
  `ProviderKind+Presentation.swift`: `symbol` (a reasonable SF Symbol fallback,
  e.g. `sparkle` — but not `sparkles`, which Claude uses), `logoName`
  (`antigravity-logo`), `sidebarProgressGradient`, and `reconnectCommand`. For
  reconnect, use `open -a Antigravity` to open the app where the CLI-owned
  credential is authenticated.
- Extract the logo from the installed bundle and add it as
  `Assets/antigravity-logo.png` (square PNG, matching the other four):
  ```sh
  sips -s format png /Applications/Antigravity.app/Contents/Resources/icon.icns \
    --out /tmp/antigravity-logo.png
  ```
  Verify dimensions against `Assets/cursor-logo.png` and downscale/pad to match
  before committing. Register it in `Package.swift` `resources:`
  (`Package.swift:37-55`). The Xcode target copies `Assets/*.png` wholesale
  (`apps/macos-native/project.yml:40`), so no change is needed there.
- Add the new source file to `Package.swift` `sources:` (`Package.swift:19-36`).
- **Gate**: `swift build` passes with no exhaustive-switch errors remaining.

## Phase 4 — Activity monitor and UI text

- `ProviderActivityMonitor.swift`: add `.antigravity` to `processNamesByProvider`
  (match on the bundle path, e.g. `antigravity.app`, following the Cursor
  precedent — a bare `"agy"` substring risks false positives) and to
  `sessionDirectoriesByProvider` with
  `Library/Application Support/Antigravity/User/globalStorage`, whose WAL
  traffic reflects real agent activity the way Cursor's does.
- Update the provider-count prose wherever it is stated: `OnboardingView.swift`
  (the "Claude, Codex, OpenCode Go, and Cursor" line), `README.md` providers
  section, and `Localizable.xcstrings` (English + pt-BR, matching the existing
  entries). Check `MetriaApp.swift` for provider-count assumptions the same way
  (e.g. the per-kind color switch and the "Go" short-name special case).
- **Gate**: the notch rail, menu bar labels, dashboard card with all four
  windows, and the paired PWA show the Antigravity logo and percentages.

## Phase 5 — Companion PWA and documentation

- Add `antigravity-logo.png` to `apps/pwa/public/`, extend the logo map
  (`apps/pwa/public/app.js:82`), add the file to the PWA build copy list
  (`apps/pwa/package.json:5`) and to `apps/pwa/public/.gitignore`, matching how
  the other logos are handled.
- Update the README "Providers" list with the Antigravity entry and its
  credential source (`~/.gemini/oauth_creds.json`), and the provider count
  wherever it is stated.
- Note in the README that Antigravity usage comes from an endpoint Google does
  not publish, so it can break outside Metria's control (same disclaimer as
  Cursor's).
- Update `plans/README.md`: mark this plan's status (and fix the stale
  "None of the four provider credentials" sentence, which becomes five).

## Risks

1. **Spawning a subprocess on every refresh.** The Cursor plan rejected shelling
   out for a point read; here the fork is the whole design, because it is the
   only zero-prompt path to a fresh credential. Mitigation: the call runs on
   the existing ~5-minute refresh cadence (observed ~3 s, off the main actor),
   with a hard timeout; a future optimization is gating Antigravity refreshes
   on `ProviderActivityMonitor` activity. If the maintainer rejects subprocess
   use outright, there is no fallback provider design under the zero-prompt
   constraint — say so in the PR rather than silently adding Keychain code.
2. **Undocumented CLI output.** `/usage` print output is not a published
   contract and its labels can change. Mitigation: keyword matching (not full
   strings), per-slot omission instead of invented values, total failure
   degrading to the setup hint, and failures isolated per provider by
   `UsageStore`; the card degrades to an error string rather than breaking the
   app.
3. **CLI-gated availability.** IDE-only users (no `agy` binary) get no card;
   the setup hint must say the CLI is required. Mitigation: `isAvailable`
   checks the binary, so the provider drops out quietly instead of failing
   loudly; the CLI installs with one documented `curl | bash`.
4. **Signed-out CLI hangs.** Without a session, `agy -p` blocks past 30 s with
   no output (observed). Mitigation: closed stdin plus the hard timeout map
   this to the setup hint; never wait indefinitely.
5. **Reading another app's product.** Metria executes the vendor's binary and
   parses its human-readable output. Mitigation: fixed argv, closed stdin, no
   user data passed; the token is sent only to Google's own hosts by `agy`
   itself, and Metria never sees any credential.
6. **Scope creep into an Antigravity sign-in flow.** Out of scope. Metria reads
   quota the CLI already authenticated; it does not authenticate on the CLI's
    behalf; Reconnect only opens Antigravity so the user can authenticate there.

## Alternatives considered and rejected

- **Direct cloud call with a Metria-held token**
  (`POST .../v1internal:retrieveUserQuotaSummary` with a vendored OAuth
  client): rejected. Phase 0 proved the only refreshable local token belongs
  to the wrong identity (Gemini CLI → 403 `PERMISSION_DENIED`), the
  Antigravity-identity token is Keychain-only, and obtaining a project under
  the wrong identity needs `onboardUser` — a state-changing, potentially
  billing-related write that was deliberately not attempted.
- **Keychain read plus Metria-owned cache (the Claude pattern)**: rejected by
  the contributor zero-prompt constraint. The current app never authorizes
  Keychain access, and Antigravity support must not introduce the first prompt.
- **Decoding the cached `userStatus` proto from `state.vscdb`**
  (`antigravityUnifiedStateSync.userStatus`, base64'd protobuf): rejected. It
  needs a proto schema Metria does not have, and the IDE's cached `apiKey`
  alongside it is stale (401 `UNAUTHENTICATED` observed).
- **One window per model**: rejected. Antigravity exposes a dozen-plus models;
   a card per model breaks the one-card-per-provider layout every surface
  assumes. Four vendor-labeled windows fit the existing card that already renders
  three for OpenCode Go.

## Verification

```sh
swift build                       # required repository verification (AGENTS.md)
```

Manual checks on a Mac with Antigravity signed in:

1. Antigravity appears in Settings → Providers, enabled, with usage inside one
   refresh interval.
2. Sign out (`agy` logout or Keychain removal): the card becomes
   unavailable/failed with the setup hint within the timeout, and the other
   four providers keep updating.
3. "Diagnose" reports the real state; "Reconnect" opens Antigravity.
4. The notch rail, menu bar labels, dashboard (all four windows on hover), and
   paired PWA all show the Antigravity logo and percentages.
5. Signed-out hang path: with no CLI session, a refresh returns the setup hint
   in seconds (timeout path), never blocks the other providers, and never
   prompts for Keychain access.

## Evidence

Researched 2026-09-04. None of this is a published Google contract; all of it
is corroborated by more than one independently maintained tool plus direct
inspection of a signed-in Mac.

- **Credential location and schema** — `~/.gemini/oauth_creds.json` with
  `access_token`, `refresh_token`, `expiry_date` (ms epoch), `id_token`,
  `scope`, `token_type`; active account email in `~/.gemini/google_accounts.json`
  (`active` key). Confirmed by direct inspection on the target machine.
- **Secondary credential** — `state.vscdb`, table `ItemTable`, key
  `antigravityAuthStatus`, a JSON object with `name`, `email`, and `apiKey`
  (a `ya29.*` Google OAuth token). Confirmed readable with
  `SELECT key FROM ItemTable` on the target machine at
  `~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb`.
- **OAuth client** — client ID
  `1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com`,
  standard Google scopes (`cloud-platform`, `userinfo.email`,
  `userinfo.profile`, `cclog`, `experimentsandconfigs`), token endpoint
  `https://oauth2.googleapis.com/token`.
  Source: [NoeFabris/opencode-antigravity-auth](https://github.com/NoeFabris/opencode-antigravity-auth/blob/main/src/constants.ts).
- **Quota endpoint** — `POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
  with `Authorization: Bearer`, body `{"project": <id>}`; response `models` is
  an object keyed by model ID, each entry with `quotaInfo: {remainingFraction,
  resetTime, isExhausted?}`; project ID from `POST .../v1internal:loadCodeAssist`
  (`cloudaicompanionProject`), which also returns `planInfo.planType` and prompt
  credits. Internal models (`chat_*`, `tab_*`, `rev*`, image/lite) carry no
  usable quota and are excluded.
  Sources: [opencode-antigravity-auth `src/plugin/quota.ts`](https://github.com/NoeFabris/opencode-antigravity-auth/blob/main/src/plugin/quota.ts)
  and [API spec](https://github.com/NoeFabris/opencode-antigravity-auth/blob/main/docs/ANTIGRAVITY_API_SPEC.md);
  [skainguyen1412/antigravity-usage](https://github.com/skainguyen1412/antigravity-usage)
  (`src/google/cloudcode.ts`, `src/google/parser.ts`) implements the identical
  call sequence including the `loadCodeAssist`-first project discovery.
- **Local-server alternative** —
  `POST /exa.language_server_pb.LanguageServerService/GetUserStatus` with
  `Connect-Protocol-Version: 1` and `X-Codeium-Csrf-Token`, answered by the
  language server on loopback; per-model quota under
  `cascadeModelConfigData.clientModelConfigs[].quotaInfo`.
  Source: [antigravity-usage `src/local/connect-client.ts`](https://github.com/skainguyen1412/antigravity-usage/blob/main/src/local/connect-client.ts).
  Also: [tungcorn/antigravity-usage-checker](https://github.com/tungcorn/antigravity-usage-checker)
  reads the same local API read-only.
- **Logo source** — `/Applications/Antigravity.app/Contents/Resources/icon.icns`,
  confirmed present on the target machine; convert with `sips -s format png`.
- **CLI `/usage` output (the provider's actual source)** — observed live on the
  target machine 2026-09-04 with a signed-in `agy` (`~/.local/bin/agy`, the
  documented installer path; the `~/.antigravity/…/agy` symlink is stale and
  no CLI ships inside the IDE bundle):
  ```sh
  agy -p "/usage" </dev/null   # ~3 s, tab-separated, ISO8601 resets
  ```
  prints one line per window: group (`Gemini Models`, `Claude and GPT models`),
  window (`Weekly Limit Remaining`, `Five Hour Limit Remaining`), remaining
  percent, reset timestamp. Pre-sign-in the same command blocks past 30 s with
  no output (hence closed stdin + hard timeout in Phase 2).
- **Quota endpoint behind `/usage`** —
  `POST https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary`,
  observed in `~/.gemini/antigravity-cli/log/cli-20260903_230115.log`
  (`quota_manager.go doRefreshQuota`, `Cache(retrieveUserQuotaSummary)`);
  proto surface from binary strings:
  `google.internal.cloud.code.v1internal.RetrieveUserQuotaSummaryRequest/Response`,
  `QuotaSummaryGroup`, `QuotaSummaryBucket{quotaBucketKey, remainingFraction}`.
  NOT called by this provider (see rejected alternatives).
- **Prior art at Metria's exact scope** — [openusage](https://github.com/robinebers/openusage)
  ships Cursor alongside Claude, Codex, and OpenCode reading machine-local
  credentials; Metria follows the same read-only posture for a fifth provider.

## Decision log

- **2026-09-04**: plan written. Contributor decisions locked during planning:
  credential = `~/.gemini/oauth_creds.json` with in-memory refresh (reads work
  from the app's existing `URLSession`+`JSONDecoder` infra, no new
  dependencies); one Antigravity card with four hover windows (5-hour/weekly ×
  Gemini/others); logo extracted from the installed app bundle. Phase 0 still
  has to confirm the reset-time horizon split on the target machine before any
  provider code is written.
- **Phase 0 partial findings, 2026-09-04** (target machine, all secrets redacted,
  nothing written anywhere):
  - `~/.gemini/oauth_creds.json` exists with the expected keys; its
    `access_token` was expired.
  - Refresh with the Antigravity OAuth client fails (`unauthorized_client`):
    this `refresh_token` was not minted for that client.
  - Refresh with the public Gemini CLI OAuth client succeeds (proves the
    refresh mechanics), but `loadCodeAssist` under that identity returns only
    `allowedTiers: [standard-tier]` / `ineligibleTiers: [free-tier =
    UNSUPPORTED_CLIENT, "migrate to the Antigravity suite"]` — no
    `cloudaicompanionProject`. The Gemini CLI identity is the wrong identity
    for Antigravity quota; calling `onboardUser` here would be a
    state-changing (possibly billing-related) action and was deliberately NOT
    attempted.
  - The IDE's cached `apiKey` in `state.vscdb` (`antigravityAuthStatus`) is
    stale: `loadCodeAssist` answers 401 `UNAUTHENTICATED`.
  - `agy -p "/usage"` with closed stdin hangs (needs interactive auth); the
    `agy` symlink under `~/.antigravity/` is stale (points at a removed
    `Desktop/Antigravity.app`); no CLI binary ships inside
    `/Applications/Antigravity.app`.
  - Conclusion at the time: the remaining read-only probe was the loopback
    language server while the IDE runs. SUPERSEDED by the CLI activation and
    the gate closure below — no IDE probing was needed.
- **Phase 0 resumed, 2026-09-04** (target machine, contributor activated via
  `agy` CLI on the same account):
  - `agy -p "/usage"` (stdin closed) prints exactly the four requested windows:
    `Gemini Models / Weekly Limit Remaining 98% / 2026-09-10T18:19:58Z`,
    `Gemini Models / Five Hour Limit Remaining 100% / 2026-09-04T07:04:27Z`,
    `Claude and GPT models / Weekly Limit Remaining 100% / 2026-09-11T02:04:27Z`,
    `Claude and GPT models / Five Hour Limit Remaining 100% / 2026-09-04T07:04:27Z`.
    Horizon split CONFIRMED from the vendor's own labels — no inference needed.
    Note the values are REMAINING fractions, so Metria maps
    `percent = 100 - remaining`.
  - `agy`'s quota call is `POST {daily,prod}-cloudcode-pa…/v1internal:retrieveUserQuotaSummary`
    (confirmed in `~/.gemini/antigravity-cli/log/cli-20260903_230115.log`:
    `quota_manager.go doRefreshQuota`, `Cache(retrieveUserQuotaSummary)`).
    Binary strings give the proto surface:
    `google.internal.cloud.code.v1internal.RetrieveUserQuotaSummaryRequest/Response`,
    `QuotaSummaryGroup`, `QuotaSummaryBucket{quotaBucketKey, remainingFraction}`.
  - The CLI's fresh credential is Keychain-only: generic password
    service `gemini` / account `antigravity`, `mdat` = CLI activation time.
    `~/.gemini/oauth_creds.json` was NOT touched by the CLI login.
  - `retrieveUserQuotaSummary` with `{}` under the Gemini CLI identity answers
    403 `PERMISSION_DENIED` on both daily and prod hosts — smoke test only, no
    writes.
- **Phase 0 closed, 2026-09-04** (contributor constraint: zero Keychain prompts
  in the shipped app — the current app never prompts):
  - The approved one-time Keychain read (terminal only, token kept in a shell
    variable, never printed or stored) returned a 690-char opaque token that is
    neither `ya29.`, JWT, `1//` refresh, nor JSON; it answers 401 on
    `retrieveUserQuotaSummary` under both hosts. It is the CLI's private token
    format — reverse-engineering it would work around the vendor's credential
    handling, so investigation stops here per this plan's own rule.
  - `agy --help` shows no dedicated quota subcommand; `/usage` via print mode
    is the interface. `agy -p "/usage" </dev/null` is stable across runs
    (~2.8 s wall, fresh resets each call) and needs no Keychain code in Metria.
  - Pivot locked: provider = `Process` + TSV parse (Phases 1–2 rewritten);
    direct-cloud and Keychain designs moved to Alternatives as rejected. The
    horizon-inference assumption from the first draft is retired — the vendor
    labels the windows itself.
- **Implemented + verified live, 2026-09-04** (branch `chore/antigravity-plan`):
  `swift build` green, `xcodegen` regen committed (new file only), `make run`
  (`xcodebuild` Debug) BUILD SUCCEEDED. The launched app auto-enabled
  Antigravity via the `knownProviderKinds` migration and cached four live
  windows (`5-hour Gemini 0%`, `Weekly Gemini 2%`, `5-hour other models 0%`,
  `Weekly other models 0%` — matching a manual `agy -p "/usage"` run);
  Claude/Codex/Cursor/OpenCode Go kept updating. Remaining manual check: logo
  rendering + hover card in Settings/notch (needs eyes on the GUI).
