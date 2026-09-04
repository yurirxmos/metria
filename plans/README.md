# Implementation Plans

Planning-only documents. Each plan records the state of the code at the commit
it was written against and must be re-checked with its own drift check before
implementation.

Plan 001 is the migration assessment that led to the repository split and is
kept for its rejected alternatives. Plan 002 adds a single provider to the
native macOS app and begins with a research gate rather than committing to an
undocumented vendor endpoint sight unseen.

## Execution order & status

| Plan | Title | Priority | Effort | Depends on | Status |
|---|---|---|---|---|---|
| 001 | Add a maintainable Electron companion without replacing native macOS | P1 | L | — | Superseded by the repository split |
| 002 | Add a Cursor usage provider to the native macOS app | P2 | M | — | DONE |
| 003 | Add an Antigravity usage provider to the native macOS app | P2 | M | — | Implemented on `chore/antigravity-plan`, awaiting PR |

## Plans that moved with their app

The repository split sent two plans to the repositories that own the code they
describe:

- **003 — Add a Cursor usage provider to the Electron app**: now in
  [pedropsoares/metria-win-linux](https://github.com/pedropsoares/metria-win-linux).
- **004 — Add a native iOS companion with Home Screen and Lock Screen widgets**:
  now in [pedropsoares/metria-ios](https://github.com/pedropsoares/metria-ios),
  where its Phase 0 device gate is still open.

Plan 002's phase 0 was the confirmation step shared by both Cursor plans: the
credential location and the usage endpoint are documented in its Evidence
section, but they are not a published Cursor contract, so they must be
reconfirmed against the Cursor version at hand before either implementation is
changed.

Note: the number 003 below refers to the original pre-split plan that moved to
`metria-win-linux`. It is unrelated to the current plan 003 (Antigravity
provider) in the execution table above; the number was intentionally reused.

## Findings considered and rejected

- Separate repositories per desktop OS: originally rejected, later adopted. The
  Electron implementation moved to `metria-win-linux` and the iOS app to
  `metria-ios`, while native macOS and the companion PWA remain here.
- Replacing or rewriting the native Swift macOS app: rejected. It remains the
  production macOS application.
- A direct Swift cross-compile or SwiftUI reuse in Electron: rejected. The
  current executable is macOS-native and Electron cannot import SwiftUI/AppKit;
  only versioned data/protocol contracts and test fixtures may be shared.
- Replacing the companion PWA with the iOS app: rejected. The PWA is the only
  Android path and must keep parsing the same snapshot JSON; the iOS app ships
  alongside it and shares the transport contracts, not the code.
- A single cross-app Cursor implementation: rejected. The two Cursor plans share
  the fixture database and the recorded endpoint contract, not code.
- Deriving Cursor usage by counting local Cursor session files: rejected. That
  records requests made, not the account quota, so any percentage would be
  invented rather than measured.
- Making the iOS app fully standalone and retiring the Mac mirror: rejected.
  None of the four provider credentials the Mac reads (Claude Keychain OAuth,
  Cursor's session JWT, the OpenCode-managed Codex token, the OpenCode Go key)
  can be discovered by the phone on its own, and Cursor's own dashboard API key
  was confirmed not to authenticate its usage RPC even though the RPC accepted
  the key everywhere else — so the Mac mirror stays the only universal path.
