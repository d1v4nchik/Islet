#!/bin/bash
# Builds Islet.app with just the Xcode Command Line Tools (no Xcode project needed).
#   ./build.sh             build/Islet.app for this Mac
#   ./build.sh universal   Apple Silicon + Intel
set -euo pipefail
cd "$(dirname "$0")"

# Build and sign outside the project folder: iCloud-synced folders (like Documents) add
# file attributes that make code signing fail.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/Islet.app"
SDK="$(xcrun --show-sdk-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {
  xcrun swiftc -O -swift-version 5 -target "$1-apple-macos14.0" -sdk "$SDK" Sources/*.swift -o "$2"
}

if [ "${1:-}" = "universal" ]; then
  compile arm64 "$WORK/Islet-arm64"
  compile x86_64 "$WORK/Islet-x86_64"
  lipo -create "$WORK/Islet-arm64" "$WORK/Islet-x86_64" -output "$APP/Contents/MacOS/Islet"
else
  compile "$(uname -m)" "$APP/Contents/MacOS/Islet"
fi

cp Info.plist "$APP/Contents/Info.plist"
if [ -f Assets/AppIcon.icns ]; then
  cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
xattr -cr "$APP"
codesign --force --sign - "$APP"

mkdir -p build
rm -rf build/Islet.app
ditto "$APP" build/Islet.app
echo "Built build/Islet.app"
