import AppKit
import ScreenCaptureKit
import SwiftUI

/// GLINT_DESIGN=<dir>: opens each surface in each look and saves real screen pixels (glass included).
/// Launch through LaunchServices: `open -W -n --env GLINT_DESIGN=/tmp/d /Applications/Glint.app`
@MainActor
enum DebugDesign {
    static func run(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let savedLook = Prefs.d.string(forKey: GlassLook.key)
        let savedLayout = Prefs.d.string(forKey: "settingsLayout")
        let savedPane = Prefs.d.string(forKey: "settingsPane")
        Task { @MainActor in
            await wait(1.5)
            NSApp.activate(ignoringOtherApps: true)
            let shot = try? await CaptureService.shared.freeze([NSScreen.withMouse]).first
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let mode = dark ? "dark" : "light"
                for look in GlassLook.allCases {
                    Prefs.d.set(look.rawValue, forKey: GlassLook.key)
                    await wait(0.4)
                    if let home = HomeWindow.window {
                        home.setContentSize(CGSize(width: 1000, height: 680))
                        home.center()
                        home.makeKeyAndOrderFront(nil)
                        home.level = .floating // keep other apps from covering it mid-capture
                        await wait(0.6)
                        await capture(home.frame, "\(dir)/home-\(look.rawValue)-\(mode).png")
                        home.level = .normal
                    }
                    if let f = shot {
                        EditorWindowController.show(Shot(image: f.image, scale: f.scale))
                        if let w = EditorWindowController.open.last?.window {
                            w.setFrame(CGRect(x: 0, y: 0, width: 1200, height: 760), display: true)
                            w.center()
                            w.makeKeyAndOrderFront(nil)
                            w.level = .floating
                            await wait(0.8)
                            await capture(w.frame, "\(dir)/editor-\(look.rawValue)-\(mode).png")
                            w.close()
                        }
                    }
                    if !dark {
                        // Overlays sit over other apps, the same in light and dark.
                        Presenter.shared.set(.draw, true)
                        await wait(0.6)
                        if let t = NSApp.windows.first(where: { $0.contentView is NSHostingView<DrawToolbar> }) {
                            await capture(t.frame.insetBy(dx: -20, dy: -20), "\(dir)/drawbar-\(look.rawValue).png")
                        }
                        Presenter.shared.set(.draw, false)
                        Toast.show("Copied to clipboard")
                        await wait(0.5)
                        if let t = NSApp.windows.first(where: { $0.identifier == GlintChrome.id && $0.isVisible && $0.level == .popUpMenu }) {
                            await capture(t.frame, "\(dir)/toast-\(look.rawValue).png")
                        }
                    }
                }
                // Settings: both layouts, on Appearance, in the default look.
                Prefs.d.set(GlassLook.liquid.rawValue, forKey: GlassLook.key)
                for layout in ["tabs", "sidebar"] {
                    for pane in [SettingsPane.appearance, .permissions] {
                        Prefs.d.set(layout, forKey: "settingsLayout")
                        Prefs.d.set(pane.rawValue, forKey: "settingsPane")
                        // A stand-in window with the same toolbar style as the Settings scene's.
                        let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
                        w.title = pane.title
                        w.toolbarStyle = layout == "tabs" ? .preference : .unified
                        let host = NSHostingController(rootView: SettingsView())
                        w.contentViewController = host
                        w.center()
                        w.level = .floating
                        w.makeKeyAndOrderFront(nil)
                        await wait(1.2)
                        await capture(w.frame, "\(dir)/settings-\(layout)-\(pane.rawValue)-\(mode).png")
                        w.orderOut(nil)
                    }
                }
            }
            NSApp.appearance = nil
            Prefs.d.set(savedLook, forKey: GlassLook.key)
            Prefs.d.set(savedLayout, forKey: "settingsLayout")
            Prefs.d.set(savedPane, forKey: "settingsPane")
            print("DESIGN done")
            NSApp.terminate(nil)
        }
    }

    static func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    /// Real screen pixels of a rectangle (Cocoa coordinates), nothing excluded.
    static func capture(_ rect: CGRect, _ path: String) async {
        let mid = CGPoint(x: rect.midX, y: rect.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mid) }), let id = screen.displayID,
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == id }) else { print("DESIGN miss \(path)"); return }
        let r = rect.intersection(screen.frame)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: r.minX - screen.frame.minX, y: screen.frame.maxY - r.maxY, width: r.width, height: r.height)
        config.width = Int(r.width * screen.backingScaleFactor)
        config.height = Int(r.height * screen.backingScaleFactor)
        config.showsCursor = false
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: config)
        else { print("DESIGN miss \(path)"); return }
        try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
