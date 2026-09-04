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
the existing provider contract exactly: discover a local credential, call the
vendor's usage endpoint, and map the answer onto `UsageWindow` values.
Antigravity differs from the four current providers in one way only, and that
difference drives most of this plan: its quota is per-model, not per-window.
The `fetchAvailableModels` endpoint answers with one `remainingFraction` plus
one `resetTime` per model, so Metria must derive its four windows by grouping —
Gemini models vs. other models, crossed with short-horizon vs. long-horizon
resets:

| Window | Rule |
|---|---|
| 5-hour Gemini | min `remainingFraction` across `gemini-*` models with a short-horizon reset |
| Weekly Gemini | min across `gemini-*` models with a long-horizon reset |
| 5-hour other models | min across non-Gemini models (Claude, GPT-OSS, …) with a short-horizon reset |
| Weekly other models | min across non-Gemini models with a long-horizon reset |

`percent = (1 - remainingFraction) * 100`. A model belongs to the short-horizon
group when its `resetTime` is within ~24 hours of now, and to the long-horizon
group otherwise. This horizon split is an assumption Phase 0 must confirm
against live data; the fallback is two windows by family only (see Phase 2).

Credentials live in plain JSON at `~/.gemini/oauth_creds.json`
(`access_token`, `refresh_token`, `expiry_date`) — the same shape the Gemini CLI
uses. No new storage reader is needed: `Data(contentsOf:)` plus `JSONDecoder`
is enough, exactly like `OpenCodeGoProvider` reads its auth file. Token refresh
is a standard Google OAuth2 refresh grant, mirroring `ClaudeProvider`'s refresh
flow; the refreshed token lives in memory only and is never written back to
Antigravity's files.

The project ID that `fetchAvailableModels` requires comes from
`POST .../v1internal:loadCodeAssist`, whose response carries
`cloudaicompanionProject` — the same discovery call third-party tools use
before every quota fetch. Both facts are corroborated by shipping third-party
tools; see "Evidence" below.

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

## Phase 0 — Confirm the mechanism on the target machine (short)

The mechanism is documented in the "Evidence" section and implemented by
shipping third-party tools. What remains is confirming it against the
Antigravity version at hand and — critically — confirming the reset-time
horizons cluster into the short/long split the four windows assume, because
none of it is a published contract.

1. Confirm the credential is present and readable (keys only, never print values):
   ```sh
   python3 -c "import json;print(sorted(json.load(open('$HOME/.gemini/oauth_creds.json')).keys()))"
   ```
   Expect `access_token`, `refresh_token`, `expiry_date` (plus `id_token`,
   `scope`, `token_type`).
2. Discover the project ID:
   ```sh
   ACC=$(python3 -c "import json;print(json.load(open('$HOME/.gemini/oauth_creds.json'))['access_token'])")
   curl -s -X POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist \
     -H "Authorization: Bearer $ACC" -H 'Content-Type: application/json' \
     -d '{"metadata":{"ideType":"ANTIGRAVITY"}}' | python3 -m json.tool | head -40
   ```
   Expect `cloudaicompanionProject` (string or `{id}`) and `planInfo.planType`.
   Unset `ACC` when done (`unset ACC`); never paste the token into logs or chat.
3. Confirm the quota shape and the horizon split:
   ```sh
   curl -s -X POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels \
     -H "Authorization: Bearer $ACC" -H 'Content-Type: application/json' \
     -H 'User-Agent: antigravity' -d '{"project":"<id-from-step-2>"}' \
     | python3 -c "import json,sys; [print(k, v.get('quotaInfo')) for k,v in json.load(sys.stdin).get('models',{}).items() if v.get('quotaInfo')]"
   ```
   Expect per-model `quotaInfo` with `remainingFraction` and `resetTime`, and
   expect the reset times to cluster into a short horizon (hours) and a long
   horizon (days) within each model family.
