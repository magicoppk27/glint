# Glint

A native macOS screenshot tool: area, window, full-screen and scrolling capture, OCR, a color picker, an annotation editor, pinned images and clipboard history.

## Build & install

Requires macOS 14+ and the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh --install   # builds Glint.app and copies it to /Applications
./build.sh             # build only (output: build/Glint.app)
```

## Code signing

`build.sh` signs with a self-signed certificate kept in `.signing/glint-signing.keychain-db`, which is **not** committed. A stable certificate lets macOS keep Screen Recording / Accessibility permissions across rebuilds. Without that folder the build falls back to ad-hoc signing, and macOS will ask for those permissions again after each rebuild.

Back up `.signing/` separately if you want to rebuild on another Mac with the same identity.

## Layout

- `Sources/Glint/` — app source (SwiftUI + AppKit, ScreenCaptureKit, Vision)
- `scripts/make-icon.swift` — draws the app icon
- `Resources/Info.plist` — bundle metadata
