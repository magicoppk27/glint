import AppKit
import SwiftUI
import Carbon.HIToolbox

/// Development aid: `GLINT_SNAPSHOT=/some/dir Glint` renders the home and editor windows to PNGs and quits.
@MainActor
enum DebugSnapshot {
    /// GLINT_STITCH_TEST=dir: slices a synthetic tall page (with a sticky header) into frames,
    /// stitches them back and writes stitched.png plus a pass/fail line to stdout.
    static func stitchTest(into dir: String) {
        let W = 800, H = 4000, frameH = 600, header = 70
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        Renderer.withFlippedNSContext(ctx) {
            for i in 0..<(H / 40) {
                let y = CGFloat(i * 40)
                NSColor(hue: CGFloat(i % 17) / 17, saturation: 0.5, brightness: 0.9, alpha: 1).setFill()
                NSRect(x: 20 + CGFloat((i * 37) % 300), y: y + 8, width: 60 + CGFloat((i * 53) % 200), height: 24).fill()
                NSAttributedString(string: "Row \(i) — the quick brown fox \(i * 7)", attributes: [.font: NSFont.systemFont(ofSize: 18)]).draw(at: CGPoint(x: 420, y: y + 8))
            }
        }
        let page = ctx.makeImage()!
        func frame(at off: Int) -> CGImage {
            let f = CGContext(data: nil, width: W, height: frameH, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            // content scrolled by `off`, shown below a fixed header
            let crop = page.cropping(to: CGRect(x: 0, y: off, width: W, height: frameH))!
            f.draw(crop, in: CGRect(x: 0, y: 0, width: W, height: frameH))
            f.setFillColor(NSColor(hex: 0x312E81).cgColor)
            f.fill(CGRect(x: 0, y: frameH - header, width: W, height: header))
            return f.makeImage()!
        }
        let horizontalMode = ProcessInfo.processInfo.environment["GLINT_STITCH_H"] != nil
        if horizontalMode {
            // Orientation check: a red pixel on the right edge must end up on the bottom row.
            let t = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            t.setFillColor(NSColor.white.cgColor); t.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
            t.setFillColor(NSColor.red.cgColor); t.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
            let rot = rotateQuarter(t.makeImage()!, clockwise: true)!
            let rep = NSBitmapImageRep(cgImage: rot)
            print("STITCH-H orientation rightEdgeToBottom=\((rep.colorAt(x: 0, y: 1)?.redComponent ?? 0) > 0.9 && (rep.colorAt(x: 0, y: 1)?.greenComponent ?? 1) < 0.1)")
        }
        Task {
            let st = Stitcher()
            var off = 0
            var offsets: [Int] = []
            while off + frameH <= H { offsets.append(off); off += [97, 120, 0, 143, 61][offsets.count % 5] }
            var img: CGImage?
            var page = page
            if horizontalMode {
                // Same content turned sideways: fixed column on the left, new content arriving on the right.
                for o in offsets { _ = await st.add(rotateQuarter(rotateQuarter(frame(at: o), clockwise: false)!, clockwise: true)!) }
                img = await st.compose().flatMap { rotateQuarter($0, clockwise: false) }
                page = rotateQuarter(page, clockwise: false)!
                if let i = img, let back = rotateQuarter(i, clockwise: true) { img = back }
                page = rotateQuarter(page, clockwise: true)!
                print("STITCH-H wideOutput=\((await st.compose().flatMap { rotateQuarter($0, clockwise: false) }).map { "\($0.width)x\($0.height)" } ?? "nil")")
            } else {
                for o in offsets { _ = await st.add(frame(at: o)) }
                img = await st.compose()
            }
            let expected = frameH + offsets.last!
            print("STITCH frames=\(offsets.count) height=\(img?.height ?? -1) expected=\(expected) \(img?.height == expected ? "PASS" : "FAIL")")
            if let img, img.height == expected {
                let a = NSBitmapImageRep(cgImage: img), b = NSBitmapImageRep(cgImage: page)
                var bad = 0
                for y in stride(from: header, to: expected, by: 1) {
                    for x in stride(from: 0, to: W, by: 7) {
                        let ca = a.colorAt(x: x, y: y)!, cb = b.colorAt(x: x, y: y)!
                        if abs(ca.redComponent - cb.redComponent) + abs(ca.greenComponent - cb.greenComponent) + abs(ca.blueComponent - cb.blueComponent) > 0.03 { bad += 1; break }
                    }
                }
                print("STITCH rowsMismatched=\(bad)")
            }
            if let img { try? ImageStore.write(img, scale: 1, to: URL(fileURLWithPath: "\(dir)/stitched.png")) }
            try? ImageStore.write(page, scale: 1, to: URL(fileURLWithPath: "\(dir)/page.png"))
            NSApp.terminate(nil)
        }
    }

    static func hotkeyTest() {
        let st = HotkeyStore.shared
        let custom = Hotkey(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey))
        let e1 = st.set(custom, for: .capture(.area))
        let reg = !st.failed.contains("area")
        let e2 = st.set(custom, for: .capture(.fullscreen))
        let e3 = st.set(Hotkey(keyCode: UInt32(kVK_ANSI_3), modifiers: UInt32(cmdKey | shiftKey)), for: .capture(.window))
        st.set(nil, for: .capture(.text))
        let cleared = st.hotkey(.capture(.text)) == nil
        print("HKTEST set=\(e1 == nil) label=\(st.label(.capture(.area))) registered=\(reg) conflict=\(e2 ?? "nil") reserved=\(e3 ?? "nil") cleared=\(cleared)")
        st.resetAll()
        print("HKTEST afterReset area=\(st.label(.capture(.area))) text=\(st.label(.capture(.text))) customized=\(st.isCustomized)")
        NSApp.terminate(nil)
    }

