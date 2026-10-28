# Glint — notes for Claude Code

Native macOS screenshot / annotation / clipboard app. SwiftUI + AppKit, ScreenCaptureKit, Vision.
Goal of this file: "clone my glint repo, build and install it" should work in one request.

## Facts
- Bundle ID: `app.glint.mac` (it used to be `app.glint.Glint` — don't go back: a stale TCC record for the old ID caused a permission loop).
- Version: `CFBundleShortVersionString` in `Resources/Info.plist`. Minimum macOS 14 (`LSMinimumSystemVersion`).
- **Apple silicon (arm64) only. Never add Intel or universal builds.** `build.sh` and `make-dmg.sh` fail if `lipo -archs` isn't exactly `arm64`.
- Permissions: **Screen Recording** (all captures) and **Accessibility** (scrolling auto-scroll, clipboard auto-paste).
- Owner: GitHub `magicoppk27`. Git author for this repo (local config): Rodrigo Furtado <magicoppk@gmail.com>.

## Build
- `./build.sh` → `build/Glint.app`; `./build.sh --install` also copies it to /Applications. `CONFIG=debug` for a debug build.
- Toolchain: Xcode **Command Line Tools only** (no full Xcode, no Homebrew on the original Mac). The macOS 27 SDK's SwiftUI `@State`/`@Observable` are macros whose plugin ships only with full Xcode, so:
  - `build.sh` picks the newest `MacOSX26.*.sdk` in CommandLineTools if present.
  - If only a 27+ SDK exists, either install full Xcode or avoid macro-based SwiftUI APIs (the code already uses `ObservableObject` / `@Published` / `@ObservedObject` / `@StateObject` and plain `@State` only where the 26 SDK compiles it — keep new code macro-free).
- Tests are debug env flags on the built binary, e.g. `GLINT_STITCH_TEST=<dir>` (scroll stitching, pixel-exact), add `GLINT_STITCH_H=1` for horizontal, `GLINT_HOTKEY_TEST=1`, `GLINT_SNAPSHOT=<dir> GLINT_SAMPLE=<png>` (renders windows/export to PNG).
- Performance probe (release build, launched via LaunchServices so capture permission applies):
  `open -W -n --env GLINT_PERF=1 --stdout /tmp/perf.txt /Applications/Glint.app; cat /tmp/perf.txt`
  prints main-thread ms for copy, PNG encode, sound, the whole after-capture path, one editor frame
  (5K image, 1500×950 window) and freezing every display. Note: it uses the clipboard — save/restore it.
- `GLINT_WINSHOT=1` with `GLINT_SNAPSHOT`/`GLINT_SAMPLE` also captures the live editor window with real
  pixels (shows GPU layer shadows that `cacheDisplay` snapshots miss).
- Permission check that matters: launch through LaunchServices so Glint (not the shell) is the responsible process:
  `open -W -n --env GLINT_PERMCHECK=1 --stdout /tmp/p.txt /Applications/Glint.app; cat /tmp/p.txt`

## Signing (why permissions survive rebuilds)
- Ad-hoc signing makes TCC identify the app by cdhash, so every rebuild loses Screen Recording. Glint is signed with a stable self-signed identity **"Glint Local Signing"** (SHA-1 `33F6828E026F3F2C3CC3F0E687908745DEBEB38A`).
- `scripts/setup-signing.sh` creates (once) / re-adds / unlocks it in `.signing/signing.keychain-db` (password in `.signing/keychain-password`, chmod 600; no auto-lock), adds that keychain to the user search list (handles paths with spaces — the list also contains other projects' keychains, e.g. "Screen Cursor", Dictate), and prints the SHA-1. `build.sh` signs with `codesign --keychain … --sign <sha1>`; override with `SIGN_IDENTITY` (`-` = ad-hoc).
- Verify: `codesign -dr - /Applications/Glint.app` must show `certificate leaf = H"33f6…"`, not `cdhash H…`. To prove grants survive, install a build with a **different CDHash** (e.g. `CONFIG=debug ./build.sh --install`) and run the permission check — identical rebuilds can be byte-for-byte the same and prove nothing.
- **`.signing/` is gitignored and must be backed up separately.** On a new Mac: copy the backup into the clone before building. Without it a new certificate is created and every user must grant permissions again once (on an ad-hoc → cert switch, reset the old grant with `tccutil reset ScreenCapture app.glint.mac`).

## Distribute
- `scripts/make-dmg.sh` → `dist/Glint-<version>-arm64.dmg` (+ `.sha256`) with the app, an /Applications link and "How to Install.txt". Not notarized; optional, **untested** notarization path via `SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=…`.
- `scripts/release.sh` (clean tree + new version required) → GitHub release `v<version>` with fixed asset names `Glint-arm64.dmg` and `Glint-arm64.dmg.sha256`, so `…/releases/latest/download/Glint-arm64.dmg` is always the newest.
- `scripts/web-install.sh` is the `curl … | bash` installer: checks arm64 + macOS 14, downloads with curl (no quarantine), verifies SHA-256, installs to /Applications (or ~/Applications), strips quarantine, `codesign --verify --strict`, opens Glint.
- Release downloads only work without login while the repo is **public**.
- GitHub CLI: `~/.local/bin/gh` (logged in as magicoppk27 on the original Mac). If missing: download the official arm64 release from github.com/cli/cli and verify its SHA-256 (no Homebrew).

## Performance rules (from the BAMA performance skill, measured on 5K captures)
- Nothing slow on the main thread after a capture: the shutter is `AudioServicesPlaySystemSound` off-main
  (NSSound.play blocked 150+ ms), the clipboard gets a promised PNG/TIFF (`ImagePasteProvider`) encoded in the
  background and resolved on quit, and saving reserves the file name then encodes/writes in the background.
  After-capture main-thread time: ~340 ms → ~0.3 ms.
- Displays are frozen in parallel (task group).
- Selection overlay: the frozen picture is a layer's contents; mouse moves redraw only the screen under the pointer.
- Editor: draws a copy of the screenshot pre-scaled to display size, and the picture's drop shadow is a GPU layer
  shadow with an explicit path. One frame: 18.4 ms → ~3 ms.
- Clipboard history timer: 0.5 s, tolerance 0.1, `RunLoop.main` `.common` mode; skips ConcealedType, TransientType,
  AutoGeneratedType and `com.agilebits.onepassword`.

## Gotchas already solved
- Area capture is drag-only; Window mode picks windows. Captures include Glint's own windows; transient helpers are tagged `GlintChrome.id` and excluded.
- The editor canvas spans the transparent title bar, so it drags the window itself (`performDrag`).
- Editor Copy copies and closes silently; captures remain in Recent captures.
