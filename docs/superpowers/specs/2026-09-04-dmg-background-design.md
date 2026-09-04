# DMG installer window — design spec

Date: 2026-09-04. Branch: `chore/dmg-background`. Status: approved by contributor.

## Goal

Replace the bare DMG installer window (app + Applications symlink, default
Finder chrome) with a branded drag-to-install window, without adding
dependencies or risking the release pipeline.

## Locked decisions

- Approach A: background PNG + Finder layout via AppleScript inside
  `apps/macos-native/scripts/package-macos.sh`. Rejected: `create-dmg` tool
  (new external dependency against repo minimalism) and checked-in `.DS_Store`
  (fragile, breaks silently).
- Background is a STATIC committed asset
  (`Assets/dmg-background@2x.png`, 1320x880). Nothing is rendered at build
  time: deterministic, reviewable in PR, zero build tooling.
- English-only baked text (installer imagery is single-language by
  convention; the app itself stays localized).
- AppleScript failure falls back silently to the current bare DMG. The release
  never breaks because of window dressing.

## UI composition (approved mockup B)

- Window 660x440pt; dark gradient `#0a0a0c` to `#1a1a22`.
- Top center: mascot (`Assets/metria-mascot.png`, ~120pt), title "Metria"
  semibold, tagline "monitor your usage without leaving your flow" secondary.
- Bottom row: `Metria.app` icon left (~160,220), arrow baked into the
  background center, `Applications` symlink right (~500,220). Icons at 128px.

## Layout script behavior

- After staging `dmg-root` (app + symlink + `.background/background.png`),
  run `osascript`: set window bounds, `icon size 128`, `background picture`,
  icon positions, `arrange by none`. Runs in both the plain and the
  notarization DMG rebuild paths in `package-macos.sh`.
- The `.background` folder must be hidden in the final window (set
  visibility via the same script).

## Files touched (expected)

- `Assets/dmg-background@2x.png` (new)
- `apps/macos-native/scripts/package-macos.sh` (layout block, both DMG paths)
- This spec (docs only)

## Verification

- Local `./package-macos.sh` (unsigned path, no notary profile), open the
  resulting DMG, screenshot the window: mascot, title, tagline, arrow, both
  icons at the specified positions, no `.background` visible.
- Drag-install smoke test from the mounted DMG into a temp dir (not into the
  real /Applications).
- `git status` clean of `.DS_Store` files outside the DMG (never commit Finder
  state from the staging dir).

## Out of scope

- Notarization/stapling flow changes. License/readme files in the DMG.
  Localized background variants. Lite-mode or retina-1x variants (2x PNG
  downscales cleanly).
