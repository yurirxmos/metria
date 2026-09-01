# Plan 003: Add a Cursor usage provider to the Electron app

> **Executor instructions**: Follow this plan in order. It reuses the credential
> and endpoint findings recorded in Plan 002's decision log; do not re-derive
> them here, and do not start before Plan 002's Gates A and B have passed.
> Windows and Linux behavior must be exercised on those operating systems —
> `apps/electron/README.md` and Plan 001 already require this, and Cursor's
> paths differ per platform.
>
> **Drift check (run first)**:
> `git diff --stat a16b53b..HEAD -- apps/electron plans`
> If any listed path has changed, compare the current behavior described below
> with the live code and update this plan before implementation.

## Status

- **Priority**: P2
- **Effort**: M (one provider, one SQLite decision, per-platform paths)
- **Risk**: MEDIUM (same undocumented endpoint as Plan 002, plus a new runtime
  dependency decision and the WSL boundary)
- **Depends on**: Plan 002 phase 0 (credential location, endpoint, response
  shape). Implementation can otherwise proceed in parallel.
- **Category**: feature
- **Planned at**: commit `a16b53b`, 2026-09-01

## Decision

Add **Cursor** as a fourth `ProviderKind` in the Electron app, reading Cursor's
VS Code global-storage SQLite database on the host and calling the same usage
endpoint Plan 002 selects.

Ship Cursor as **host-only** in its first release: `hasHostCredentials()` is
real, WSL presence is always `false`, and `fetchWsl` throws a clear message.
Cursor is a GUI application; a Cursor install inside a WSL distribution is rare
enough that it does not justify piping a binary database through
`wsl.exe` before the host path has shipped. Phase 5 covers WSL if it is ever
wanted.

Read the database with **`sql.js`** (SQLite compiled to WebAssembly), not with a
native module. `better-sqlite3` would drag `electron-rebuild` and per-platform
native artifacts into a build that currently has zero native dependencies
(`apps/electron/package.json:29-34`), and `node:sqlite` is not dependable on
Electron 37's Node 22 runtime without a flag. `sql.js` reads a `Buffer` the main
process already has and stays inside the existing pure-JS packaging.

## Why this matters

The Electron app exists to bring Metria to Windows and Linux, which is where a
large part of Cursor's user base is. The provider surface is small and uniform —
`Provider` is five members (`apps/electron/src/main/providers.ts:11-18`) — so the
cost here is not the provider; it is the SQLite dependency decision, the
per-platform paths, and the WSL type obligations described below.

## Verified current state

1. `ProviderKind` is a string union declared once and enumerated in three more
   places in the same file: `ALL_PROVIDER_KINDS`, the `isProviderKind` guard, and
   `PROVIDER_LOGOS` (`apps/electron/src/shared/types.ts:1`, `:92-102`). A fourth
   place, `providerShortLabel` (`:104-106`), special-cases long names.
2. `Provider` implementations must supply `hasHostCredentials`, `fetchHost`, and
   `fetchWsl`; `ProviderService.fetch` catches throws per provider and converts
   them into an available-but-errored card
   (`apps/electron/src/main/providers.ts:33-45`).
3. `POPULATION_BY_KIND` is a **total** `Record<ProviderKind, keyof
   WslProviderPresence>` (`apps/electron/src/main/providers.ts:74`), so adding a
   kind will not typecheck until `WslProviderPresence`
   (`apps/electron/src/main/wsl.ts:4-8`) gains a matching field and the probe
   script (`apps/electron/src/main/wsl.ts:23-30`) is updated.
4. Paths live in one place, honoring `APPDATA`, `XDG_DATA_HOME`, and `CODEX_HOME`
   (`apps/electron/src/main/provider-paths.ts:5-14`), and are unit-tested per
   platform with a fake environment
   (`apps/electron/src/test/provider-paths.test.ts:6-15`).
5. Credentials are read as UTF-8 strings everywhere today — both
   `readFileSync(..., "utf8")` and `WslShell.readFile`
   (`apps/electron/src/main/wsl.ts:20`). A SQLite file is binary and does not fit
   that contract.
