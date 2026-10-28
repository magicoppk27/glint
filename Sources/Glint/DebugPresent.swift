import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import SwiftUI

/// GLINT_PRESENT_TEST=<dir>: checks the presenting tools and writes their snapshots to <dir>.
/// Launch through LaunchServices so Glint's own permissions apply:
/// `open -W -n --env GLINT_PRESENT_TEST=/tmp/p --stdout /tmp/p.txt /Applications/Glint.app`
@MainActor
enum DebugPresent {
    static func run(into dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let saved = Prefs.d.stringArray(forKey: "presentingOn")
        Presenter.shared.turnOffAll()
        Task { @MainActor in
            await haloTest(dir)
            await hotkeyReleaseTest()
            Presenter.shared.turnOffAll()
            Prefs.d.set(saved, forKey: "presentingOn")
            print("PRESENT done")
            NSApp.terminate(nil)
        }
    }

    static func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1e9)) }

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("PRESENT \(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
    }

    // MARK: Halo

    static func haloTest(_ dir: String) async {
        let hk = HotkeyStore.shared
        check("halo default shortcut", hk.label(.present(.halo)) == "⌃⌥C", hk.label(.present(.halo)))
        print("PRESENT info shortcut-conflicts=\(hk.failed.sorted())")

        Presenter.shared.set(.halo, true)
        await wait(0.3)
        let panel = NSApp.windows.first { $0.identifier == GlintChrome.id && $0.level == .presenting }
        check("halo shows", CursorHalo.shared.isShowing && panel != nil)
        if let panel {
            let m = NSEvent.mouseLocation
            let d = hypot(panel.frame.midX - m.x, panel.frame.midY - m.y)
            check("halo centered on pointer", d < 1.5, "off by \(d)")
            check("halo is click-through", panel.ignoresMouseEvents)
        }
        check("halo remembered", Prefs.d.stringArray(forKey: "presentingOn") == ["halo"])

        // Left out of Glint's captures.
        if let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true), let panel {
            let excluded = CaptureService.chromeWindows(in: content).contains { $0.windowID == CGWindowID(panel.windowNumber) }
            check("halo excluded from captures", excluded)
        } else {
            check("halo excluded from captures", false, "no Screen Recording")
        }

        // Snapshots of the three states over a light and a dark backdrop.
        let st = CursorHalo.shared.state
        for (name, press) in [("idle", HaloState.Press.none), ("left", .left), ("right", .right)] {
            st.press = press
            for dark in [false, true] {
                let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
                w.contentView = NSHostingView(rootView: HaloView(state: st)
                    .frame(width: 200, height: 200)
                    .background(dark ? Color(white: 0.12) : Color(white: 0.96)))
                w.orderFront(nil)
                await wait(0.35)
                DebugSnapshot.save(w, "\(dir)/halo-\(name)-\(dark ? "dark" : "light").png")
                w.orderOut(nil)
            }
        }
        st.press = .none

        Presenter.shared.turnOffAll()
        await wait(0.1)
        check("turn off all hides halo", !CursorHalo.shared.isShowing && Prefs.d.stringArray(forKey: "presentingOn") == [])
    }

    // MARK: Hotkeys

    /// Posts a real key press and release (needs Accessibility) and checks both handlers fire.
    static func hotkeyReleaseTest() async {
        var down = 0, up = 0, seen = 0
        let mods = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        let ok = HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_J), modifiers: mods, id: 190, onRelease: { up += 1 }) { down += 1 }
        guard ok, AXIsProcessTrusted() else { check("hotkey press + release", false, "register=\(ok) ax=\(AXIsProcessTrusted())"); return }
        let mon = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .keyUp]) { _ in seen += 1 }
        let src = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_ANSI_J), keyDown: isDown)
            e?.flags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
            e?.post(tap: .cghidEventTap)
            await wait(0.2)
        }
        await wait(0.3)
        if let mon { NSEvent.removeMonitor(mon) }
        print("PRESENT info keyEventsSeen=\(seen)")
        HotKeyCenter.shared.unregister(190...190)
        check("hotkey press + release", down == 1 && up == 1, "down=\(down) up=\(up)")
    }
}
