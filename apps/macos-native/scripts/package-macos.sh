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

if [[ -n "${CODESIGN_IDENTITY:-}" && "$CODESIGN_IDENTITY" != "-" ]]; then
    codesign --deep --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
else
    printf '%s\n' "Warning: no Developer ID configured; ad hoc signing the release archive so Gatekeeper treats it as an unidentified-developer app instead of reporting it as damaged."
    codesign --deep --force --sign - "$APP_BUNDLE"
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

# Styles the DMG installer window: background art, fixed icon positions and
# window size. Best-effort by design — AppleScript Finder control can fail on
# headless runners, and a bare DMG is always preferable to a failed release.
#
# Takes a MOUNTED volume path (not a plain directory): Finder flushes
# .DS_Store on detach, which plain staging dirs never trigger.
layout_dmg_window() {
    local volume="$1"
    mkdir -p "$volume/.background"
    cp "$ROOT_DIR/Assets/dmg-background.png" "$volume/.background/background.png"
    SetFile -a V "$volume/.background" 2>/dev/null || true
    osascript <<EOF >/dev/null 2>&1 || return 0
tell application "Finder"
    open POSIX file "$volume"
    set dmgWindow to Finder window 1
    set current view of dmgWindow to icon view
    set toolbar visible of dmgWindow to false
    -- Counter-intuitive but verified: hiding the status bar leaves a white
    -- filler strip on current macOS, while showing it renders fully dark.
    set statusbar visible of dmgWindow to true
    set bounds of dmgWindow to {100, 100, 760, 620}
    set iconViewOpts to icon view options of dmgWindow
    set arrangement of iconViewOpts to not arranged
    set icon size of iconViewOpts to 96
    set background picture of iconViewOpts to POSIX file "$volume/.background/background.png"
    set position of item "Metria.app" of dmgWindow to {170, 300}
    set position of item "Applications" of dmgWindow to {490, 300}
    set position of item ".background" of dmgWindow to {1000, 1000}
    delay 2
    close dmgWindow
end tell
EOF
    return 0
}

# Builds a styled read-only DMG from a staging dir via a writable scratch
# image (mount -> layout -> detach flushes .DS_Store -> convert to UDZO).
build_styled_dmg() {
    local dmg_root="$1" dmg_path="$2" volname="$3"
    local scratch="$BUILD_DIR/.dmg-scratch.dmg"
    rm -f "$scratch"
    local size_mb
    size_mb=$(du -sm "$dmg_root" | cut -f1)
    hdiutil create -volname "$volname" -srcfolder "$dmg_root" -ov -format UDRW -size "$((size_mb + 20))m" "$scratch" >/dev/null || return 1
    # Unique mountpoint: never collide with a user-mounted older Metria DMG
    # (same volume name), which would style — or fail to detach — the wrong disk.
    local mountpoint="/Volumes/${volname}-staging-$$"
    hdiutil attach "$scratch" -mountpoint "$mountpoint" -nobrowse >/dev/null || return 1
    layout_dmg_window "$mountpoint"
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
    hdiutil detach "/Volumes/${APP_NAME}-staging-$" >/dev/null 2>&1 || true
    rm -f "$BUILD_DIR/.dmg-scratch.dmg"
    hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD_DIR/dmg-root" -ov -format UDZO "$DMG_PATH" >/dev/null
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
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
    hdiutil detach "/Volumes/${APP_NAME}-staging-$" >/dev/null 2>&1 || true
    rm -f "$BUILD_DIR/.dmg-scratch.dmg"
    hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD_DIR/dmg-root" -ov -format UDZO "$DMG_PATH" >/dev/null
fi
fi

rm -rf "$BUILD_DIR/dmg-root"
printf 'Created %s\nCreated %s\n' "$ZIP_PATH" "$DMG_PATH"
