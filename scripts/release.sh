#!/bin/bash
# Builds a distributable, notarized Brewer.app:
#   universal binary (arm64 + x86_64) -> .app bundle -> Developer ID codesign
#   -> notarization -> staple -> zip
#
# Requirements (one-time, needs an Apple Developer Program membership):
#   1. A "Developer ID Application" certificate in your Keychain.
#   2. A notary profile:  xcrun notarytool store-credentials brewer-notary \
#        --apple-id you@example.com --team-id TEAMID --password app-specific-pw
#
# Usage:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="brewer-notary" \
#   bash scripts/release.sh
#
# Without SIGN_IDENTITY it falls back to ad-hoc signing and skips notarization
# (the app then runs locally but Gatekeeper will block it on other Macs).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" packaging/Info.plist)
APP="dist/Brewer.app"
ZIP="dist/Brewer-${VERSION}.zip"

echo "==> Building arm64"
swift build -c release --triple arm64-apple-macosx14.0

echo "==> Building x86_64"
swift build -c release --triple x86_64-apple-macosx14.0

echo "==> Creating universal binary"
mkdir -p dist
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create \
  ".build/arm64-apple-macosx/release/Brewer" \
  ".build/x86_64-apple-macosx/release/Brewer" \
  -output "$APP/Contents/MacOS/Brewer"
lipo -archs "$APP/Contents/MacOS/Brewer"

cp packaging/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp packaging/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  echo "==> Codesigning with: $SIGN_IDENTITY"
  codesign --force --deep \
    --options runtime \
    --entitlements packaging/Brewer.entitlements \
    --sign "$SIGN_IDENTITY" \
    --timestamp \
    "$APP"
  codesign --verify --strict --verbose=2 "$APP"

  echo "==> Zipping for notarization"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"

  if [ -n "${NOTARY_PROFILE:-}" ]; then
    echo "==> Submitting to Apple notary service (this can take a few minutes)"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> Stapling ticket"
    xcrun stapler staple "$APP"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "==> Done: $ZIP (notarized & stapled)"
  else
    echo "!! NOTARY_PROFILE not set — skipped notarization. Set it up with:"
    echo "   xcrun notarytool store-credentials brewer-notary --apple-id … --team-id … --password …"
  fi
else
  echo "!! SIGN_IDENTITY not set — ad-hoc signing only (local use)."
  codesign --force --deep --sign - "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "==> Done: $ZIP (NOT distributable — see docs/DISTRIBUTION.md)"
fi
