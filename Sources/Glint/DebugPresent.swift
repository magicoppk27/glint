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
            await lensTest(dir)
            await drawTest(dir)
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

    // MARK: Zoom Lens

    static func lensTest(_ dir: String) async {
        let f = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let mid = ZoomLens.crop(mouse: CGPoint(x: 500, y: 250), display: f, lens: 200, zoom: 2)
        let corner = ZoomLens.crop(mouse: CGPoint(x: 0, y: 0), display: f, lens: 200, zoom: 2)
        let second = ZoomLens.crop(mouse: CGPoint(x: 1500, y: 250), display: f.offsetBy(dx: 1000, dy: 0), lens: 200, zoom: 2)
        check("lens crop math", mid == CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.2) && corner.origin == .zero && second == mid,
              "\(mid) \(corner) \(second)")

        let lens = ZoomLens.shared
        lens.keyDown(); await wait(0.05); lens.keyUp()
        await wait(1.5)
        check("lens tap opens", lens.isShowing && Presenter.shared.isOn(.lens))
        check("lens receives frames", lens.framesShown > 10, "\(lens.framesShown) frames in 1.5 s")
        let panel = NSApp.windows.first { $0.identifier == GlintChrome.id && $0.sharingType == .none && $0.isVisible }
        check("lens leaves itself out", panel.map { lens.excludedWindowIDs.contains(CGWindowID($0.windowNumber)) } ?? false,
              "excluded=\(lens.excludedWindowIDs)")
        if let img = lens.snapshot() {
            let rep = NSBitmapImageRep(cgImage: img)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/lens-view.png"))
            check("lens snapshot", img.width > 50, "\(img.width)x\(img.height) px")
        } else { check("lens snapshot", false) }
        let before = Prefs.d.object(forKey: "lensZoom")
        Prefs.d.set(4.0, forKey: "lensZoom"); await wait(0.1)
        Prefs.d.set(before, forKey: "lensZoom")
        lens.keyDown(); await wait(0.05); lens.keyUp()
        await wait(0.2)
        check("lens second tap closes", !lens.isShowing && !Presenter.shared.isOn(.lens))

        lens.keyDown(); await wait(0.6)
        let heldOpen = lens.isShowing
        lens.keyUp(); await wait(0.2)
        check("lens hold peeks, release closes", heldOpen && !lens.isShowing)
    }

    // MARK: Draw on screen

    static func drawTest(_ dir: String) async {
        let keys = ["drawTool", "drawColor", "drawSize"]
        let saved = keys.map { Prefs.d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { Prefs.d.set(v, forKey: k) } }

        Presenter.shared.set(.draw, true)
        await wait(0.3)
        let d = ScreenDraw.shared
        guard let m = d.model, let panel = NSApp.windows.first(where: { $0 is DrawPanel && $0.isVisible }),
              let canvas = panel.contentView as? CanvasView, let screen = panel.screen else {
            check("draw opens", false); return
        }
        check("draw opens", panel.frame == screen.frame && panel.isKeyWindow && panel.identifier != GlintChrome.id,
              "key=\(panel.isKeyWindow) frame=\(panel.frame)")
        let toolbar = NSApp.windows.first { $0.identifier == GlintChrome.id && $0.contentView is NSHostingView<DrawToolbar> }
        check("draw toolbar is chrome", toolbar?.isVisible == true && (toolbar?.frame.width ?? 0) > 600, "\(toolbar?.frame ?? .zero)")
        if let toolbar { DebugSnapshot.save(toolbar, "\(dir)/draw-toolbar.png") }

        func mouse(_ type: NSEvent.EventType, _ p: CGPoint, shift: Bool = false) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: p.x, y: panel.frame.height - p.y), modifierFlags: shift ? .shift : [],
                               timestamp: 0, windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        func drag(_ tool: Tool, _ a: CGPoint, _ b: CGPoint) {
            m.tool = tool
            canvas.mouseDown(with: mouse(.leftMouseDown, a))
            for i in 1...8 { let t = CGFloat(i) / 8; canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))) }
            canvas.mouseUp(with: mouse(.leftMouseUp, b))
        }
        // Points in top-left view coordinates, away from the toolbar at the bottom.
        let o = CGPoint(x: screen.frame.width * 0.2, y: screen.frame.height * 0.2)
        m.colorIndex = 0
        drag(.arrow, o, CGPoint(x: o.x + 300, y: o.y + 160))
        drag(.pen, CGPoint(x: o.x, y: o.y + 260), CGPoint(x: o.x + 260, y: o.y + 300))
        m.colorIndex = 5
        drag(.stepBox, CGPoint(x: o.x + 380, y: o.y + 60), CGPoint(x: o.x + 620, y: o.y + 220))
        canvas.commitText()
        let kinds = m.annotations.map { "\($0.kind)" }
        check("draw tools make shapes", kinds == ["arrow", "pen", "rect", "counter"], "\(kinds)")
        if let a = m.annotations.first {
            check("draw maps points to pixels", abs(a.start.x - o.x * m.scale) < 1 && abs(a.start.y - o.y * m.scale) < 1,
                  "\(a.start) vs \(o) × \(m.scale)")
        }
        canvas.display()
        await wait(0.2)

        // The drawing is in Glint's captures; the toolbar is not.
        if let f = try? await CaptureService.shared.freeze([screen]).first {
            let s = f.scale
            let crop = CGRect(x: (o.x - 40) * s, y: (o.y - 70) * s, width: 760 * s, height: 420 * s).integral
            if let img = f.image.cropping(to: crop) {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(dir)/draw-captured.png"))
            }
            let rep = NSBitmapImageRep(cgImage: f.image)
            let mid = CGPoint(x: (o.x + 150) * s, y: (o.y + 80) * s) // on the arrow's shaft
            let c = rep.colorAt(x: Int(mid.x), y: Int(mid.y))?.usingColorSpace(.sRGB)
            check("drawing appears in captures", (c?.redComponent ?? 0) > 0.8 && (c?.greenComponent ?? 1) < 0.4, "\(c?.hexString ?? "nil")")
        } else { check("drawing appears in captures", false, "no capture") }

        m.undo()
        check("draw undo (box + step is one step)", m.annotations.count == 2)
        m.clearAll()
        check("draw clear", m.annotations.isEmpty)
        d.setClickThrough(true)
        check("draw click-through", panel.ignoresMouseEvents)
        d.setClickThrough(false)

        let esc = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                                   context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        m.selectedID = nil
        canvas.keyDown(with: esc)
        await wait(0.1)
        check("esc stops drawing", !d.isShowing && !Presenter.shared.isOn(.draw) && toolbar?.isVisible == false)
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
