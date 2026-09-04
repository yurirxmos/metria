# DMG Background Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a branded DMG installer window (approved mockup v3) by adding a static background PNG and a Finder layout block to the packaging script.

**Architecture:** Two independent pieces: (1) a committed 1320x880 background PNG generated once from repo assets with PIL; (2) a `layout_dmg_window` bash function in `package-macos.sh`, called on both DMG build paths, that positions icons and sets the background via AppleScript with silent fallback to the current bare DMG.

**Tech Stack:** bash, osascript (Finder), hdiutil (existing), Python PIL (one-time asset generation on the dev machine only — never a build dependency).

---

### Task 1: Generate the background PNG

**Files:**
- Create: `Assets/dmg-background@2x.png` (1320x880)
- Read: `Assets/metria-mascot.png`, `Assets/metria-logo.png`, `Assets/claude-logo.png`, `Assets/codex-logo.png`, `Assets/opencode-logo.png`, `Assets/cursor-logo.png`, plus `Assets/antigravity-logo.png` from branch `chore/antigravity-plan` via `git show chore/antigravity-plan:Assets/antigravity-logo.png` (DMG ships all five provider marks; do NOT copy the file into this branch outside /tmp)

- [ ] **Step 1: Write the generator script to /tmp (never committed)**

```python
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import subprocess

W, H = 1320, 880
# Base diagonal gradient #0a0a0c -> #1e1e2a
base = Image.new('RGB', (W, H))
px = base.load()
for y in range(H):
    for x in range(W):
        t = (x + y) / (W + H)
        px[x, y] = tuple(int(a + (b - a) * t) for a, b in zip((10, 10, 12), (30, 30, 42)))
img = base.convert('RGBA')
# Radial blue glow centered top
glow = Image.new('RGBA', (W, H), (0, 0, 0, 0))
gd = ImageDraw.Draw(glow)
gd.ellipse([-220, -320, 860, 240], fill=(48, 135, 251, 70))
img = Image.alpha_composite(img, glow.filter(ImageFilter.GaussianBlur(60)))
d = ImageDraw.Draw(img)

def font(size, bold=False):
    cands = ['/System/Library/Fonts/Helvetica.ttc', '/System/Library/Fonts/Supplemental/Arial.ttf']
    for i, p in enumerate(cands):
        for idx in ([1, 0] if bold else [0]):
            try:
                return ImageFont.truetype(p, size, index=idx)
            except Exception:
                continue
    return ImageFont.load_default()

def centered(y, text, fnt, fill):
    bb = d.textbbox((0, 0), text, font=fnt)
    d.text(((W - (bb[2] - bb[0])) / 2, y), text, font=fnt, fill=fill)

mascot = Image.open('Assets/metria-mascot.png').convert('RGBA').resize((240, 240), Image.LANCZOS)
img.alpha_composite(mascot, ((W - 240) // 2, 56))
centered(312, 'Metria', font(56, bold=True), (255, 255, 255))
centered(380, 'monitor your usage without leaving your flow', font(27), (167, 167, 179))
# WORKS WITH strip
strip = ['Assets/claude-logo.png', 'Assets/codex-logo.png', 'Assets/opencode-logo.png', 'Assets/cursor-logo.png', '/tmp/ag_logo.png']
minis = [Image.open(s).convert('RGBA').resize((44, 44), Image.LANCZOS) for s in strip]
label, gap = 'WORKS WITH', 20
lf = font(22)
lb = d.textbbox((0, 0), label, font=lf)
total = (lb[2] - lb[0]) + gap + len(minis) * 44 + (len(minis) - 1) * 12
x = (W - total) // 2
d.text((x, 448), label, font=lf, fill=(125, 125, 137))
x += (lb[2] - lb[0]) + gap
for m in minis:
    img.alpha_composite(m, (x, 430))
    x += 44 + 12
# Divider
for x in range(240, 1080):
    a = int(41 * (1 - abs(x - 660) / 420))
    d.line([(x, 520), (x, 521)], fill=(255, 255, 255, max(a, 0)))
# Arrow between icon slots (slots at x=340 and x=980 in PNG coords, y=560)
ax, ay = 660, 600
d.line([(ax - 44, ay), (ax + 30, ay)], fill=(142, 142, 153), width=6)
d.polygon([(ax + 30, ay - 18), (ax + 30, ay + 18), (ax + 62, ay)], fill=(142, 142, 153))
# Slot microcopy (centered under each icon slot, NOT window-centered)
def slot_caption(cx, y, text):
    f = font(24, bold=True)
    bb = d.textbbox((0, 0), text, font=f)
    d.text((cx - (bb[2] - bb[0]) / 2, y), text, font=f, fill=(10, 132, 255))
slot_caption(340, 770, '1    Drag the app')
slot_caption(980, 770, '2    Drop it here')
img.save('Assets/dmg-background@2x.png')
print('saved')
```

Before running: `git show chore/antigravity-plan:Assets/antigravity-logo.png > /tmp/ag_logo.png`.

- [ ] **Step 2: Run it and inspect**

Run: `python3 /tmp/mk_dmg_bg.py` from the repo root.
Expected: prints `saved`, file `Assets/dmg-background@2x.png` is 1320x880.

