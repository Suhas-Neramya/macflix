#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${MACFLIX_REBUILD_BUILD_DIR:-$PROJECT_ROOT/build}"
SIGNING_IDENTITY="${MACFLIX_SIGNING_IDENTITY:--}"
APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$PROJECT_ROOT/Resources/Info.plist")"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macflix-rebuild.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP_BUNDLE="$STAGING_DIR/Macflix.app"

SPARKLE_DIR="$(bash "$PROJECT_ROOT/bin/fetch_sparkle.sh" "$BUILD_DIR/dependencies")"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$APP_BUNDLE/Contents/Frameworks" "$BUILD_DIR/module-cache"
printf 'Building Macflix %s for Apple silicon, macOS 14 or later...\n' "$APP_VERSION"
xcrun swiftc -O -swift-version 5 -warnings-as-errors \
    -target arm64-apple-macosx14.0 -parse-as-library \
    -module-cache-path "$BUILD_DIR/module-cache" \
    -F "$SPARKLE_DIR" -framework Sparkle \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    -framework Cocoa -framework WebKit -framework AVFoundation -framework Network \
    "$PROJECT_ROOT"/Sources/*.swift -o "$APP_BUNDLE/Contents/MacOS/Macflix"

for resource in MacflixIcon0_2_4.icns MacflixDock.png MultichannelAudio.js NativeAudioBridge.js AudioDiagnostics.js Playback.js; do
    cp "$PROJECT_ROOT/Resources/$resource" "$APP_BUNDLE/Contents/Resources/$resource"
done
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_ROOT/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE"
cp "$SPARKLE_DIR/LICENSE" "$APP_BUNDLE/Contents/Resources/LICENSE-Sparkle.txt"
ditto --norsrc --noextattr "$SPARKLE_DIR/Sparkle.framework" "$APP_BUNDLE/Contents/Frameworks/Sparkle.framework"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
codesign --force --sign "$SIGNING_IDENTITY" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

# Replace only this rebuild's generated app bundle; never touch /Applications.
rm -rf "$BUILD_DIR/Macflix.app"
ditto --norsrc --noextattr "$APP_BUNDLE" "$BUILD_DIR/Macflix.app"
codesign --verify --deep --strict "$BUILD_DIR/Macflix.app"
printf 'Built: %s\n' "$BUILD_DIR/Macflix.app"