6. `ACCENT` in the widget is another total `Record<ProviderKind, string>`
   (`apps/electron/src/renderer/widget.tsx:10-14`), and logos are copied from the
   repository-root `Assets/` by an explicit file list
   (`apps/electron/scripts/copy-renderer-assets.cjs:6-10`).
7. Tests are `node:test` over the compiled output, run by `npm run check`
   (`apps/electron/package.json:12-16`).

## Phase 1 — Paths and platform coverage

Extend `ProviderPaths` with `cursorState` in
`apps/electron/src/main/provider-paths.ts:5-14`:

| Platform | Path |
|---|---|
| Windows | `%APPDATA%\Cursor\User\globalStorage\state.vscdb` |
| Linux | `$XDG_CONFIG_HOME` or `~/.config` + `/Cursor/User/globalStorage/state.vscdb` |
| macOS | `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` |

Note that Cursor's root follows the **config** root on Linux (`XDG_CONFIG_HOME`),
not the data root the OpenCode path uses; do not reuse `dataRoot`.

Extend `apps/electron/src/test/provider-paths.test.ts` with one assertion per
platform, including the `XDG_CONFIG_HOME` override, following the existing style.

## Phase 2 — Reading the state database

Add `sql.js` to `dependencies` and a `readCursorAuth(path, key)` helper in a new
`apps/electron/src/main/cursor-state.ts`:

- copy the database (and any `-wal` / `-shm` siblings) to `app.getPath("temp")`,
  read the copy, delete it — Cursor holds the live file open in WAL mode;
- `SELECT value FROM ItemTable WHERE key = ?`, decode the value as UTF-8;
- return `undefined` for every failure mode (missing file, missing table, missing
  key, malformed value) so the provider can throw one clear message instead of
  leaking SQLite errors into the card;
- keep the parsing entry point exported and pure so it can be unit-tested against
  a fixture database, the way `parseCodexAuth` and `parseOpenCodeGoWindows` are
  (`apps/electron/src/main/providers.ts:196-231`).

Verify the WASM asset is present in the packaged app: `sql.js` loads
`sql-wasm.wasm` at runtime, so it must be unpacked from the asar or bundled
alongside the main process output. Check `apps/electron/electron-builder.yml`
and add `asarUnpack` if needed.

- **Gate**: `npm run check` passes, and a packaged build (`npm run package`) can
  still read a fixture database. A `sql.js` that only works in `npm run dev` is a
  failed gate, not a detail to fix later.

## Phase 3 — The provider

Add `CursorProvider` to `apps/electron/src/main/providers.ts`, alongside the
existing three, and register it in the `ProviderService` constructor
(`apps/electron/src/main/providers.ts:28`):

- `hint`: "Sign in to Cursor to make usage available."
- `hasHostCredentials()`: the state database exists **and** carries the auth key.
- `fetchHost()`: read the credential, call the Plan 002 endpoint through the
  existing `requestWithRetry` (`apps/electron/src/main/providers.ts:180-201`) so
  timeout, 429 and `Retry-After` behavior stay identical to the other providers,
  then map the payload with an exported pure `parseCursorWindows(data)`.
- `fetchWsl()`: throw `new Error("Cursor usage is read from the Windows or Linux
  host installation.")` until Phase 5.
- Window titles come from the response, as in Plan 002 — the first window is what
  the widget ring and tray show (`apps/electron/src/renderer/widget.tsx:16`).

Add unit tests in `apps/electron/src/test/providers.test.ts` for
`parseCursorWindows`: a request-quota payload, a usage-based payload, and a
malformed payload.

## Phase 4 — Types, WSL typing obligation, and presentation

- `apps/electron/src/shared/types.ts`: add `"Cursor"` to the union,
  `ALL_PROVIDER_KINDS`, `isProviderKind`, and `PROVIDER_LOGOS`
  (`cursor-logo.png`). `providerShortLabel` needs no change — "Cursor" is short.
