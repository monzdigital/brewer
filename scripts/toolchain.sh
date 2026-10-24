# Shared toolchain selection for bundle.sh and release.sh. Source it, don't run it.
#
# With the macOS 27 SDK, SwiftUI's @State became a Swift macro whose compiler
# plugin (SwiftUIMacros) ships only with Xcode, so the Command Line Tools can no
# longer build Brewer against their newest SDK. Order of preference:
#   1. an explicit DEVELOPER_DIR from the caller,
#   2. Xcode (the selected one, then /Applications/Xcode.app) with its license accepted,
#   3. the Command Line Tools, pinned to the newest pre-27 SDK they still ship.

if [ -z "${DEVELOPER_DIR:-}" ]; then
  for candidate in "$(xcode-select -p 2>/dev/null || true)" /Applications/Xcode.app/Contents/Developer; do
    case "$candidate" in
      *.app/Contents/Developer)
        if [ -d "$candidate" ] && DEVELOPER_DIR="$candidate" xcodebuild -license check >/dev/null 2>&1; then
          export DEVELOPER_DIR="$candidate"
          break
        fi
        ;;
    esac
  done
fi

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Library/Developer/CommandLineTools/SDKs ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
  sdk_major=$(xcrun --sdk macosx --show-sdk-version 2>/dev/null | cut -d. -f1 || true)
  if [ -z "${SDKROOT:-}" ] && [ "${sdk_major:-0}" -ge 27 ] 2>/dev/null; then
    legacy_sdk=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX2[0-6]*.sdk 2>/dev/null | sort -V | tail -1 || true)
    if [ -n "$legacy_sdk" ]; then
      export SDKROOT="$legacy_sdk"
    else
      echo "!! The macOS $sdk_major SDK needs Xcode to build SwiftUI apps (the SwiftUIMacros plugin)." >&2
      echo "   Install Xcode, or Command Line Tools that still include a macOS 26 SDK." >&2
      exit 1
    fi
  fi
fi

echo "==> Toolchain: ${DEVELOPER_DIR:-system default}${SDKROOT:+ with $(basename "$SDKROOT")}"