4. Record the Antigravity version and the response shape in the decision log.
5. **Gate**: steps 1–3 answer with the expected shapes AND the horizon split
   holds. If the token is expired, refresh it first via
   `POST https://oauth2.googleapis.com/token` with
   `grant_type=refresh_token` (proving Phase 2's refresh path); if the
   endpoint refuses the token or the horizons do not split, stop and record
   which one failed — do not guess a replacement. If the horizons do not
   split, fall back to the two-window variant documented in Phase 2.

## Phase 1 — Credential loading and refresh

Inside `AntigravityProvider.swift` (no separate store file — the credential is
one JSON file, unlike Cursor's SQLite database).

- Read `~/.gemini/oauth_creds.json` with `JSONDecoder` into
  `{accessToken, refreshToken, expiryDate}`. Every failure (missing file,
  undecodable content) maps to `ProviderError.unavailable`, so `isAvailable`
  is simply "the file exists and decodes".
- `isAvailable`: file exists. `setupHint`:
  "Sign in to Antigravity to make usage available."
- Before the request, compare `expiry_date` (milliseconds since epoch) against
  now; when expired, refresh first:
  ```
  POST https://oauth2.googleapis.com/token
  Content-Type: application/x-www-form-urlencoded
  body: grant_type=refresh_token&refresh_token=<refreshToken>
        &client_id=1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com
        &client_secret=<see note>
  ```
  **Note on the client secret**: the OAuth client ID and secret are the ones
  Google issued to the Antigravity app itself and are already published in the
  open-source tools in Evidence. Embedding a third party's OAuth client secret
  is a maintainer decision — flag it in the PR. If the maintainer rejects it,
  the fallback is read-only: use the fresh `apiKey` from the IDE's
  `state.vscdb` (`antigravityAuthStatus` key, confirmed readable) while the IDE
  runs, with no refresh, degrading to the setup hint when it expires.
- On HTTP 401 from any API call, refresh once and retry (same shape as
  `ClaudeProvider`'s 401 retry). Never write to `~/.gemini/` or to
  Antigravity's directories.
- `accountLabel`: the active email from `~/.gemini/google_accounts.json`
  (`active` key, confirmed present), falling back to the `id_token` email
  claim via the existing `KeychainReader.tokenEmail` helper. `planLabel`: the
  `planInfo.planType` from `loadCodeAssist` (e.g. Pro/Ultra), best-effort.
- Reuse the existing three-attempt / `Retry-After` / `ProviderError.http(status)`
  handling (`apps/macos-native/Sources/Metria/Providers/OpenCodeGoProvider.swift:44-64`).
- **Gate**: `swift build` passes; unavailable state (credential file moved away
  temporarily) yields the setup hint, not a crash.

## Phase 2 — The provider

New file `apps/macos-native/Sources/Metria/Providers/AntigravityProvider.swift`,
modeled on `OpenCodeGoProvider` + `ClaudeProvider`'s refresh.

- On each fetch: ensure a valid access token (Phase 1), then
  `POST https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist` with
  `{"metadata":{"ideType":"ANTIGRAVITY"}}` to resolve the project ID
  (`cloudaicompanionProject`, string or `{id}`), then
  `POST https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels`
  with `{"project": <id>}`, both with `Authorization: Bearer`,
  `Content-Type: application/json`, `User-Agent: antigravity`,
  `X-Goog-Api-Client: google-cloud-sdk vscode_cloudshelleditor/0.1`, and
  `Client-Metadata: {"ideType":"ANTIGRAVITY","platform":"MACOS","pluginType":"GEMINI"}`.
- Map the response into exactly four windows:
  - `Self.fiveHourGeminiTitle` (`"5-hour Gemini"`), `Self.weeklyGeminiTitle`
    (`"Weekly Gemini"`), `Self.fiveHourOthersTitle`
    (`"5-hour other models"`), `Self.weeklyOthersTitle`
    (`"Weekly other models"`) — all `String(localized:)`, all listed in
    `usageWindowTitles`.
  - Family split: model ID (or display name) contains `gemini` (case-insensitive)
    → Gemini group, else others.
  - Horizon split: `resetTime` within 24 hours of now → short group, else long
    group. Skip models without `quotaInfo` (internal `chat_`/`tab_`/`rev`
    models, image models — same exclusions the tools in Evidence apply).
  - Each window's percent is `(1 - min(remainingFraction in group)) * 100`;
    `resetDate` is the earliest `resetTime` in the group. A group with no
    models yields no window for that group rather than an invented zero —
    never render a percentage Metria had to invent.
  - **Fallback if the Phase 0 horizon gate fails**: two windows by family only
    (`"Gemini"`, `"Other models"`), each the min across all horizons. Implement
    only the variant Phase 0 confirms — do not build both speculatively.
- Register the instance in `ProviderRegistry.makeProviders()`.
- **Gate**: with the credential present, `fetch()` returns `.loaded` with the
  confirmed window count; with the credential absent, `.failed` with the setup
  hint, and the other four providers keep updating.

## Phase 3 — Kind, presentation, and assets

- Add `case antigravity = "Antigravity"` to `ProviderKind`
  (`apps/macos-native/Sources/MetriaCore/UsageStore.swift:84-91`).
- Handle the new case in all four switches in
  `ProviderKind+Presentation.swift`: `symbol` (a reasonable SF Symbol fallback,
  e.g. `sparkle` — but not `sparkles`, which Claude uses), `logoName`
  (`antigravity-logo`), `sidebarProgressGradient`, and `reconnectCommand`. For
  reconnect, use `open -a Antigravity` — it is a real shell command, which is
  what the reconnect path requires (same reasoning as Cursor's `open -a Cursor`).
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

1. **Undocumented endpoints.** Neither `loadCodeAssist` nor
   `fetchAvailableModels` is a public contract. Mitigation: one provider, two
   adjacent decode sites, failures isolated per provider by `UsageStore`; the
   card degrades to an error string rather than breaking the app.
2. **Third-party OAuth client secret.** The refresh grant needs the Antigravity
   app's own OAuth client ID/secret, which are public only because other
   open-source tools publish them. Mitigation: maintainer call in review; the
   read-only `state.vscdb` fallback in Phase 1 removes the need entirely at the
   cost of working only while the IDE keeps its token fresh.
3. **Derived windows.** The 5-hour/weekly split is inferred from reset-time
   horizons, not stated by the API. Mitigation: Phase 0 gate plus the two-window
   fallback; a group with no models produces no window, never a fabricated
   percentage.
4. **Credential location moves.** The path `~/.gemini/oauth_creds.json` is
   shared with the Gemini CLI today and could move. Mitigation: `isAvailable`
   checks the file, so the provider drops out quietly instead of failing
   loudly; the `state.vscdb` `antigravityAuthStatus` key is the documented
   second source.
5. **Reading another app's credential.** Mitigation: read-only open, no writes
   to `~/.gemini/` or Antigravity's directories ever; the token is sent only to
   Google's own hosts.
6. **Scope creep into an Antigravity sign-in flow.** Out of scope. Metria reads
   credentials that other apps created; it does not authenticate on their behalf.

## Alternatives considered and rejected

- **Local language-server API as the primary source**
  (`POST 127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/GetUserStatus`
  over Connect RPC): rejected as the default. It carries the same per-model
  quota payload but requires the IDE to be running plus port/CSRF discovery
  from process arguments on every refresh. Keep it as a fallback if the cloud
  path is ever blocked.
- **Decoding the cached `userStatus` proto from `state.vscdb`**
  (`antigravityUnifiedStateSync.userStatus`, base64'd protobuf): rejected. It
  needs a proto schema Metria does not have, and the JSON cloud response
  carries the same data.
- **One window per model**: rejected. Antigravity exposes a dozen-plus models;
   a card per model breaks the one-card-per-provider layout every surface
  assumes. Four grouped windows fit the existing card that already renders
  three for OpenCode Go.
- **Counting local Antigravity conversation files** (`~/.gemini/antigravity/`
  `conversations/`) the way `CodexProvider` falls back to session files:
  rejected as a quota source. Local transcripts record requests, not the
  account quota, so any percentage would be fabricated. (Watching a directory
  for *activity* in Phase 4 is fine; deriving *quota* from it is not.)
- **Per-account multi-profile support** (`google_accounts.json` `active`/`old`):
  rejected for v1. Metria reads the active account only, matching how every
  other provider reads a single signed-in identity.

## Verification

```sh
swift build                       # required repository verification (AGENTS.md)
```

Manual checks on a Mac with Antigravity signed in:

1. Antigravity appears in Settings → Providers, enabled, with usage inside one
   refresh interval.
2. Move `~/.gemini/oauth_creds.json` away temporarily: the card becomes
   unavailable with the setup hint, and the other four providers keep updating.
   Restore the file afterwards.
3. "Diagnose" reports the real state; "Reconnect" opens Antigravity.
4. The notch rail, menu bar labels, dashboard (all four windows on hover), and
   paired PWA all show the Antigravity logo and percentages.
5. Expired-token path: with an expired `access_token` in the credential file,
   the next refresh recovers without user action (verify once, then leave the
   file untouched).

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
