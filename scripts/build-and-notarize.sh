#!/usr/bin/env bash
set -euo pipefail

# ------------------------------------------------------------------
# build-and-notarize.sh — Build, sign, notarize, and package FreeWispr
#
# Usage:
#   SIGNING_IDENTITY="Developer ID Application: ..." \
#   NOTARIZE_PROFILE="FreeWispr-notarize" \
#     ./scripts/build-and-notarize.sh 1.0.0
#
# Environment variables:
#   SIGNING_IDENTITY  — codesign identity (required)
#   NOTARIZE_PROFILE  — notarytool keychain profile (required)
# ------------------------------------------------------------------

VERSION="${1:?Usage: $0 <version>}"
APP_NAME="FreeWispr"
BUNDLE_ID="com.ygivenx.FreeWispr"

: "${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
: "${NOTARIZE_PROFILE:?Set NOTARIZE_PROFILE to your notarytool keychain profile name}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../FreeWispr" && pwd)"
BUILD_DIR="$SCRIPT_DIR/../build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME-$VERSION.dmg"

ENTITLEMENTS="$PROJECT_DIR/$APP_NAME.entitlements"
INFO_PLIST="$PROJECT_DIR/Sources/$APP_NAME/Info.plist"

echo "==> Stage 1: Building $APP_NAME (release, arm64)"
cd "$PROJECT_DIR"
swift build -c release --arch arm64

BUILT_BINARY="$PROJECT_DIR/.build/arm64-apple-macosx/release/$APP_NAME"
if [ ! -f "$BUILT_BINARY" ]; then
    echo "Error: Built binary not found at $BUILT_BINARY"
    exit 1
fi

echo "==> Stage 2: Assembling .app bundle"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILT_BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$INFO_PLIST" "$APP_BUNDLE/Contents/Info.plist"
cp "$PROJECT_DIR/Sources/$APP_NAME/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/"
cp -R "$PROJECT_DIR/.build/arm64-apple-macosx/release/${APP_NAME}_${APP_NAME}.bundle" "$APP_BUNDLE/"

# Stamp version into the bundle plist
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Stage 3: Code signing"
codesign --force --deep \
    --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$APP_BUNDLE"

echo "    Verifying signature..."
codesign --verify --verbose=2 "$APP_BUNDLE"

echo "==> Stage 4: Notarization"
# Create a temporary zip for notarization submission
NOTARIZE_ZIP="$BUILD_DIR/$APP_NAME-notarize.zip"
ditto -c -k --keepParent "$APP_BUNDLE" "$NOTARIZE_ZIP"

xcrun notarytool submit "$NOTARIZE_ZIP" \
    --keychain-profile "$NOTARIZE_PROFILE" \
    --wait

rm -f "$NOTARIZE_ZIP"

echo "    Stapling notarization ticket..."
xcrun stapler staple "$APP_BUNDLE"

echo "==> Stage 5: Creating DMG"
rm -f "$DMG_PATH"

# Create a temporary directory for DMG contents
DMG_STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

rm -rf "$DMG_STAGING"

echo "    Signing DMG..."
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"

echo ""
echo "Done! Artifacts:"
echo "  App:  $APP_BUNDLE"
echo "  DMG:  $DMG_PATH"
