# DMG installer window — design spec

Date: 2026-09-04. Branch: `chore/dmg-background`. Status: approved by contributor (mockup v3 via visual companion).

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
- Top center: mascot (`Assets/metria-mascot.png`, 84pt), title "Metria"
  semibold, tagline "Monitor your usage without leaving your flow" secondary.
- Bottom row: `Metria.app` icon left ({170,332}), arrow baked into the
  background center (icon mid-height), `Applications` symlink right
  ({490,332}). Both icons render at the SAME visual size (72px) — explicit
  contributor requirement. Finder `position` is the icon CENTER: with 72px
  icons the glyphs span 296-368, Finder labels land ~372-392, baked captions
  at ~404 — all inside the cards. (An earlier revision placed icons at y=290
  assuming top-left anchoring; they overflowed the card tops and were fixed
  here.)
- Details (all baked into the PNG): radial blue glow behind the mascot, a
  "WORKS WITH" label ABOVE the five provider mini-logos, a subtle divider
  with a 46px breathing gap before the cards, and numbered microcopy under
  each target ("1 Drag the app" / "2 Drop it here").
- Finder draws icon labels ("Metria", "Applications") in black with no API to
  force light text, so each icon sits on a baked WHITE card (176x152,
  y 276-428) — black labels stay readable on the cards. Verified live.

## Layout script behavior

- After staging `dmg-root` (app + symlink + `.background/background.png`),
  run `osascript`: set window bounds, `icon size 72`, `background picture`,
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

## Verification log (2026-09-04, branch `chore/dmg-background`)

- Built `dist/Metria-dev-arm64.dmg` via `VERSION=dev bash
  apps/macos-native/scripts/package-macos.sh` (ad-hoc sign path, no notary).
- Mounted DMG shows the full branded window: mascot, "Metria", "Monitor your
  usage without leaving your flow", WORKS WITH above the five marks, divider,
  arrow, Metria.app left + Applications right at equal 96px with both slot
  captions legible, dark path + status bars, no `.background` visible.
- Findings applied during verification: background art must be 660x440
  (Finder maps pixels 1:1 to points); window is 660x520 outer so captions fit
  without a scrollbar; status bar stays VISIBLE (hiding it leaves a white
  filler strip on current macOS); UDRW mount -> layout -> detach flow is
  required because Finder only flushes `.DS_Store` on detach; unique staging
  mountpoint avoids colliding with user-mounted older Metria DMGs, with
  fallback to the bare DMG on any failure.
- Smoke test: copied Metria.app from the mounted DMG to /tmp (never
  /Applications); `codesign --verify --deep --strict` passes.
- Cleaned: detached volume, removed dist artifacts and temp files; no
  `.DS_Store` or staging files in the working tree.
