#!/bin/bash
# Builds a universal Islet.app and packs it into build/Islet.dmg
# (open it, drag Islet onto Applications). The mounted disk shows Islet's icon.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh universal

WORK="$(mktemp -d)"
trap 'hdiutil detach "$WORK/mnt" -quiet 2>/dev/null || true; rm -rf "$WORK"' EXIT

# Writable image first, so the disk can get a custom icon.
hdiutil create -size 40m -fs HFS+ -volname "Islet" -ov "$WORK/rw.dmg" >/dev/null
mkdir "$WORK/mnt"
hdiutil attach "$WORK/rw.dmg" -nobrowse -noautoopen -mountpoint "$WORK/mnt" >/dev/null

ditto build/Islet.app "$WORK/mnt/Islet.app"
ln -s /Applications "$WORK/mnt/Applications"
cp Assets/AppIcon.icns "$WORK/mnt/.VolumeIcon.icns"
SetFile -a C "$WORK/mnt"
SetFile -a V "$WORK/mnt/.VolumeIcon.icns"

hdiutil detach "$WORK/mnt" -quiet
rm -f build/Islet.dmg
hdiutil convert "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o build/Islet.dmg >/dev/null
echo "Built build/Islet.dmg ($(du -h build/Islet.dmg | cut -f1))"
