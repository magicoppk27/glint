#!/bin/zsh
# Builds build/Glint.app (Apple silicon only) and optionally installs it into /Applications.
#   ./build.sh             release build
#   ./build.sh --install   release build, then install
#   CONFIG=debug ./build.sh --install   debug build (different binary/CDHash, same signature)
# Signing: the stable local identity from scripts/setup-signing.sh. Override with
#   SIGN_IDENTITY="Developer ID Application: …"   or   SIGN_IDENTITY=-   (ad-hoc).
set -euo pipefail
cd "${0:A:h}"
CONFIG="${CONFIG:-release}"

# The macOS 27 SDK needs the SwiftUI macro plugin that only ships with full Xcode.
SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1 || true)
[[ -n "$SDK" ]] && export SDKROOT="$SDK"

swift build -c "$CONFIG" --arch arm64

APP=build/Glint.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Glint" "$APP/Contents/MacOS/Glint"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [[ ! -f build/AppIcon.icns || scripts/make-icon.swift -nt build/AppIcon.icns ]]; then
  ICONSET=build/AppIcon.iconset
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  swift scripts/make-icon.swift build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [[ "$(lipo -archs "$APP/Contents/MacOS/Glint")" != "arm64" ]]; then
  echo "error: expected an arm64-only binary" >&2; exit 1
fi

# TCC identifies ad-hoc apps by cdhash, so every rebuild would lose Screen Recording permission.
# Signing with a stable certificate makes the grant survive rebuilds and updates.
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --deep --sign "$SIGN_IDENTITY" --identifier app.glint.mac "$APP"
else
  HASH="$(scripts/setup-signing.sh)"
  codesign --force --deep --keychain "$PWD/.signing/signing.keychain-db" --sign "$HASH" --identifier app.glint.mac "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Glint 2>/dev/null || true
  rm -rf /Applications/Glint.app
  ditto "$APP" /Applications/Glint.app
  echo "Installed /Applications/Glint.app"
fi
