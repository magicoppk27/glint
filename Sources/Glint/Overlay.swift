import AppKit

/// Full-screen "frozen" overlay used to pick an area or a window.
@MainActor
final class SelectionOverlay {
    enum Mode { case area, window, text, color, scroll }
    enum Outcome {
        case area(Frozen, CGRect, CGRect) // frozen, pixel rect (top-left), local point rect (bottom-left)
        case window(CGWindowID)
        case color(NSColor)
        case cancelled
    }

    static var active: SelectionOverlay?

    let mode: Mode
    let windows: [WinInfo]
    private let completion: (Outcome) -> Void
    private var panels: [OverlayWindow] = []
    var views: [OverlayView] = []

    static func present(frozen: [Frozen], mode: Mode, windows: [WinInfo], completion: @escaping (Outcome) -> Void) {
        let o = SelectionOverlay(mode: mode, windows: windows, completion: completion)
        active = o
        o.show(frozen)
    }

    static func pixelRect(for local: CGRect, screenHeight: CGFloat, scale: CGFloat) -> CGRect {
        CGRect(x: local.minX * scale, y: (screenHeight - local.maxY) * scale,
               width: local.width * scale, height: local.height * scale).integral
    }

    private init(mode: Mode, windows: [WinInfo], completion: @escaping (Outcome) -> Void) {
        self.mode = mode
        self.windows = windows
        self.completion = completion
    }

    private func show(_ frozen: [Frozen]) {
        for f in frozen {
            let w = OverlayWindow(contentRect: f.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.identifier = GlintChrome.id
            w.level = .screenSaver
            w.isOpaque = true
            w.backgroundColor = .black
            w.hasShadow = false
            w.isReleasedWhenClosed = false
            w.acceptsMouseMovedEvents = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            let container = NSView(frame: CGRect(origin: .zero, size: f.screen.frame.size))
            container.wantsLayer = true
            container.layer?.contents = f.image
            container.layer?.contentsGravity = .resize
            let v = OverlayView(frame: container.bounds, frozen: f, owner: self)
            v.autoresizingMask = [.width, .height]
            container.addSubview(v)
            w.contentView = container
            w.setFrame(f.screen.frame, display: false)
            panels.append(w)
            views.append(v)
            w.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        let idx = panels.firstIndex { NSMouseInRect(mouse, $0.frame, false) } ?? 0
        if panels.indices.contains(idx) {
            panels[idx].makeKeyAndOrderFront(nil)
            panels[idx].makeFirstResponder(views[idx])
            views[idx].prime(at: mouse)
        }
        NSCursor.crosshair.set()
    }

    func finish(_ outcome: Outcome) {
        guard SelectionOverlay.active === self else { return }
        SelectionOverlay.active = nil
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        completion(outcome)
    }

    func redrawAll() { views.forEach { $0.needsDisplay = true } }

    func window(at global: CGPoint) -> WinInfo? { windows.first { $0.frame.contains(global) } }
}

final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    let frozen: Frozen
    weak var owner: SelectionOverlay?

    fileprivate(set) var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var dragEnd: CGPoint?
    fileprivate(set) var hovered: (info: WinInfo, rect: CGRect)?
    private lazy var rep = NSBitmapImageRep(cgImage: frozen.image)

    init(frame: CGRect, frozen: Frozen, owner: SelectionOverlay) {
        self.frozen = frozen
        self.owner = owner
        super.init(frame: frame)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var sf: CGRect { frozen.screen.frame }
    private var selection: CGRect? {
        guard let s = dragStart, let e = dragEnd else { return nil }
        return CGRect(s, e).intersection(bounds)
    }

    func prime(at global: CGPoint) {
        update(local: CGPoint(x: global.x - sf.minX, y: global.y - sf.minY))
    }

    private func update(local p: CGPoint) {
        // Only this screen (and one the pointer just left) needs redrawing — not every display.
        owner?.views.forEach { v in
            if v !== self, v.mouse != nil || v.hovered != nil { v.clearMouse(); v.needsDisplay = true }
        }
        mouse = p
        let g = CGPoint(x: p.x + sf.minX, y: p.y + sf.minY)
        if owner?.mode != .color, owner?.mode != .area, let w = owner?.window(at: g) {
            let r = w.frame.offsetBy(dx: -sf.minX, dy: -sf.minY).intersection(bounds)
            hovered = r.isNull ? nil : (w, r)
        } else {
            hovered = nil
        }
        needsDisplay = true
    }

    func clearMouse() { mouse = nil; hovered = nil }

    // MARK: Events

    override func mouseMoved(with event: NSEvent) {
        update(local: convert(event.locationInWindow, from: nil))
        NSCursor.crosshair.set()
    }

    override func mouseEntered(with event: NSEvent) { window?.makeKey(); window?.makeFirstResponder(self) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if owner?.mode == .color {
            if let c = color(at: p) { owner?.finish(.color(c)) }
            return
        }
        dragStart = p
        dragEnd = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard owner?.mode != .window, owner?.mode != .color, let s = dragStart else { return }
        var p = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains(.shift) {
            let side = max(abs(p.x - s.x), abs(p.y - s.y))
            p = CGPoint(x: s.x + (p.x >= s.x ? side : -side), y: s.y + (p.y >= s.y ? side : -side))
        }
        dragEnd = p
        mouse = p
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStart = nil; dragEnd = nil; owner?.redrawAll() }
        if let sel = selection, sel.width >= 4, sel.height >= 4 {
            finishArea(sel)
            return
        }
        guard let h = hovered else { return }
        if owner?.mode == .text || owner?.mode == .scroll { finishArea(h.rect) } else { owner?.finish(.window(h.info.id)) }
    }

    override func rightMouseDown(with event: NSEvent) { owner?.finish(.cancelled) }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: owner?.finish(.cancelled) // esc
        default:
            if owner?.mode == .color, event.charactersIgnoringModifiers?.lowercased() == "c", let m = mouse, let c = color(at: m) {
                owner?.finish(.color(c))
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private func finishArea(_ r: CGRect) {
        let local = r.integral
        let px = SelectionOverlay.pixelRect(for: local, screenHeight: bounds.height, scale: frozen.scale)
        owner?.finish(.area(frozen, px, local))
    }

    private func color(at p: CGPoint) -> NSColor? {
        let x = Int(p.x * frozen.scale), y = Int((bounds.height - p.y) * frozen.scale)
        guard x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return nil }
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let sel = selection
        let focus: CGRect? = sel ?? (dragStart == nil ? hovered?.rect : nil)

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.42).cgColor)
        if let f = focus {
            ctx.addRect(bounds); ctx.addRect(f)
            ctx.fillPath(using: .evenOdd)
        } else {
            ctx.fill(bounds)
        }

