#!/bin/bash
# Installs (or updates) Islet in ~/Applications:
#
#   curl -fsSL https://raw.githubusercontent.com/d1v4nchik/Islet/main/install.sh | bash
#
# A download made from Terminal isn't marked as "from the internet", so macOS doesn't show the
# "can't be checked for malicious software" warning. No admin password needed.
set -euo pipefail

REPO="d1v4nchik/Islet"
DEST="$HOME/Applications"

TMP="$(mktemp -d)"
MNT="$TMP/mnt"
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null || true; rm -rf "$TMP"' EXIT

echo "Downloading Islet..."
curl -fsSL -o "$TMP/Islet.dmg" "https://github.com/$REPO/releases/latest/download/Islet.dmg"
mkdir "$MNT"
hdiutil attach "$TMP/Islet.dmg" -nobrowse -readonly -mountpoint "$MNT" -quiet

if ! codesign --verify --strict -R='identifier "app.islet.calendar"' "$MNT/Islet.app" 2>/dev/null; then
    echo "That download doesn't look like Islet, so nothing was installed."
    exit 1
fi

mkdir -p "$DEST"
pkill -x Islet 2>/dev/null || true
rm -rf "$DEST/Islet.app"
ditto "$MNT/Islet.app" "$DEST/Islet.app"
open "$DEST/Islet.app"
echo "Done! Islet is in $DEST."
