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
- **Input Monitoring** (optional) — only for Show Keystrokes; asked the first time you turn it on. Keys are only displayed, never stored.

Captures are saved to `~/Pictures/Glint`; nothing leaves your Mac.

## Default shortcuts

| | |
|---|---|
| ⇧⌘2 Capture area | ⇧⌘1 Capture screen |
| ⇧⌘6 Capture window | ⇧⌘0 Scrolling capture |
| ⇧⌘8 Copy text from screen | ⇧⌘7 Pick color |
| ⌃⌘V Clipboard history | |
| ⌃⌥C Cursor highlight | ⌃⌥K Show keystrokes |
| ⌃⌥D Draw on screen | ⌃⌥M Zoom lens (tap or hold) |
| ⌃⌥X Turn off presenting tools | |

All of them can be changed in Settings → Shortcuts.

## Presenting tools

For demos and screen recordings (menu bar → Presenting, the Home window, or Settings → Presenting):

- **Cursor highlight** — a halo around the pointer that flashes red/blue on left/right clicks and dims when the mouse rests.
- **Show keystrokes** — shortcuts and typing appear as chips near the bottom of the screen and fade after 2 s.
- **Draw on screen** — the editor's own tools (arrow, box, pen, highlighter, text, steps, Box + Step, spotlight) on the live screen. ⌘Z undo, ⌘⌫ clear, esc or right-click to stop; the hand button passes clicks through, the camera button captures the screen with your drawing into the editor.
- **Zoom lens** — a live magnifier that follows the pointer. Tap ⌃⌥M to toggle, hold it to peek; ⌃⌥= / ⌃⌥− zoom, esc closes.

The halo, keystrokes and lens never appear in Glint's own screenshots; drawings do.

## Themes

Pick a theme from the palette button on the Home window, the menu bar icon → Theme, View → Theme, or Settings → Appearance:

- **Classic** — frosted materials and soft shadows.
- **Liquid Glass** — Apple's glass on toolbars and buttons, with a see-through window (macOS 26+).
- **Glint Glass** — violet-tinted glass with a light rim, on the Home tiles too (macOS 26+).

Settings can be shown as tabs or as a sidebar (Settings → Appearance → Layout).

## Build from source

Requires the Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh --install        # build and install into /Applications
scripts/make-dmg.sh         # dist/Glint-<version>-arm64.dmg + .sha256
scripts/release.sh          # publish GitHub release v<version> (bump the version first)
```

See [CLAUDE.md](CLAUDE.md) for signing, toolchain notes and the release process.
