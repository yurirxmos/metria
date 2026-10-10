#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/dist}"
XCODE_BUILD_DIR="${XCODE_BUILD_DIR:-$ROOT_DIR/.build/xcode-package}"
VERSION="${VERSION:-$(git -C "$ROOT_DIR" describe --tags --always 2>/dev/null || true)}"
VERSION="${VERSION:-dev}"
RELEASE_VERSION="${VERSION#macos-}"
RELEASE_VERSION="${RELEASE_VERSION#v}"
if [[ "$RELEASE_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    MARKETING_VERSION="$RELEASE_VERSION"
else
    MARKETING_VERSION="0.0.0"
fi
BUILD_NUMBER="$(git -C "$ROOT_DIR" rev-list --count HEAD 2>/dev/null || printf '1')"
ARCH="$(uname -m)"
APP_NAME="Metria"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
ZIP_PATH="$BUILD_DIR/$APP_NAME-$VERSION-$ARCH.zip"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION-$ARCH.dmg"
XCODE_APP_BUNDLE="$XCODE_BUILD_DIR/Build/Products/Release/$APP_NAME.app"

cd "$ROOT_DIR"
xcodebuild_args=(
    -project "$ROOT_DIR/apps/macos-native/Metria.xcodeproj"
    -scheme "$APP_NAME"
    -configuration Release
    -destination "generic/platform=macOS"
    -derivedDataPath "$XCODE_BUILD_DIR"
    ARCHS="$ARCH"
    ONLY_ACTIVE_ARCH=YES
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    MARKETING_VERSION="$MARKETING_VERSION"
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)

xcodebuild "${xcodebuild_args[@]}" build
test -d "$XCODE_APP_BUNDLE"

rm -rf "$APP_BUNDLE" "$ZIP_PATH" "$DMG_PATH" "$BUILD_DIR/dmg-root"
mkdir -p "$BUILD_DIR"
ditto --norsrc "$XCODE_APP_BUNDLE" "$APP_BUNDLE"
rm -f "$APP_BUNDLE"/._* "$APP_BUNDLE/Contents"/._* "$APP_BUNDLE/Contents/MacOS"/._* "$APP_BUNDLE/Contents/Resources"/._*

# Xcode's GENERATE_INFOPLIST_FILE only recognizes a fixed set of well-known
# INFOPLIST_KEY_* names, so it silently drops Sparkle's custom keys instead of
# erroring. Write them into the built Info.plist directly instead.
if [[ -n "${SPARKLE_FEED_URL:-}" && -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
    PLIST="$APP_BUNDLE/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_ED_KEY" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :SUScheduledCheckInterval integer 3600" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :SUAutomaticallyUpdate bool true" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :SURequireSignedFeed bool true" "$PLIST"
fi

ENTITLEMENTS="$ROOT_DIR/apps/macos-native/Metria.entitlements"
DEVELOPER_ID_SIGNED=0
if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
    DEVELOPER_ID_SIGNED=1
    sign() { codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$@"; }
    # Notarization rejects `--deep`-signed bundles whose nested helpers lack
    # hardened runtime or a secure timestamp, so sign inside-out the way
    # Sparkle's documentation prescribes for non-sandboxed apps.
    SPARKLE="$APP_BUNDLE/Contents/Frameworks/Sparkle.framework/Versions/B"
    if [[ -d "$SPARKLE" ]]; then
        sign "$SPARKLE/XPCServices/Installer.xpc"
        sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
        sign "$SPARKLE/Autoupdate"
        sign "$SPARKLE/Updater.app"
    fi
    for framework in "$APP_BUNDLE"/Contents/Frameworks/*.framework; do
        [[ -e "$framework" ]] || continue
        sign "$framework"
    done
    sign --entitlements "$ENTITLEMENTS" "$APP_BUNDLE"
else
    printf '%s\n' "Warning: no Developer ID configured; ad hoc signing the release archive so Gatekeeper treats it as an unidentified-developer app instead of reporting it as damaged."
    codesign --deep --force --sign - "$APP_BUNDLE"
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
if [[ "$DEVELOPER_ID_SIGNED" == 1 ]]; then
    codesign -d --entitlements - "$APP_BUNDLE" 2>/dev/null | grep -q "com.apple.security.automation.apple-events"
fi

# Styles the DMG installer window via Finder's `tell disk` / container window
# API (create-dmg style). Opening a custom -mountpoint with Finder window 1
# styles icons/background but often fails to persist WindowBounds on CI
# (v0.1.36/v0.1.38 shipped 920x464). A unique staging volume name lets
# `tell disk` work without colliding with a user-mounted Metria.dmg.
layout_dmg_window() {
    local volume="$1"
    local disk_name="$2"
    mkdir -p "$volume/.background"
    cp "$ROOT_DIR/Assets/dmg-background.png" "$volume/.background/background.png"
    SetFile -a V "$volume/.background" 2>/dev/null || true
    osascript <<EOF >/dev/null 2>&1 || return 0
tell application "Finder"
    tell disk "$disk_name"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        try
            set pathbar visible of container window to false
        end try
        -- Status bar (item count + icon-size slider) must stay off for the
        -- branded installer look. Outer height is 500pt so 470pt art fills the
        -- content area with title-bar chrome only (no path/status bars).
        set statusbar visible of container window to false
        set the bounds of container window to {100, 100, 760, 600}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 72
        set background picture of theViewOptions to file ".background:background.png"
        set position of item "Metria.app" of container window to {170, 332}
        set position of item "Applications" of container window to {490, 332}
        try
            set position of item ".background" of container window to {1000, 1000}
        end try
        update without registering applications
        delay 2
        try
            set pathbar visible of container window to false
        end try
        set the bounds of container window to {100, 100, 760, 600}
        delay 1
        close
        delay 1
    end tell
end tell
EOF
    return 0
}

# Safety net: if AppleScript still left a wrong WindowBounds (seen on GHA as
# 920x464), patch the bwsp string in-place with an equal-length replacement so
# the binary plist length prefix stays valid.
force_dmg_window_bounds() {
    local volume="$1"
    local ds_store="$volume/.DS_Store"
    local target_w=660 target_h=500
    sync 2>/dev/null || true
    [[ -f "$ds_store" ]] || return 1

    TARGET_W="$target_w" TARGET_H="$target_h" DS_STORE="$ds_store" python3 - <<'PY'
import os, re
from pathlib import Path

ds = Path(os.environ["DS_STORE"])
tw, th = int(os.environ["TARGET_W"]), int(os.environ["TARGET_H"])
data = bytearray(ds.read_bytes())
pat = re.compile(rb"\{\{(\d+), (\d+)\}, \{(\d+), (\d+)\}\}")
matches = list(pat.finditer(data))
before = [m.group(0).decode() for m in matches]

if not matches:
    print("DMG WindowBounds: missing from .DS_Store", flush=True)
    raise SystemExit(1)

already_ok = all(int(m.group(3)) == tw and int(m.group(4)) == th for m in matches)
if already_ok:
    print("DMG WindowBounds: already %dx%d" % (tw, th), flush=True)
    raise SystemExit(0)

replacement = None
old = matches[0].group(0)
for x in range(0, 1000):
    for y in range(0, 1000):
        cand = ("{{%d, %d}, {%d, %d}}" % (x, y, tw, th)).encode()
        if len(cand) == len(old):
            replacement = cand
            break
    if replacement is not None:
        break

if replacement is None:
    raise SystemExit(1)

for m in matches:
    if len(m.group(0)) != len(replacement):
        raise SystemExit(1)
    data[m.start():m.end()] = replacement

ds.write_bytes(data)
after = [m.group(0).decode() for m in pat.finditer(data)]
ok = all(int(m.group(3)) == tw and int(m.group(4)) == th for m in pat.finditer(data))
print("DMG WindowBounds: %s -> %s" % (before[0], after[0]), flush=True)
raise SystemExit(0 if ok else 1)
PY
}

# Builds a styled read-only DMG from a staging dir via a writable scratch
# image (mount -> tell disk layout -> bounds patch -> rename -> detach -> UDZO).
build_styled_dmg() {
    local dmg_root="$1" dmg_path="$2" volname="$3"
    local scratch="$BUILD_DIR/.dmg-scratch.dmg"
    local staging_name="${volname}-staging-$$"
    rm -f "$scratch"
    local size_mb
    size_mb=$(du -sm "$dmg_root" | cut -f1)
    # Unique volume name (not just mountpoint): Finder's `tell disk` only sees
    # volumes mounted at /Volumes/<name>, and custom -mountpoint breaks it.
    hdiutil create -volname "$staging_name" -srcfolder "$dmg_root" -ov -format UDRW -size "$((size_mb + 20))m" "$scratch" >/dev/null || return 1
    local attach_out mountpoint
    attach_out="$(hdiutil attach "$scratch" -nobrowse)" || return 1
    mountpoint="$(printf '%s\n' "$attach_out" | awk 'END { print $NF }')"
    [[ -d "$mountpoint" ]] || return 1

    layout_dmg_window "$mountpoint" "$staging_name"
    if ! force_dmg_window_bounds "$mountpoint"; then
        printf '%s\n' "Warning: could not force DMG WindowBounds to 660x500." >&2
        hdiutil detach "$mountpoint" >/dev/null 2>&1 || hdiutil detach "$mountpoint" -force >/dev/null 2>&1 || true
        rm -f "$scratch"
        return 1
    fi

    # Final installer should show volume name "Metria", not the staging name.
    if ! diskutil rename "$mountpoint" "$volname" >/dev/null; then
        printf '%s\n' "Warning: could not rename staging DMG volume to $volname." >&2
        hdiutil detach "$mountpoint" >/dev/null 2>&1 || true
        rm -f "$scratch"
        return 1
    fi
    # Rename moves the mount path to /Volumes/<volname> (or " 1" if taken).
    if [[ ! -d "$mountpoint" ]]; then
        if [[ -d "/Volumes/$volname" ]]; then
            mountpoint="/Volumes/$volname"
        else
            mountpoint="$(ls -d /Volumes/"$volname"* 2>/dev/null | head -1 || true)"
        fi
    fi

    if ! hdiutil detach "$mountpoint" >/dev/null 2>&1; then
        sleep 2
        hdiutil detach "$mountpoint" >/dev/null 2>&1 || hdiutil detach "$mountpoint" -force >/dev/null 2>&1 || return 1
    fi
    hdiutil convert "$scratch" -format UDZO -o "$dmg_path" >/dev/null || return 1
    rm -f "$scratch"
}

ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

mkdir -p "$BUILD_DIR/dmg-root"
ditto --norsrc "$APP_BUNDLE" "$BUILD_DIR/dmg-root/$APP_NAME.app"
ln -s /Applications "$BUILD_DIR/dmg-root/Applications"
if ! build_styled_dmg "$BUILD_DIR/dmg-root" "$DMG_PATH" "$APP_NAME"; then
    printf '%s\n' "Warning: styled DMG failed; shipping a bare DMG instead." >&2
    rm -f "$BUILD_DIR/.dmg-scratch.dmg"
    hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD_DIR/dmg-root" -ov -format UDZO "$DMG_PATH" >/dev/null
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    if [[ "$DEVELOPER_ID_SIGNED" != 1 ]]; then
        printf '%s\n' "Error: NOTARY_PROFILE requires a Developer ID CODESIGN_IDENTITY." >&2
        exit 1
    fi
    # Notarize the app first so the Sparkle zip carries a stapled ticket, then
    # rebuild both archives from the stapled bundle.
    xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_BUNDLE"
    rm "$ZIP_PATH"
    ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"
    rm "$DMG_PATH"
    rm -rf "$BUILD_DIR/dmg-root"
    mkdir -p "$BUILD_DIR/dmg-root"
    ditto --norsrc "$APP_BUNDLE" "$BUILD_DIR/dmg-root/$APP_NAME.app"
    ln -s /Applications "$BUILD_DIR/dmg-root/Applications"
    if ! build_styled_dmg "$BUILD_DIR/dmg-root" "$DMG_PATH" "$APP_NAME"; then
        printf '%s\n' "Warning: styled DMG failed; shipping a bare DMG instead." >&2
        rm -f "$BUILD_DIR/.dmg-scratch.dmg"
        hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD_DIR/dmg-root" -ov -format UDZO "$DMG_PATH" >/dev/null
    fi

    # The disk image is what users download, so it needs its own signature and
    # stapled ticket for Gatekeeper to accept it offline.
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
    xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG_PATH"

    xcrun stapler validate "$APP_BUNDLE"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
elif [[ "$DEVELOPER_ID_SIGNED" == 1 ]]; then
    codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH"
fi

rm -rf "$BUILD_DIR/dmg-root"
printf 'Created %s\nCreated %s\n' "$ZIP_PATH" "$DMG_PATH"
