import AppKit

/// Draws the editor scene. All coordinates are output pixels with a top-left origin (flipped context).
@MainActor
enum Renderer {
    static func render(_ m: EditorModel) -> CGImage? {
        let size = m.outputSize
        let cs: CGColorSpace = {
            if let c = m.base.colorSpace, c.model == .rgb { return c }
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }()
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        drawScene(ctx, m, draft: nil, shadowScale: 1)
        return ctx.makeImage()
    }

    /// shadowScale: device pixels per output pixel (shadows are specified in device space).
    static func drawScene(_ ctx: CGContext, _ m: EditorModel, draft: Annotation?, shadowScale k: CGFloat) {
        let ir = m.imageRect
        let pad = m.padPx
        ctx.saveGState()
        if m.backdrop.enabled {
            let preset = Backdrop.presets[m.backdrop.preset % Backdrop.presets.count]
            let size = m.outputSize
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [preset.a.cgColor, preset.b.cgColor] as CFArray, locations: [0, 1]) {
                ctx.saveGState()
                ctx.clip(to: CGRect(origin: .zero, size: size))
                ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
                ctx.restoreGState()
            }
            let frame = CGRect(x: pad, y: pad, width: ir.width, height: ir.height)
            let r = min(m.backdrop.radius * m.scale, min(ir.width, ir.height) / 2)
            let path = CGPath(roundedRect: frame, cornerWidth: r, cornerHeight: r, transform: nil)
            if m.backdrop.shadow {
                ctx.saveGState()
                ctx.setShadow(offset: CGSize(width: 0, height: -14 * m.scale * k), blur: 44 * m.scale * k, color: NSColor.black.withAlphaComponent(0.42).cgColor)
                ctx.addPath(path)
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fillPath()
                ctx.restoreGState()
            }
            ctx.addPath(path)
            ctx.clip()
        } else {
            ctx.clip(to: CGRect(origin: .zero, size: ir.size))
        }
        ctx.translateBy(x: pad - ir.minX, y: pad - ir.minY)
        drawImage(ctx, m.base, in: m.baseBounds)

        var all = m.annotations
        if let d = draft { all.append(d) }
        for a in all where a.kind != .spotlight { draw(a, ctx, m, k) }

