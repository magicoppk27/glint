#!/bin/zsh
# Builds Glint.app and installs it into /Applications.
set -euo pipefail
cd "${0:A:h}"

# The macOS 27 SDK needs the SwiftUI macro plugin that only ships with full Xcode.
SDK=$(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1 || true)
[[ -n "$SDK" ]] && export SDKROOT="$SDK"

swift build -c release

APP=build/Glint.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Glint "$APP/Contents/MacOS/Glint"
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

# TCC records ad-hoc apps by cdhash, so every rebuild would lose Screen Recording permission.
# Signing with a stable (self-signed) certificate makes the grant survive rebuilds.
KC="$PWD/.signing/glint-signing.keychain-db"
if [[ -f "$KC" ]]; then
  security unlock-keychain -p glint "$KC"
  codesign --force --deep --keychain "$KC" --sign "Glint Local Signing" --identifier app.glint.mac "$APP"
else
  echo "warning: $KC missing; signing ad-hoc (permission will reset on each build)" >&2
  codesign --force --deep --sign - --identifier app.glint.mac "$APP"
fi

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Glint 2>/dev/null || true
  rm -rf /Applications/Glint.app
  ditto "$APP" /Applications/Glint.app
  echo "Installed /Applications/Glint.app"
fi
