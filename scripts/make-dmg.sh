#!/usr/bin/env bash
# Builds a shareable installer: dist/Glint-<version>-arm64.dmg (+ .sha256)
# containing the app, an Applications shortcut (drag to install) and install instructions.
#
# Signing: by default the app is signed with the local self-signed identity (scripts/setup-signing.sh).
# It's the same identity for every release, so people keep their Screen Recording / Accessibility
# grants across updates. It is NOT notarized, so the first launch needs a one-time approval in
# System Settings → Privacy & Security ("Open Anyway"). The one-line web installer avoids that.
#
# Notarization (UNTESTED — needs a paid Apple Developer ID, which we don't have yet):
#   xcrun notarytool store-credentials glint-notary        # one time
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=glint-notary scripts/make-dmg.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
MINOS="$(plutil -extract LSMinimumSystemVersion raw Resources/Info.plist)"
NAME="Glint"
APP="build/$NAME.app"
DMG="dist/$NAME-$VERSION-arm64.dmg"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    # Notarization needs the hardened runtime and a secure timestamp.
    : "${SIGN_IDENTITY:?set SIGN_IDENTITY to your Developer ID Application identity}"
    SIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" --identifier app.glint.mac "$APP"
else
    ./build.sh
fi

if [[ "$(lipo -archs "$APP/Contents/MacOS/$NAME")" != "arm64" ]]; then
    echo "error: expected an arm64-only binary" >&2
    exit 1
fi
codesign --verify --strict --deep "$APP"

STAGE="$(mktemp -d)/$NAME"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$NAME.app"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/How to Install.txt" <<EOF
Glint $VERSION
Screenshots, annotations, OCR, scrolling capture and clipboard history for macOS.
For Macs with Apple silicon (M1 or later), macOS $MINOS or newer.

INSTALL
1. Drag "Glint" onto the Applications folder in this window.
2. Eject this disk image.
3. Open Glint from Applications (or Spotlight).

FIRST LAUNCH — "Glint" Not Opened / "Apple could not verify…"
Glint isn't distributed through the App Store, so macOS asks you to approve it once:
1. Click "Done" (not "Move to Trash") in the warning.
2. Open System Settings → Privacy & Security.
3. Scroll down to the message about "Glint" and click "Open Anyway".
4. Confirm with your password or Touch ID, then click "Open Anyway" again.
You only need to do this once.

Alternative (Terminal):
  xattr -dr com.apple.quarantine "/Applications/Glint.app"

PERMISSIONS
• Screen Recording (required) — macOS asks the first time you take a screenshot.
  System Settings → Privacy & Security → Screen & System Audio Recording → turn on Glint,
  then quit and reopen Glint.
• Accessibility (optional) — only for auto-scrolling in Scrolling Capture and for pasting
  straight from the clipboard picker. System Settings → Privacy & Security → Accessibility.
Nothing leaves your Mac: captures are saved to ~/Pictures/Glint.

USING IT
  ⇧⌘2  Capture an area          ⇧⌘1  Capture the screen
  ⇧⌘6  Capture a window         ⇧⌘0  Scrolling capture
  ⇧⌘8  Copy text from screen    ⇧⌘7  Pick a color
  ⌃⌘V  Clipboard history
All shortcuts can be changed in Glint → Settings → Shortcuts.

UNINSTALL
Quit Glint (menu bar icon → Quit Glint) and drag it from Applications to the Trash.
Optional: delete ~/Library/Application Support/Glint and ~/Pictures/Glint.
EOF

mkdir -p dist
rm -f "$DMG"
hdiutil create -quiet -volname "$NAME $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$(dirname "$STAGE")"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
fi

(cd dist && shasum -a 256 "$(basename "$DMG")" | tee "$(basename "$DMG").sha256")
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
