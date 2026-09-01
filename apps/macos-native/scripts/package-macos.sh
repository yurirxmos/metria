#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT_DIR/dist}"
XCODE_BUILD_DIR="${XCODE_BUILD_DIR:-$ROOT_DIR/.build/xcode-package}"
VERSION="${VERSION:-$(git -C "$ROOT_DIR" describe --tags --always 2>/dev/null || true)}"
VERSION="${VERSION:-dev}"
RELEASE_VERSION="${VERSION#v}"
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

if [[ -n "${SPARKLE_FEED_URL:-}" && -n "${SPARKLE_PUBLIC_ED_KEY:-}" ]]; then
    xcodebuild_args+=(
        INFOPLIST_KEY_SUFeedURL="$SPARKLE_FEED_URL"
        INFOPLIST_KEY_SUPublicEDKey="$SPARKLE_PUBLIC_ED_KEY"
        INFOPLIST_KEY_SUEnableAutomaticChecks=YES
        INFOPLIST_KEY_SUAutomaticallyUpdate=YES
        INFOPLIST_KEY_SUVerifyUpdateBeforeExtraction=YES
        INFOPLIST_KEY_SURequireSignedFeed=YES
    )
fi

xcodebuild "${xcodebuild_args[@]}" build
test -d "$XCODE_APP_BUNDLE"

rm -rf "$APP_BUNDLE" "$ZIP_PATH" "$DMG_PATH" "$BUILD_DIR/dmg-root"
mkdir -p "$BUILD_DIR"
ditto --norsrc "$XCODE_APP_BUNDLE" "$APP_BUNDLE"
rm -f "$APP_BUNDLE"/._* "$APP_BUNDLE/Contents"/._* "$APP_BUNDLE/Contents/MacOS"/._* "$APP_BUNDLE/Contents/Resources"/._*

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
        printf '%s\n' "Warning: ad hoc signing is disabled for release archives."
    else
        codesign --deep --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE"
    fi
    if [[ "$CODESIGN_IDENTITY" != "-" ]]; then
        codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
    fi
else
    printf '%s\n' "Warning: CODESIGN_IDENTITY is not set; this archive is unsigned."
fi

ditto --norsrc -c -k --keepParent "$APP_BUNDLE" "$ZIP_PATH"

mkdir -p "$BUILD_DIR/dmg-root"
ditto --norsrc "$APP_BUNDLE" "$BUILD_DIR/dmg-root/$APP_NAME.app"
ln -s /Applications "$BUILD_DIR/dmg-root/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD_DIR/dmg-root" -ov -format UDZO "$DMG_PATH" >/dev/null

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
    hdiutil create -volname "$APP_NAME" -srcfolder "$BUILD_DIR/dmg-root" -ov -format UDZO "$DMG_PATH" >/dev/null
fi

rm -rf "$BUILD_DIR/dmg-root"
printf 'Created %s\nCreated %s\n' "$ZIP_PATH" "$DMG_PATH"
