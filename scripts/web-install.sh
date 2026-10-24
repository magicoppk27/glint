#!/bin/bash
# Installs (or updates) the latest Glint release from GitHub:
#   curl -fsSL https://raw.githubusercontent.com/magicoppk27/glint/main/scripts/web-install.sh | bash
# curl doesn't quarantine downloads, so this route skips the Gatekeeper "Open Anyway" step.
set -euo pipefail

REPO="magicoppk27/glint"
BASE="https://github.com/$REPO/releases/latest/download"
NAME="Glint.app"
MIN_MACOS=14

fail() { echo "error: $*" >&2; exit 1; }

[[ "$(uname -m)" == "arm64" ]] || fail "Glint needs a Mac with Apple silicon (M1 or later)."
(( $(sw_vers -productVersion | cut -d. -f1) >= MIN_MACOS )) || fail "Glint needs macOS $MIN_MACOS Sonoma or later."

DEST_DIR="/Applications"
[[ -w "$DEST_DIR" ]] || { DEST_DIR="$HOME/Applications"; mkdir -p "$DEST_DIR"; }
DEST="$DEST_DIR/$NAME"

TMP="$(mktemp -d)"
MNT="$TMP/mnt"
cleanup() { hdiutil detach -quiet "$MNT" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

echo "Downloading Glint…"
curl -fL --progress-bar -o "$TMP/Glint.dmg" "$BASE/Glint-arm64.dmg"
EXPECTED="$(curl -fsSL "$BASE/Glint-arm64.dmg.sha256" | awk '{print $1}')"
ACTUAL="$(shasum -a 256 "$TMP/Glint.dmg" | awk '{print $1}')"
[[ -n "$EXPECTED" && "$EXPECTED" == "$ACTUAL" ]] || fail "checksum mismatch — download corrupted or tampered with; nothing was installed."

mkdir -p "$MNT"
hdiutil attach -nobrowse -readonly -quiet -mountpoint "$MNT" "$TMP/Glint.dmg"
[[ -d "$MNT/$NAME" ]] || fail "the disk image doesn't contain $NAME."

pkill -x Glint 2>/dev/null && sleep 1 || true
rm -rf "$DEST"
ditto "$MNT/$NAME" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
codesign --verify --strict "$DEST" || fail "the installed app's signature is invalid."

VERSION="$(defaults read "$DEST/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "?")"
open "$DEST"
echo "Installed Glint $VERSION in $DEST_DIR."
echo "Take a screenshot with ⇧⌘2 — macOS will ask for Screen Recording once; allow it, then reopen Glint."
