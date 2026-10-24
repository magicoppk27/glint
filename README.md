# Glint

A native macOS screenshot tool: area, window, full-screen and scrolling capture (down or sideways), OCR and QR codes, a color picker, an annotation editor (arrows, shapes, numbered steps, blur, spotlight, magnifier, crop, backdrops), pinned images and a 15-item clipboard history.

## Install

In Terminal (Apple silicon, macOS 14 or newer):

```bash
curl -fsSL https://raw.githubusercontent.com/magicoppk27/glint/main/scripts/web-install.sh | bash
```

Or download the installer: **[Glint-arm64.dmg](https://github.com/magicoppk27/glint/releases/latest/download/Glint-arm64.dmg)**, open it and drag Glint to Applications. Glint isn't notarized, so the first launch needs **System Settings → Privacy & Security → Open Anyway** (the Terminal install skips this). Details are in "How to Install.txt" inside the DMG.

## Requirements

- A Mac with Apple silicon (M1 or later) — there is no Intel build.
- macOS 14 Sonoma or newer.

## Permissions

- **Screen Recording** (required) — macOS asks the first time you take a screenshot. Allow it, then quit and reopen Glint.
- **Accessibility** (optional) — auto-scrolling in Scrolling Capture and pasting straight from the clipboard picker.

Captures are saved to `~/Pictures/Glint`; nothing leaves your Mac.

## Default shortcuts

| | |
|---|---|
| ⇧⌘2 Capture area | ⇧⌘1 Capture screen |
| ⇧⌘6 Capture window | ⇧⌘0 Scrolling capture |
| ⇧⌘8 Copy text from screen | ⇧⌘7 Pick color |
| ⌃⌘V Clipboard history | |

All of them can be changed in Settings → Shortcuts.

## Build from source

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh --install        # build and install into /Applications
scripts/make-dmg.sh         # dist/Glint-<version>-arm64.dmg + .sha256
scripts/release.sh          # publish GitHub release v<version> (bump the version first)
```

See [CLAUDE.md](CLAUDE.md) for signing, toolchain notes and the release process.