    static func run(into dir: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            let w = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 620), styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = NSHostingView(rootView: ShortcutSettings().frame(width: 600, height: 620))
            w.orderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                save(w, "\(dir)/shortcuts.png")
                print("HOTKEYS failed=\(HotkeyStore.shared.failed.sorted()) " + HotkeyAction.all.map { "\($0.id)=\(HotkeyStore.shared.label($0))" }.joined(separator: " "))
                w.orderOut(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if let home = NSApp.windows.first(where: { $0.title == "Glint" && $0.isVisible }) { save(home, "\(dir)/home.png") }
            let sample = ProcessInfo.processInfo.environment["GLINT_SAMPLE"] ?? ""
            guard let shot = ImageStore.load(url: URL(fileURLWithPath: sample)) else { NSApp.terminate(nil); return }
            EditorWindowController.show(shot)
            guard let wc = EditorWindowController.open.last else { return }
            let m = wc.model
            let w = CGFloat(m.base.width), h = CGFloat(m.base.height)
            m.annotations = [
                Annotation(kind: .arrow, start: CGPoint(x: w * 0.12, y: h * 0.85), end: CGPoint(x: w * 0.4, y: h * 0.55), color: palette[0], width: m.strokeWidth),
                Annotation(kind: .rect, start: CGPoint(x: w * 0.55, y: h * 0.3), end: CGPoint(x: w * 0.9, y: h * 0.6), color: palette[0], width: m.strokeWidth),
                Annotation(kind: .counter, start: CGPoint(x: w * 0.55 + m.counterRadius, y: h * 0.3 - m.strokeWidth / 2 - 3 * m.scale - m.counterRadius), end: .zero, color: palette[0], width: m.counterRadius, text: "Step 3", number: 3),
                Annotation(kind: .counter, start: CGPoint(x: w * 0.12, y: h * 0.62), end: .zero, color: palette[4], width: m.counterRadius, text: "Open Settings", number: 1),
                Annotation(kind: .counter, start: CGPoint(x: w * 0.12, y: h * 0.74), end: .zero, color: palette[5], width: m.counterRadius, text: "Glint purple", number: 4),
                Annotation(kind: .magnifier, start: CGPoint(x: w * 0.3, y: h * 0.86), end: CGPoint(x: w * 0.3 + w * 0.12, y: h * 0.86), color: palette[0], width: 2.2),
                Annotation(kind: .counter, start: CGPoint(x: w * 0.2, y: h * 0.3), end: .zero, color: palette[0], width: m.counterRadius, text: "Click here first", number: 2, tip: CGPoint(x: w * 0.36, y: h * 0.48)),
                Annotation(kind: .text, start: CGPoint(x: w * 0.08, y: h * 0.08), end: .zero, color: palette[1], width: m.fontSize, text: "Look here!"),
                Annotation(kind: .blur, start: CGPoint(x: w * 0.6, y: h * 0.65), end: CGPoint(x: w * 0.9, y: h * 0.9), color: palette[0], width: 0),
                Annotation(kind: .measure, start: CGPoint(x: w * 0.1, y: h * 0.95), end: CGPoint(x: w * 0.5, y: h * 0.95), color: palette[3], width: m.strokeWidth),
            ]
            m.hover.color = m.color(at: CGPoint(x: w * 0.5, y: h * 0.5))
            m.showCopiedBadge = true
            m.backdrop.enabled = ProcessInfo.processInfo.environment["GLINT_BACKDROP"] != nil
            if let ws = ProcessInfo.processInfo.environment["GLINT_EDITOR_WIDTH"], let wv = Double(ws), let win = wc.window {
                var f = win.frame; f.size.width = CGFloat(wv); win.setFrame(f, display: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if let win = wc.window { save(win, "\(dir)/editor.png") }
                if let img = m.render() { try? ImageStore.write(img, scale: m.scale, to: URL(fileURLWithPath: "\(dir)/export.png")) }
                ThumbnailController.show(shot)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    if let p = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible && $0.frame.width < 400 }) { save(p, "\(dir)/thumb.png") }
                    NSApp.terminate(nil)
                }
            }
        }
    }

    static func save(_ w: NSWindow, _ path: String) {
        guard let v = w.contentView?.superview ?? w.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        v.cacheDisplay(in: v.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}