- `apps/electron/src/main/wsl.ts`: add `cursor: boolean` to
  `WslProviderPresence`, return `false` for it from every construction site
  (including the non-Windows early return at `:47`), and leave the probe script
  untouched in this phase. Then map `Cursor: "cursor"` in `POPULATION_BY_KIND`
  (`apps/electron/src/main/providers.ts:74`). This keeps `needsChoice`
  (`apps/electron/src/main/providers.ts:56`) false for Cursor, so the source
  picker never offers a WSL option that cannot work.
- `apps/electron/src/renderer/widget.tsx:10-14`: add the Cursor accent color.
- `apps/electron/scripts/copy-renderer-assets.cjs:7`: add `cursor-logo.png` to
  the copied list. The asset itself is added by Plan 002 Phase 3; if this plan
  ships first, add `Assets/cursor-logo.png` here instead.
- Update `apps/electron/README.md` and the README "Providers → Electron version"
  list, stating plainly that Cursor is host-only and that its usage comes from an
  endpoint Cursor does not publish.

## Phase 5 — WSL support (deferred, only if asked for)

Do not start this without a user actually running Cursor inside WSL.

- `WslShell` would need a binary read (`readFileBase64`) because `readFile`
  returns UTF-8 (`apps/electron/src/main/wsl.ts:20`); a SQLite file cannot
  survive that path.
- The probe script (`apps/electron/src/main/wsl.ts:23-30`) would gain a
  `cursor:"$HOME/.config/Cursor/User/globalStorage/state.vscdb"` entry.
- `fetchWsl` would base64 the copy, decode it into a `Buffer`, and reuse the
  Phase 2 reader.

## Risks

1. **Undocumented endpoint** — same as Plan 002, same mitigation: one decode
   site, per-provider error isolation (`apps/electron/src/main/providers.ts:41-44`).
2. **A new runtime dependency in a dependency-light app.** `sql.js` is ~1.5 MB of
   WASM. Mitigation: load it lazily inside `cursor-state.ts` so it costs nothing
   until a user actually has Cursor installed.
3. **Packaging.** The WASM asset is the most likely thing to work in development
   and fail in an installer. Mitigation: the Phase 2 gate tests a packaged build,
   not a dev run.
4. **Total-record types.** `POPULATION_BY_KIND` and `ACCENT` will fail to compile
   until updated; that is the intended safety net, not an obstacle.
5. **Platform drift.** Cursor's Linux root is config-based, not data-based;
   getting this wrong silently reports "not installed". Mitigation: Phase 1 unit
   tests per platform.

## Alternatives considered and rejected

- **`better-sqlite3`**: rejected. A native module means `electron-rebuild`,
  per-platform prebuilds, and CI changes on a project that currently ships no
  native dependencies.
- **`node:sqlite`**: rejected for now. It needs a flag on Electron 37's Node 22
  runtime; revisit when the app moves to an Electron on Node 24.
- **Shelling out to a system `sqlite3` binary**: rejected. Not present by default
  on Windows, and it would add a spawn to every refresh.
- **Sharing the reader with the macOS app**: rejected, as Plan 001 already
  concluded — only versioned data contracts and fixtures cross the Swift/TS
  boundary. The **fixture database** from Plan 002 Phase 0 should be shared;
  the code should not.
- **Shipping WSL support in the first release**: rejected as unjustified work,
  per the Decision above.

## Verification

```sh
cd apps/electron
npm run check       # typecheck + build + node:test
npm run package     # must be run and smoke-tested on Windows and on Linux
```

Manual checks, on each of Windows and Linux with Cursor signed in:

1. Cursor appears in the widget, tray, and dashboard with usage inside one
   refresh interval.
2. Sign out of Cursor: the Cursor card reports its setup hint and the other three
   providers keep updating.
3. On Windows with at least one WSL distribution present, the provider source
   picker offers no WSL option for Cursor.
4. With Cursor not installed at all, nothing regresses and no SQLite/WASM code is
   loaded.
