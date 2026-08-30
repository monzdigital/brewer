#!/bin/bash
# Builds the Brewer executable with SwiftPM and assembles a runnable Brewer.app bundle.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Brewer"
APP="dist/Brewer.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/Brewer"
cp packaging/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f packaging/AppIcon.icns ]; then
  cp packaging/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
if [ -f packaging/PrivacyInfo.xcprivacy ]; then
  cp packaging/PrivacyInfo.xcprivacy "$APP/Contents/Resources/PrivacyInfo.xcprivacy"
fi

# Ad-hoc signature so notifications and TCC behave for local use.
codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "==> Built $APP"