- [ ] **Step 3: Visually verify the PNG**

Open `Assets/dmg-background@2x.png` in Preview. Expected: dark gradient, blue glow top-center, mascot, "Metria", tagline, WORKS WITH + five marks, divider, arrow centered at x=660, blue "1    Drag the app" caption. If the bold/regular faces look wrong (Helvetica.ttc index varies by macOS), adjust the `font()` index picks and re-run — the screenshot check is the test.

- [ ] **Step 4: Commit the asset**

```bash
git add Assets/dmg-background@2x.png
git commit -m "Add DMG installer background art"
```

### Task 2: Layout function in package-macos.sh

**Files:**
- Modify: `apps/macos-native/scripts/package-macos.sh` (add function + call it in both DMG staging paths: the plain build block and the notary-rebuild block)

- [ ] **Step 1: Add the function after the codesign block (after line 67)**

```bash
# Styles the DMG installer window: background art, fixed icon positions and
# window size. Best-effort by design — AppleScript Finder control can fail on
# headless runners, and a bare DMG is always preferable to a failed release.
layout_dmg_window() {
    local dmg_root="$1"
    mkdir -p "$dmg_root/.background"
    cp "$ROOT_DIR/Assets/dmg-background@2x.png" "$dmg_root/.background/background.png"
    SetFile -a V "$dmg_root/.background" 2>/dev/null || true
    osascript <<EOF >/dev/null 2>&1 || return 0
tell application "Finder"
    open POSIX file "$dmg_root"
    set dmgWindow to Finder window 1
    set current view of dmgWindow to icon view
    set toolbar visible of dmgWindow to false
    set statusbar visible of dmgWindow to false
    set bounds of dmgWindow to {100, 100, 760, 540}
    set iconViewOpts to icon view options of dmgWindow
    set arrangement of iconViewOpts to not arranged
    set icon size of iconViewOpts to 96
    set background picture of iconViewOpts to POSIX file "$dmg_root/.background/background.png"
    set position of item "Metria.app" of dmgWindow to {170, 300}
    set position of item "Applications" of dmgWindow to {490, 300}
    set position of item ".background" of dmgWindow to {1000, 1000}
    close dmgWindow
    open POSIX file "$dmg_root"
    close Finder window 1
end tell
EOF
    return 0
}
```

Notes the engineer must preserve: `|| return 0` and `|| true` are the silent-fallback contract from the spec — a styling failure must never fail the build. `SetFile` may be absent on newer Xcode-only installs, hence `|| true`.

- [ ] **Step 2: Call it in both DMG paths**

In the plain block, after the `ln -s /Applications` line, insert:
```bash
layout_dmg_window "$BUILD_DIR/dmg-root"
```
Do the same in the notary-rebuild block after its identical `ln -s` line. Both call sites MUST be added — grep to confirm exactly two.

- [ ] **Step 3: Syntax-check and commit**

Run: `bash -n apps/macos-native/scripts/package-macos.sh && grep -c 'layout_dmg_window "$BUILD_DIR/dmg-root"' apps/macos-native/scripts/package-macos.sh`
Expected: no output from `bash -n`, count prints `2`.

```bash
git add apps/macos-native/scripts/package-macos.sh
git commit -m "Style DMG window with background art and fixed layout"
```

### Task 3: Local DMG verification

**Files:** none (build artifacts under `dist/`, gitignored — verify with `git status`)

- [ ] **Step 1: Build the DMG locally**

Run: `VERSION=dev ./apps/macos-native/scripts/package-macos.sh`
Expected: tail prints `Created dist/Metria-dev-<arch>.zip` and `Created dist/Metria-dev-<arch>.dmg`. Notarization is skipped automatically (no `NOTARY_PROFILE`), ad-hoc sign path is taken.

- [ ] **Step 2: Open and screenshot**

Run: `open dist/Metria-dev-*.dmg`, screenshot the Finder window.
Expected: 660x440 window, dark branded background, mascot/title/tagline, five provider marks, arrow, Metria.app left + Applications right at equal 96px sizes, captions legible, no `.background` folder visible. Compare against approved mockup v3.

- [ ] **Step 3: Drag-install smoke test**

Drag `Metria.app` from the mounted DMG into a temp dir (`mkdir -p /tmp/dmgtest`, drop there — NEVER into real /Applications). Then `codesign --verify --deep --strict /tmp/dmgtest/Metria.app`.
Expected: verify passes (ad-hoc signature survives the DMG round-trip).

- [ ] **Step 4: Detach and clean**

Run: `hdiutil detach /Volumes/Metria; rm -rf /tmp/dmgtest dist/Metria-dev-*` then `git status --short`.
Expected: detached, temp files gone, working tree shows no `.DS_Store` or staging files (only intended branch commits).

### Task 4: Record verification in the spec

**Files:**
- Modify: `docs/superpowers/specs/2026-09-04-dmg-background-design.md` (append a `## Verification log` section with date, DMG filename, screenshot confirmation bullets, smoke-test result)

- [ ] **Step 1: Append the log and commit**

```bash
git add docs/superpowers/specs/2026-09-04-dmg-background-design.md
git commit -m "Record DMG background verification"
```
