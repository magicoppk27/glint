// Renders Glint's app icon at 1024×1024. Usage: swift make-icon.swift out.png
import AppKit

let S: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
let cs = CGColorSpace(name: CGColorSpace.displayP3)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
func gradient(_ colors: [CGColor], _ locs: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: locs)!
}

// macOS icon grid: 824pt squircle centred in 1024 canvas
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let radius: CGFloat = 186
let squircle = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: c(0x000000, 0.38))
ctx.addPath(squircle); ctx.setFillColor(c(0x15123A)); ctx.fillPath()
ctx.restoreGState()

// Base: deep indigo gradient
ctx.saveGState()
ctx.addPath(squircle); ctx.clip()
ctx.drawLinearGradient(gradient([c(0x3A2FA8), c(0x1E1760), c(0x0D0B2A)], [0, 0.55, 1]),
                       start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// Aurora glows
ctx.drawRadialGradient(gradient([c(0xB04BF2, 0.85), c(0xB04BF2, 0)], [0, 1]),
                       startCenter: CGPoint(x: 640, y: 600), startRadius: 0, endCenter: CGPoint(x: 640, y: 600), endRadius: 430, options: [])
ctx.drawRadialGradient(gradient([c(0xFF4FA3, 0.55), c(0xFF4FA3, 0)], [0, 1]),
                       startCenter: CGPoint(x: 760, y: 260), startRadius: 0, endCenter: CGPoint(x: 760, y: 260), endRadius: 380, options: [])
ctx.drawRadialGradient(gradient([c(0x38BDF8, 0.45), c(0x38BDF8, 0)], [0, 1]),
                       startCenter: CGPoint(x: 260, y: 820), startRadius: 0, endCenter: CGPoint(x: 260, y: 820), endRadius: 360, options: [])
// Top sheen
ctx.drawLinearGradient(gradient([c(0xFFFFFF, 0.16), c(0xFFFFFF, 0)], [0, 1]),
                       start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: 560), options: [])
ctx.restoreGState()

// Inner edge highlight
ctx.saveGState()
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: radius - 2, cornerHeight: radius - 2, transform: nil))
ctx.setStrokeColor(c(0xFFFFFF, 0.14)); ctx.setLineWidth(4); ctx.strokePath()
ctx.restoreGState()

// Viewfinder corners
let inset: CGFloat = 250, L: CGFloat = 132, W: CGFloat = 44
let lo = inset, hi = S - inset
let corners = CGMutablePath()
corners.move(to: CGPoint(x: lo, y: lo + L)); corners.addLine(to: CGPoint(x: lo, y: lo)); corners.addLine(to: CGPoint(x: lo + L, y: lo))
corners.move(to: CGPoint(x: hi - L, y: lo)); corners.addLine(to: CGPoint(x: hi, y: lo)); corners.addLine(to: CGPoint(x: hi, y: lo + L))
corners.move(to: CGPoint(x: hi, y: hi - L)); corners.addLine(to: CGPoint(x: hi, y: hi)); corners.addLine(to: CGPoint(x: hi - L, y: hi))
corners.move(to: CGPoint(x: lo + L, y: hi)); corners.addLine(to: CGPoint(x: lo, y: hi)); corners.addLine(to: CGPoint(x: lo, y: hi - L))
let stroked = corners.copy(strokingWithWidth: W, lineCap: .round, lineJoin: .round, miterLimit: 10)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: c(0x0B0820, 0.5))
ctx.addPath(stroked); ctx.setFillColor(c(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(stroked); ctx.clip()
ctx.drawLinearGradient(gradient([c(0xFFFFFF), c(0xE4DCFF)], [0, 1]), start: CGPoint(x: 0, y: hi + W), end: CGPoint(x: 0, y: lo - W), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
ctx.restoreGState()

// Sparkle ("glint")
func sparkle(_ ctr: CGPoint, _ R: CGFloat, _ k: CGFloat = 0.13) -> CGPath {
    let p = CGMutablePath()
    let q = R * k
    p.move(to: CGPoint(x: ctr.x, y: ctr.y + R))
    p.addCurve(to: CGPoint(x: ctr.x + R, y: ctr.y), control1: CGPoint(x: ctr.x + q, y: ctr.y + q), control2: CGPoint(x: ctr.x + q, y: ctr.y + q))
    p.addCurve(to: CGPoint(x: ctr.x, y: ctr.y - R), control1: CGPoint(x: ctr.x + q, y: ctr.y - q), control2: CGPoint(x: ctr.x + q, y: ctr.y - q))
    p.addCurve(to: CGPoint(x: ctr.x - R, y: ctr.y), control1: CGPoint(x: ctr.x - q, y: ctr.y - q), control2: CGPoint(x: ctr.x - q, y: ctr.y - q))
    p.addCurve(to: CGPoint(x: ctr.x, y: ctr.y + R), control1: CGPoint(x: ctr.x - q, y: ctr.y + q), control2: CGPoint(x: ctr.x - q, y: ctr.y + q))
    p.closeSubpath()
    return p
}

let center = CGPoint(x: 512, y: 512)
// glow
ctx.drawRadialGradient(gradient([c(0xFFFFFF, 0.55), c(0xF5B8FF, 0.18), c(0xF5B8FF, 0)], [0, 0.35, 1]),
                       startCenter: center, startRadius: 0, endCenter: center, endRadius: 250, options: [])
let main = sparkle(center, 178)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 40, color: c(0xFFC8F2, 0.9))
ctx.addPath(main); ctx.setFillColor(c(0xFFFFFF)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(main); ctx.clip()
ctx.drawLinearGradient(gradient([c(0xFFFFFF), c(0xFFF3FB), c(0xF2C6FF)], [0, 0.5, 1]),
                       start: CGPoint(x: 400, y: 690), end: CGPoint(x: 640, y: 330), options: [])
ctx.restoreGState()

// small companion sparkle
let small = sparkle(CGPoint(x: 668, y: 668), 52, 0.16)
ctx.saveGState()
ctx.setShadow(offset: .zero, blur: 18, color: c(0xFFC8F2, 0.9))
ctx.addPath(small); ctx.setFillColor(c(0xFFFFFF, 0.95)); ctx.fillPath()
ctx.restoreGState()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