        let spots = all.filter { $0.kind == .spotlight }
        if !spots.isEmpty {
            ctx.saveGState()
            ctx.addRect(ir.insetBy(dx: -2, dy: -2))
            for s in spots {
                let r = s.rect
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(10 * m.scale, r.width / 2), cornerHeight: min(10 * m.scale, r.height / 2), transform: nil))
            }
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            ctx.fillPath(using: .evenOdd)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    static func drawImage(_ ctx: CGContext, _ img: CGImage, in r: CGRect) {
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(origin: .zero, size: r.size))
        ctx.restoreGState()
    }

    static func softShadow(_ ctx: CGContext, _ m: EditorModel, _ k: CGFloat, alpha: CGFloat = 0.3) {
        ctx.setShadow(offset: CGSize(width: 0, height: -1 * m.scale * k), blur: 3 * m.scale * k, color: NSColor.black.withAlphaComponent(alpha).cgColor)
    }

    static func draw(_ a: Annotation, _ ctx: CGContext, _ m: EditorModel, _ k: CGFloat) {
        let c = a.color.cgColor
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch a.kind {
        case .arrow:
            softShadow(ctx, m, k)
            ctx.addPath(arrowPath(a.start, a.end, a.width))
            ctx.setFillColor(c); ctx.setStrokeColor(c); ctx.setLineWidth(a.width * 0.35)
            ctx.drawPath(using: .fillStroke)
        case .line:
            softShadow(ctx, m, k)
            ctx.setStrokeColor(c); ctx.setLineWidth(a.width)
            ctx.move(to: a.start); ctx.addLine(to: a.end); ctx.strokePath()
        case .rect:
            softShadow(ctx, m, k)
            let r = a.rect
            let rad = min(a.width * 1.4, r.width / 2, r.height / 2)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
            ctx.setStrokeColor(c); ctx.setLineWidth(a.width); ctx.strokePath()
        case .oval:
            softShadow(ctx, m, k)
            ctx.setStrokeColor(c); ctx.setLineWidth(a.width); ctx.strokeEllipse(in: a.rect)
        case .pen:
            softShadow(ctx, m, k, alpha: 0.2)
            ctx.addPath(smoothPath(a.points)); ctx.setStrokeColor(c); ctx.setLineWidth(a.width); ctx.strokePath()
        case .highlighter:
            ctx.setBlendMode(.multiply)
            ctx.setLineCap(.square)
            ctx.addPath(smoothPath(a.points))
            ctx.setStrokeColor(a.color.withAlphaComponent(0.42).cgColor)
            ctx.setLineWidth(a.width * 3.4)
            ctx.strokePath()
        case .text:
            drawText(a, ctx)
        case .counter:
            let r = a.width
            let circle = CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2)
            if let tip = a.tip {
                softShadow(ctx, m, k)
                ctx.addPath(arrowPath(a.start, tip, r * 0.3))
                ctx.setFillColor(c); ctx.setStrokeColor(c); ctx.setLineWidth(r * 0.1)
                ctx.drawPath(using: .fillStroke)
            }
            if a.id != m.editingLabelID, let (label, pill, origin) = counterLabel(a) {
                softShadow(ctx, m, k, alpha: 0.3)
                ctx.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
                ctx.setFillColor(c); ctx.fillPath()
                ctx.setShadow(offset: .zero, blur: 0)
                withFlippedNSContext(ctx) { label.draw(at: origin) }
            }
            softShadow(ctx, m, k, alpha: 0.35)
            ctx.setFillColor(c); ctx.fillEllipse(in: circle)
            ctx.setShadow(offset: .zero, blur: 0)
            ctx.setStrokeColor(NSColor.white.cgColor); ctx.setLineWidth(max(1.5, r * 0.12))
            ctx.strokeEllipse(in: circle.insetBy(dx: r * 0.06, dy: r * 0.06))
            let fg = counterForeground(a.color)
            let s = NSAttributedString(string: "\(a.number)", attributes: [.font: roundedFont(r * 1.15, .bold), .foregroundColor: fg])
            withFlippedNSContext(ctx) {
                let sz = s.size()
                s.draw(at: CGPoint(x: a.start.x - sz.width / 2, y: a.start.y - sz.height / 2))
            }
        case .blur:
            if let (img, rr) = m.blurred(a.rect) {
                drawImage(ctx, img, in: rr)
            }
        case .measure:
            drawMeasure(a, ctx, m, k)
        case .spotlight:
            break
        }
        ctx.restoreGState()
    }

    static func counterForeground(_ c: NSColor) -> NSColor {
        c.hexString == "#FFFFFF" || c.hexString == "#FFCC00" ? NSColor(white: 0.1, alpha: 1) : .white
    }

    static func counterLabelFont(_ r: CGFloat) -> NSFont { roundedFont(r, .semibold) }

    /// Label pill that extends to the right of a step number, centred on it.
    static func counterLabel(_ a: Annotation) -> (NSAttributedString, CGRect, CGPoint)? {
        guard !a.text.isEmpty else { return nil }
        let r = a.width
        let s = NSAttributedString(string: a.text, attributes: [.font: counterLabelFont(r), .foregroundColor: counterForeground(a.color)])
        let sz = s.size()
        let h = r * 1.6
        let textX = a.start.x + r * 1.45
        let pill = CGRect(x: a.start.x, y: a.start.y - h / 2, width: textX - a.start.x + sz.width + r * 0.75, height: h)
        return (s, pill, CGPoint(x: textX, y: a.start.y - sz.height / 2))
    }

    static func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let f = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = f.fontDescriptor.withDesign(.rounded), let r = NSFont(descriptor: d, size: size) { return r }
        return f
    }

    static func textAttributes(_ a: Annotation, outline: Bool) -> [NSAttributedString.Key: Any] {
        let font = roundedFont(a.width, .bold)
        if outline {
            let dark = a.color.hexString == "#FFFFFF" || a.color.hexString == "#FFCC00"
            return [.font: font, .strokeColor: dark ? NSColor(white: 0.08, alpha: 0.9) : NSColor.white, .strokeWidth: 18, .foregroundColor: NSColor.clear]
        }
        return [.font: font, .foregroundColor: a.color]
    }

    static func textSize(_ a: Annotation) -> CGSize {
        NSAttributedString(string: a.text, attributes: textAttributes(a, outline: false)).size()
    }

    static func drawText(_ a: Annotation, _ ctx: CGContext) {
        withFlippedNSContext(ctx) {
            NSAttributedString(string: a.text, attributes: textAttributes(a, outline: true)).draw(at: a.start)
            NSAttributedString(string: a.text, attributes: textAttributes(a, outline: false)).draw(at: a.start)
        }
    }

    static func withFlippedNSContext(_ ctx: CGContext, _ body: () -> Void) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
    }

    static func drawMeasure(_ a: Annotation, _ ctx: CGContext, _ m: EditorModel, _ k: CGFloat) {
        let c = a.color.cgColor
        let w = max(1.5 * m.scale, a.width * 0.45)
        let dx = a.end.x - a.start.x, dy = a.end.y - a.start.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return }
        let nx = -dy / len, ny = dx / len
        let t = 7 * m.scale
        softShadow(ctx, m, k)
        ctx.setStrokeColor(c); ctx.setLineWidth(w)
        ctx.move(to: a.start); ctx.addLine(to: a.end)
        for p in [a.start, a.end] {
            ctx.move(to: CGPoint(x: p.x + nx * t, y: p.y + ny * t))
            ctx.addLine(to: CGPoint(x: p.x - nx * t, y: p.y - ny * t))
        }
        ctx.strokePath()
        ctx.setShadow(offset: .zero, blur: 0)
        let label = "\(Int(len.rounded())) px"
        let s = NSAttributedString(string: label, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11 * m.scale, weight: .semibold), .foregroundColor: NSColor.white])
        let sz = s.size()
        let mid = CGPoint(x: (a.start.x + a.end.x) / 2, y: (a.start.y + a.end.y) / 2)
        let bg = CGRect(x: mid.x - sz.width / 2 - 7 * m.scale, y: mid.y - sz.height / 2 - 3 * m.scale, width: sz.width + 14 * m.scale, height: sz.height + 6 * m.scale)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.78).cgColor)
        ctx.addPath(CGPath(roundedRect: bg, cornerWidth: bg.height / 2, cornerHeight: bg.height / 2, transform: nil))
        ctx.fillPath()
        withFlippedNSContext(ctx) { s.draw(at: CGPoint(x: bg.minX + 7 * m.scale, y: bg.minY + 3 * m.scale)) }
    }

    static func arrowPath(_ a: CGPoint, _ b: CGPoint, _ w: CGFloat) -> CGPath {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(hypot(dx, dy), 0.001)
        let ux = dx / len, uy = dy / len, nx = -uy, ny = ux
        let headLen = min(len * 0.6, w * 4.4)
        let headHalf = min(w * 2.3, headLen * 0.7)
        let bx = b.x - ux * headLen, by = b.y - uy * headLen
        let t0 = w * 0.2, t1 = w * 0.6
        let p = CGMutablePath()
        p.move(to: CGPoint(x: a.x + nx * t0, y: a.y + ny * t0))
        p.addLine(to: CGPoint(x: bx + nx * t1, y: by + ny * t1))
        p.addLine(to: CGPoint(x: bx + nx * headHalf, y: by + ny * headHalf))
        p.addLine(to: b)
        p.addLine(to: CGPoint(x: bx - nx * headHalf, y: by - ny * headHalf))
        p.addLine(to: CGPoint(x: bx - nx * t1, y: by - ny * t1))
        p.addLine(to: CGPoint(x: a.x - nx * t0, y: a.y - ny * t0))
        p.closeSubpath()
        return p
    }

    static func smoothPath(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        guard let first = pts.first else { return p }
        p.move(to: first)
        if pts.count < 3 {
            pts.dropFirst().forEach { p.addLine(to: $0) }
            if pts.count == 1 { p.addLine(to: CGPoint(x: first.x + 0.1, y: first.y)) }
            return p
        }
        for i in 1..<pts.count - 1 {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i])
        }
        p.addLine(to: pts[pts.count - 1])
        return p
    }

    static func bounds(of a: Annotation) -> CGRect {
        switch a.kind {
        case .arrow, .line, .measure:
            return CGRect(a.start, a.end).insetBy(dx: -a.width * 2, dy: -a.width * 2)
        case .pen, .highlighter:
            guard let f = a.points.first else { return .null }
            var r = CGRect(origin: f, size: .zero)
            a.points.forEach { r = r.union(CGRect(origin: $0, size: .zero)) }
            let pad = a.kind == .highlighter ? a.width * 1.8 : a.width
            return r.insetBy(dx: -pad, dy: -pad)
        case .text:
            return CGRect(origin: a.start, size: textSize(a))
        case .counter:
            var b = CGRect(x: a.start.x - a.width, y: a.start.y - a.width, width: a.width * 2, height: a.width * 2)
            if let (_, pill, _) = counterLabel(a) { b = b.union(pill) }
            if let t = a.tip { b = b.union(CGRect(origin: t, size: .zero).insetBy(dx: -a.width * 0.6, dy: -a.width * 0.6)) }
            return b
        case .rect, .oval, .blur, .spotlight:
            return a.rect.insetBy(dx: -a.width / 2, dy: -a.width / 2)
        }
    }

    static func hitTest(_ a: Annotation, _ p: CGPoint, tolerance: CGFloat) -> Bool {
        switch a.kind {
        case .arrow, .line, .measure:
            return distance(p, a.start, a.end) <= a.width + tolerance
        case .pen, .highlighter:
            let w = (a.kind == .highlighter ? a.width * 1.7 : a.width) + tolerance
            return zip(a.points, a.points.dropFirst()).contains { distance(p, $0, $1) <= w } || (a.points.count == 1 && hypot(p.x - a.points[0].x, p.y - a.points[0].y) <= w)
        case .rect, .oval:
            let outer = a.rect.insetBy(dx: -a.width - tolerance, dy: -a.width - tolerance)
            let inner = a.rect.insetBy(dx: a.width + tolerance, dy: a.width + tolerance)
            return outer.contains(p) && (inner.isNull || !inner.contains(p))
        case .counter:
            let r = a.width
            if hypot(p.x - a.start.x, p.y - a.start.y) <= r + tolerance { return true }
            if let (_, pill, _) = counterLabel(a), pill.insetBy(dx: -tolerance, dy: -tolerance).contains(p) { return true }
            if let t = a.tip, distance(p, a.start, t) <= r * 0.6 + tolerance { return true }
            return false
        default:
            return bounds(of: a).insetBy(dx: -tolerance, dy: -tolerance).contains(p)
        }
    }

    static func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let l2 = dx * dx + dy * dy
        guard l2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }
}
