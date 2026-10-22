import AppKit
import Combine
import SwiftUI

struct CanvasInsets {
    static let top: CGFloat = 84, left: CGFloat = 78, right: CGFloat = 28, bottom: CGFloat = 28
}

final class CanvasView: NSView, NSTextFieldDelegate {
    let model: EditorModel
    private var bag: AnyCancellable?
    private var draft: Annotation?
    private var dragOrigin: CGPoint?
    private var moving: (id: UUID, last: CGPoint, didCheckpoint: Bool)?
    private var textField: NSTextField?
    private var textOrigin: CGPoint = .zero
    private var lastTool: Tool?
    private var counterDrag: (id: UUID, origin: CGPoint)?

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        bag = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                self.needsDisplay = true
                if self.lastTool != self.model.tool {
                    self.lastTool = self.model.tool
                    self.commitText()
                    self.window?.invalidateCursorRects(for: self)
                }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { self.window?.makeFirstResponder(self) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    private func updateHover(_ event: NSEvent) {
        let p = toImage(convert(event.locationInWindow, from: nil))
        let c = model.imageRect.contains(p) ? model.color(at: p) : nil
        if model.hover.color != c { model.hover.color = c }
        model.hover.point = CGPoint(x: Int(p.x), y: Int(p.y))
    }

    override func mouseMoved(with event: NSEvent) { updateHover(event) }
    override func mouseExited(with event: NSEvent) { model.hover.color = nil }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: model.tool == .select ? .arrow : (model.tool == .text ? .iBeam : (model.tool == .picker ? .dragCopy : .crosshair)))
    }

    // MARK: Geometry

    private var fit: (zoom: CGFloat, origin: CGPoint) {
        let out = model.outputSize
        let aw = bounds.width - CanvasInsets.left - CanvasInsets.right
        let ah = bounds.height - CanvasInsets.top - CanvasInsets.bottom
        let z = max(0.02, min(aw / out.width, ah / out.height, 1 / model.scale))
        let origin = CGPoint(x: CanvasInsets.left + (aw - out.width * z) / 2, y: CanvasInsets.top + (ah - out.height * z) / 2)
        return (z, origin)
    }

    private func toImage(_ p: CGPoint) -> CGPoint {
        let f = fit
        let ir = model.imageRect
        return CGPoint(x: (p.x - f.origin.x) / f.zoom - model.padPx + ir.minX,
                       y: (p.y - f.origin.y) / f.zoom - model.padPx + ir.minY)
    }

    private func toView(_ p: CGPoint) -> CGPoint {
        let f = fit
        let ir = model.imageRect
        return CGPoint(x: (p.x - ir.minX + model.padPx) * f.zoom + f.origin.x,
                       y: (p.y - ir.minY + model.padPx) * f.zoom + f.origin.y)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let f = fit
        let out = model.outputSize
        let backing = window?.backingScaleFactor ?? 2
        ctx.saveGState()
        ctx.translateBy(x: f.origin.x, y: f.origin.y)
        ctx.scaleBy(x: f.zoom, y: f.zoom)
        ctx.interpolationQuality = .high

        if !model.backdrop.enabled {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(CGRect(origin: .zero, size: out))
            ctx.restoreGState()
        }
        Renderer.drawScene(ctx, model, draft: draft, shadowScale: f.zoom * backing)

        // Editing overlays, in image coordinates
        let ir = model.imageRect
        ctx.translateBy(x: model.padPx - ir.minX, y: model.padPx - ir.minY)
        let hair = 1 / f.zoom

        if let id = model.selectedID, let a = model.annotations.first(where: { $0.id == id }) {
            let b = Renderer.bounds(of: a).insetBy(dx: -4 * hair, dy: -4 * hair)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5 * hair)
            ctx.setLineDash(phase: 0, lengths: [5 * hair, 3 * hair])
            ctx.addPath(CGPath(roundedRect: b, cornerWidth: 4 * hair, cornerHeight: 4 * hair, transform: nil))
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }

        if model.tool == .crop, let c = model.pendingCrop {
            ctx.saveGState()
            ctx.addRect(ir); ctx.addRect(c)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.5).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            ctx.setLineWidth(hair)
            for i in 1...2 {
                let x = c.minX + c.width * CGFloat(i) / 3, y = c.minY + c.height * CGFloat(i) / 3
                ctx.move(to: CGPoint(x: x, y: c.minY)); ctx.addLine(to: CGPoint(x: x, y: c.maxY))
                ctx.move(to: CGPoint(x: c.minX, y: y)); ctx.addLine(to: CGPoint(x: c.maxX, y: y))
            }
            ctx.strokePath()
            ctx.setStrokeColor(NSColor.white.cgColor)
            ctx.setLineWidth(2 * hair)
            ctx.stroke(c)
            let L = min(18 * hair, c.width / 3, c.height / 3)
            ctx.setLineWidth(4 * hair)
            for (p, sx, sy) in [(CGPoint(x: c.minX, y: c.minY), 1.0, 1.0), (CGPoint(x: c.maxX, y: c.minY), -1.0, 1.0),
                                (CGPoint(x: c.minX, y: c.maxY), 1.0, -1.0), (CGPoint(x: c.maxX, y: c.maxY), -1.0, -1.0)] {
                ctx.move(to: CGPoint(x: p.x + L * sx, y: p.y)); ctx.addLine(to: p); ctx.addLine(to: CGPoint(x: p.x, y: p.y + L * sy))
            }
            ctx.strokePath()
            ctx.restoreGState()
            let label = NSAttributedString(string: "\(Int(c.width)) × \(Int(c.height))", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11 * hair, weight: .semibold), .foregroundColor: NSColor.white])
            let sz = label.size()
            let bg = CGRect(x: c.minX, y: c.minY - sz.height - 12 * hair, width: sz.width + 14 * hair, height: sz.height + 6 * hair)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.75).cgColor)
            ctx.addPath(CGPath(roundedRect: bg, cornerWidth: bg.height / 2, cornerHeight: bg.height / 2, transform: nil)); ctx.fillPath()
            Renderer.withFlippedNSContext(ctx) { label.draw(at: CGPoint(x: bg.minX + 7 * hair, y: bg.minY + 3 * hair)) }
        }
        ctx.restoreGState()
    }

    // MARK: Mouse

    private func constrained(_ s: CGPoint, _ p: CGPoint, square: Bool) -> CGPoint {
        if square {
            let side = max(abs(p.x - s.x), abs(p.y - s.y))
            return CGPoint(x: s.x + (p.x >= s.x ? side : -side), y: s.y + (p.y >= s.y ? side : -side))
        }
        let dx = p.x - s.x, dy = p.y - s.y
        let ang = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
        let len = hypot(dx, dy)
        return CGPoint(x: s.x + cos(ang) * len, y: s.y + sin(ang) * len)
    }

    /// Output area in view coordinates (the image plus any backdrop).
    private var outputRectInView: CGRect {
        let f = fit
        return CGRect(origin: f.origin, size: CGSize(width: model.outputSize.width * f.zoom, height: model.outputSize.height * f.zoom))
    }

    override func mouseDown(with event: NSEvent) {
        let vp = convert(event.locationInWindow, from: nil)
        // The canvas spans the transparent title bar, so it has to move the window itself:
        // the top strip always drags it, and so does empty space around the image with Select.
        if vp.y < 30 || (model.tool == .select && !outputRectInView.contains(vp)) {
            commitText()
            if event.clickCount == 2, vp.y < 30 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
            return
        }
        window?.makeFirstResponder(self)
        let p = toImage(vp)
        commitText()
        let m = model
        switch m.tool {
        case .select:
            let tol = 6 / fit.zoom
            if let a = m.annotations.last(where: { Renderer.hitTest($0, p, tolerance: tol) }) {
                m.selectedID = a.id
                moving = (a.id, p, false)
                if event.clickCount == 2, a.kind == .text { beginText(at: a.start, editing: a) }
                if event.clickCount == 2, a.kind == .counter { moving = nil; beginLabel(a.id) }
            } else {
                m.selectedID = nil
            }
        case .arrow, .line, .rect, .oval, .blur, .spotlight, .measure, .stepBox:
            let kind: Annotation.Kind = [.arrow: .arrow, .line: .line, .rect: .rect, .oval: .oval, .blur: .blur, .spotlight: .spotlight, .measure: .measure, .stepBox: .rect][m.tool]!
            draft = Annotation(kind: kind, start: p, end: p, color: m.color, width: m.strokeWidth)
        case .magnifier:
            // width stores the zoom factor; the lens radius is the drag distance
            draft = Annotation(kind: .magnifier, start: p, end: p, color: m.color, width: m.magnifierZoom)
        case .pen, .highlighter:
            draft = Annotation(kind: m.tool == .pen ? .pen : .highlighter, start: p, end: p, points: [p], color: m.color, width: m.strokeWidth)
        case .text:
            beginText(at: p, editing: nil)
        case .counter:
            // Clicking an existing number edits its label instead of adding a new one.
            if let hit = m.annotations.last(where: { $0.kind == .counter && hypot(p.x - $0.start.x, p.y - $0.start.y) <= $0.width }) {
                beginLabel(hit.id)
                return
            }
            let c = Annotation(kind: .counter, start: p, end: p, color: m.color, width: m.counterRadius, number: m.nextCounter)
            m.add(c)
            counterDrag = (c.id, p)
        case .picker:
            if let c = m.color(at: p) { AppController.copyColor(c, rgb: event.modifierFlags.contains(.shift)) }
        case .crop:
            dragOrigin = p
            m.pendingCrop = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        updateHover(event)
        var p = toImage(convert(event.locationInWindow, from: nil))
        let shift = event.modifierFlags.contains(.shift)
        if let mv = moving, let i = model.annotations.firstIndex(where: { $0.id == mv.id }) {
            if !mv.didCheckpoint { model.checkpoint() }
            model.annotations[i].offset(by: CGSize(width: p.x - mv.last.x, height: p.y - mv.last.y))
            moving = (mv.id, p, true)
            return
        }
        if let cd = counterDrag, let i = model.annotations.firstIndex(where: { $0.id == cd.id }) {
            let r = model.annotations[i].width
            if hypot(p.x - cd.origin.x, p.y - cd.origin.y) > r * 1.6 {
                model.annotations[i].tip = shift ? constrained(cd.origin, p, square: false) : p
            } else {
                model.annotations[i].tip = nil
            }
            return
        }
        if model.tool == .crop, let o = dragOrigin {
            if shift { p = constrained(o, p, square: true) }
            model.pendingCrop = CGRect(o, p).intersection(model.imageRect)
            return
        }
        guard var d = draft else { return }
        switch d.kind {
        case .pen, .highlighter:
            if let last = d.points.last, hypot(p.x - last.x, p.y - last.y) > 1.5 * model.scale {
                if shift, d.kind == .highlighter, let first = d.points.first { d.points = [first, CGPoint(x: p.x, y: first.y)] } else { d.points.append(p) }
            }
        case .arrow, .line, .measure:
            d.end = shift ? constrained(d.start, p, square: false) : p
        case .magnifier:
            d.end = p
        default:
            d.end = shift ? constrained(d.start, p, square: true) : p
        }
        draft = d
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        moving = nil
        dragOrigin = nil
        if let cd = counterDrag {
            counterDrag = nil
            beginLabel(cd.id)
            return
        }
        guard let d = draft else { return }
        draft = nil
        let big: Bool
        switch d.kind {
        case .pen, .highlighter: big = !d.points.isEmpty
        case .arrow, .line, .measure: big = hypot(d.end.x - d.start.x, d.end.y - d.start.y) > 4 * model.scale
        case .magnifier: big = hypot(d.end.x - d.start.x, d.end.y - d.start.y) > 10 * model.scale
        default: big = d.rect.width > 3 * model.scale && d.rect.height > 3 * model.scale
        }
        if big {
            model.add(d)
            if model.tool == .stepBox {
                // The tag sits just above the box's top-left corner, like a folder tab,
                // so it never covers what the box highlights. Too close to the top edge: tuck it inside.
                let r = model.counterRadius
                let gap = d.width / 2 + 3 * model.scale
                var center = CGPoint(x: d.rect.minX + r, y: d.rect.minY - gap - r)
                if center.y - r < model.imageRect.minY {
                    center = CGPoint(x: d.rect.minX + gap + r, y: d.rect.minY + gap + r)
                }
                let c = Annotation(kind: .counter, start: center, end: .zero, color: d.color, width: r, number: model.nextCounter)
                model.annotations.append(c)
                beginLabel(c.id)
            }
        }
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch event.keyCode {
        case 48: model.copyHoverColor(rgb: flags.contains(.shift)); return // tab
        case 51, 117: model.deleteSelected(); return // delete
        case 36, 76: // return
            if model.pendingCrop != nil { model.applyCrop(); return }
        case 53: // esc
            if model.pendingCrop != nil { model.pendingCrop = nil; return }
            if model.selectedID != nil { model.selectedID = nil; return }
            window?.performClose(nil); return
        case 123, 124, 125, 126: // arrows nudge selection
            if let id = model.selectedID, let i = model.annotations.firstIndex(where: { $0.id == id }) {
                let step: CGFloat = (flags.contains(.shift) ? 10 : 1) * model.scale
                let d: CGSize = [123: CGSize(width: -step, height: 0), 124: CGSize(width: step, height: 0), 125: CGSize(width: 0, height: step), 126: CGSize(width: 0, height: -step)][event.keyCode]!
                model.checkpoint()
                model.annotations[i].offset(by: d)
                return
            }
        default: break
        }
        if flags.isEmpty || flags == .shift, let ch = event.charactersIgnoringModifiers?.lowercased().first {
            if let t = Tool.allCases.first(where: { $0.key == ch }) { model.tool = t; return }
            if ch == "k" { model.backdrop.enabled.toggle(); return }
            if let n = Int(String(ch)), (1...8).contains(n) { model.colorIndex = n - 1; return }
        }
        super.keyDown(with: event)
    }

    // MARK: Text

    private func beginText(at p: CGPoint, editing existing: Annotation?) {
        let z = fit.zoom
        let a = existing ?? Annotation(kind: .text, start: p, end: p, color: model.color, width: model.fontSize)
        if let e = existing {
            model.checkpoint()
            model.annotations.removeAll { $0.id == e.id }
        }
        let tf = NSTextField(string: a.text)
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.font = Renderer.roundedFont(a.width * z, .bold)
        tf.textColor = a.color
        tf.placeholderString = "Type…"
        tf.delegate = self
        tf.target = self
        tf.action = #selector(textAction)
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        let vp = toView(a.start)
        tf.frame = CGRect(x: vp.x - 2, y: vp.y, width: 240, height: a.width * z * 1.3)
        addSubview(tf)
        sizeField(tf)
        window?.makeFirstResponder(tf)
        textField = tf
        textOrigin = a.start
        pendingText = a
    }

    private var pendingText: Annotation?
    private var labelID: UUID?

    /// Opens an inline label box to the right of a step number, vertically centred on it.
    private func beginLabel(_ id: UUID) {
        commitText()
        guard let a = model.annotations.first(where: { $0.id == id }) else { return }
        let z = fit.zoom
        let r = a.width * z
        let fg = Renderer.counterForeground(a.color)
        let font = Renderer.counterLabelFont(r)
        let tf = NSTextField(string: "")
        tf.cell = CenteredTextCell(textCell: a.text)
        tf.isEditable = true
        tf.isSelectable = true
        tf.isBordered = false
        tf.drawsBackground = true
        tf.backgroundColor = a.color
        tf.focusRingType = .none
        tf.font = font
        tf.textColor = fg
        tf.placeholderAttributedString = NSAttributedString(string: "Step \(a.number)", attributes: [.font: font, .foregroundColor: fg.withAlphaComponent(0.55)])
        tf.delegate = self
        tf.target = self
        tf.action = #selector(textAction)
        tf.cell?.wraps = false
        tf.cell?.isScrollable = true
        let h = Renderer.counterLabelHeight(r).rounded()
        let vp = toView(a.start)
        tf.frame = CGRect(x: vp.x + r + 3, y: vp.y - h / 2, width: 140, height: h)
        tf.wantsLayer = true
        tf.layer?.cornerRadius = h / 2
        tf.layer?.masksToBounds = true
        addSubview(tf)
        textField = tf
        labelID = id
        model.editingLabelID = id
        sizeField(tf)
        window?.makeFirstResponder(tf)
        needsDisplay = true
    }

    private func sizeField(_ tf: NSTextField) {
        if labelID != nil {
            let text = tf.stringValue.isEmpty ? (tf.placeholderAttributedString?.string ?? "") : tf.stringValue
            let w = NSAttributedString(string: text, attributes: [.font: tf.font as Any]).size().width
            tf.frame.size.width = max(60, w + tf.frame.height * 0.9 + 6)
            return
        }
        let w = max(120, (tf.attributedStringValue.size().width) + 30)
        tf.frame.size.width = w
    }

    func controlTextDidChange(_ obj: Notification) { if let tf = textField { sizeField(tf) } }
    func controlTextDidEndEditing(_ obj: Notification) { commitText() }
    @objc private func textAction() { commitText() }

    func commitText() {
        guard let tf = textField else { return }
        textField = nil
        let s = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = labelID {
            labelID = nil
            model.editingLabelID = nil
            tf.removeFromSuperview()
            if let i = model.annotations.firstIndex(where: { $0.id == id }), model.annotations[i].text != s {
                model.checkpoint()
                model.annotations[i].text = s
            }
            window?.makeFirstResponder(self)
            needsDisplay = true
            return
        }
        guard var a = pendingText else { tf.removeFromSuperview(); return }
        pendingText = nil
        tf.removeFromSuperview()
        if !s.isEmpty {
            a.text = s
            a.start = textOrigin
            model.add(a)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

/// Text cell that centres its text vertically and pads it horizontally (for pill-shaped labels).
final class CenteredTextCell: NSTextFieldCell {
    private func adjusted(_ r: NSRect) -> NSRect {
        let h = cellSize(forBounds: r).height
        let pad = r.height * 0.45
        var out = r.insetBy(dx: pad, dy: 0)
        if h < r.height { out.origin.y += (r.height - h) / 2; out.size.height = h }
        return out
    }
    override func drawingRect(forBounds rect: NSRect) -> NSRect { adjusted(super.drawingRect(forBounds: rect)) }
    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: adjusted(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }
    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText, delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: adjusted(rect), in: controlView, editor: textObj, delegate: delegate, start: selStart, length: selLength)
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> CanvasView { CanvasView(model: model) }
    func updateNSView(_ nsView: CanvasView, context: Context) { nsView.needsDisplay = true }
}