        if let f = focus {
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(sel == nil ? 0.7 : 0.95).cgColor)
            ctx.setLineWidth(1)
            if sel == nil { ctx.setLineDash(phase: 0, lengths: [5, 4]) }
            ctx.stroke(f.insetBy(dx: -0.5, dy: -0.5))
            ctx.setLineDash(phase: 0, lengths: [])
            if sel != nil { drawHandles(ctx, f) }
            let s = frozen.scale
            var label = "\(Int((f.width * s).rounded())) × \(Int((f.height * s).rounded()))"
            if sel == nil, let h = hovered { label = "\(h.info.app)  ·  " + label }
            drawPill(label, below: f)
        }

        if let m = mouse {
            if dragStart == nil {
                ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
                ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: 0, y: m.y.rounded() + 0.5)); ctx.addLine(to: CGPoint(x: bounds.maxX, y: m.y.rounded() + 0.5))
                ctx.move(to: CGPoint(x: m.x.rounded() + 0.5, y: 0)); ctx.addLine(to: CGPoint(x: m.x.rounded() + 0.5, y: bounds.maxY))
                ctx.strokePath()
            }
            if owner?.mode == .color { drawLoupe(ctx, at: m) }
            drawHint()
        }
    }

    private func drawHandles(_ ctx: CGContext, _ r: CGRect) {
        let pts = [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        for p in pts {
            let h = CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.addPath(CGPath(roundedRect: h, cornerWidth: 2, cornerHeight: 2, transform: nil))
            ctx.fillPath()
        }
    }

    private func pillAttrs(_ size: CGFloat = 12) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold), .foregroundColor: NSColor.white]
    }

    private func drawPill(_ text: String, below r: CGRect) {
        let s = NSAttributedString(string: text, attributes: pillAttrs())
        let sz = s.size()
        var o = CGPoint(x: r.minX, y: r.minY - sz.height - 14)
        if o.y < 6 { o.y = r.minY + 8; o.x = r.minX + 8 }
        o.x = min(max(6, o.x), bounds.maxX - sz.width - 18)
        let bg = CGRect(x: o.x, y: o.y, width: sz.width + 14, height: sz.height + 6)
        NSColor.black.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: bg, xRadius: bg.height / 2, yRadius: bg.height / 2).fill()
        s.draw(at: CGPoint(x: bg.minX + 7, y: bg.minY + 3))
    }

    private func drawHint() {
        let text: String
        switch owner?.mode {
        case .window: text = "Click a window to capture   ·   Esc to cancel"
        case .text: text = "Drag over text or click a window   ·   Esc to cancel"
        case .scroll: text = "Select the area to scroll, or click a window   ·   Esc to cancel"
        case .color: text = "Click any pixel to copy its color   ·   Esc to cancel"
        default: text = "Drag to select an area  ·  ⇧ square  ·  Esc cancel"
        }
        let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .medium), .foregroundColor: NSColor.white.withAlphaComponent(0.92)])
        let sz = s.size()
        let bg = CGRect(x: (bounds.width - sz.width) / 2 - 16, y: 36, width: sz.width + 32, height: sz.height + 14)
        NSColor.black.withAlphaComponent(0.62).setFill()
        NSBezierPath(roundedRect: bg, xRadius: bg.height / 2, yRadius: bg.height / 2).fill()
        NSColor.white.withAlphaComponent(0.12).setStroke()
        NSBezierPath(roundedRect: bg.insetBy(dx: 0.5, dy: 0.5), xRadius: bg.height / 2, yRadius: bg.height / 2).stroke()
        s.draw(at: CGPoint(x: bg.minX + 16, y: bg.minY + 7))
    }

    private func drawLoupe(_ ctx: CGContext, at m: CGPoint) {
        let n = 15, cell: CGFloat = 8
        let size = CGFloat(n) * cell
        var o = CGPoint(x: m.x + 28, y: m.y - 28 - size)
        if o.x + size > bounds.maxX - 8 { o.x = m.x - 28 - size }
        if o.y < 70 { o.y = m.y + 28 }
        let rect = CGRect(origin: o, size: CGSize(width: size, height: size))
        let s = frozen.scale
        let px = Int(m.x * s), py = Int((bounds.height - m.y) * s)
        let src = CGRect(x: px - n / 2, y: py - n / 2, width: n, height: n)
        let imgBounds = CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height)
        let inter = src.intersection(imgBounds)

        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 14, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillEllipse(in: rect)
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addEllipse(in: rect); ctx.clip()
        if !inter.isNull, let crop = frozen.image.cropping(to: inter) {
            let dest = CGRect(x: rect.minX + (inter.minX - src.minX) * cell,
                              y: rect.maxY - (inter.maxY - src.minY) * cell,
                              width: inter.width * cell, height: inter.height * cell)
            ctx.interpolationQuality = .none
            ctx.draw(crop, in: dest)
        }
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
        ctx.setLineWidth(0.5)
        for i in 1..<n {
            let d = CGFloat(i) * cell
            ctx.move(to: CGPoint(x: rect.minX + d, y: rect.minY)); ctx.addLine(to: CGPoint(x: rect.minX + d, y: rect.maxY))
            ctx.move(to: CGPoint(x: rect.minX, y: rect.minY + d)); ctx.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + d))
        }
        ctx.strokePath()
        let c = CGRect(x: rect.minX + CGFloat(n / 2) * cell, y: rect.minY + CGFloat(n / 2) * cell, width: cell, height: cell)
        ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.6).cgColor); ctx.setLineWidth(3); ctx.stroke(c)
        ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(1.5); ctx.stroke(c)
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: rect.insetBy(dx: 1, dy: 1))

        guard let color = color(at: m) else { return }
        let label = NSAttributedString(string: "\(color.hexString)   \(px), \(py)", attributes: pillAttrs(11))
        let sz = label.size()
        let bg = CGRect(x: rect.midX - (sz.width + 30) / 2, y: rect.minY - sz.height - 14, width: sz.width + 30, height: sz.height + 7)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: bg, xRadius: bg.height / 2, yRadius: bg.height / 2).fill()
        let sw = CGRect(x: bg.minX + 7, y: bg.midY - 5, width: 10, height: 10)
        color.setFill(); NSBezierPath(ovalIn: sw).fill()
        NSColor.white.withAlphaComponent(0.6).setStroke(); NSBezierPath(ovalIn: sw).stroke()
        label.draw(at: CGPoint(x: sw.maxX + 6, y: bg.minY + 3.5))
    }
}
