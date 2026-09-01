# Implementation Plans

Generated on 2026-08-31 at commit `f5bbbe2`. This assessment has been
superseded by the completed repository split described below.

## Execution order & status

| Plan | Title | Priority | Effort | Depends on | Status |
|---|---|---|---|---|---|
| 001 | Add a maintainable Electron companion without replacing native macOS | P1 | L | — | Superseded |

## Dependency notes

- The framework decision gate in phase 1 blocks all production-port work. Do
  not start platform UI, credential migration, or release automation until the
  proof of concept passes on all three operating systems.
- Plan 002 phase 0 is a confirmation step shared by both Cursor plans: the
  credential location and the usage endpoint are documented in Plan 002's
  Evidence section, but they are not a published Cursor contract, so they must
  be confirmed against the Cursor version at hand before code is written. Plan
  003 consumes those findings and must not re-derive them. Once confirmed, 002
  and 003 can be implemented in parallel; neither blocks the other.

## Findings considered and rejected

- Separate repositories per desktop OS: the Electron implementation was moved
  to the public `yurirxmos/metria-win-linux` repository, while native macOS and
  the companion PWA remain here.
- Replacing or rewriting the native Swift macOS app: rejected. It remains the
  production macOS application. Electron is a separately identified companion
  app that may be offered on macOS only after it coexists safely.
- A direct Swift cross-compile or SwiftUI reuse in Electron: rejected. The
  current executable is macOS-native and Electron cannot import SwiftUI/AppKit;
  only versioned data/protocol contracts and test fixtures may be shared.
- A single cross-app Cursor implementation: rejected for the same reason. The
  two Cursor plans share the fixture database and the recorded endpoint
  contract, not code.
- Deriving Cursor usage by counting local Cursor session files: rejected. That
  records requests made, not the account quota, so any percentage would be
  invented rather than measured.
