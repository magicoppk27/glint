import AppKit
import SwiftUI
import Carbon.HIToolbox
import ImageIO
import UniformTypeIdentifiers

// MARK: - Preferences

enum Prefs {
    static let d = UserDefaults.standard

    static func registerDefaults() {
        // One-time move to "open editor after capture" as the default.
        if !d.bool(forKey: "migratedAfterCaptureEditor") {
            d.removeObject(forKey: "afterCapture")
            d.set(true, forKey: "migratedAfterCaptureEditor")
        }
        d.register(defaults: [
            "afterCapture": "editor",
            "autoCopy": true,
            "autoSave": true,
            "playSound": true,
            "downscaleRetina": false,
        ])
    }

    static var afterCapture: String { d.string(forKey: "afterCapture") ?? "editor" }
    static var autoCopy: Bool { d.bool(forKey: "autoCopy") }
    static var autoSave: Bool { d.bool(forKey: "autoSave") }
    static var playSound: Bool { d.bool(forKey: "playSound") }
    static var downscaleRetina: Bool { d.bool(forKey: "downscaleRetina") }

    static var saveFolder: URL {
        get {
            if let p = d.string(forKey: "saveFolder"), !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
            let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Pictures")
            return pictures.appendingPathComponent("Glint", isDirectory: true)
        }
        set { d.set(newValue.path, forKey: "saveFolder") }
    }
}

// MARK: - Shot

struct Shot {
    var image: CGImage
    var scale: CGFloat
    var url: URL?
    var date = Date()

    var pointSize: CGSize {
        CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
    }
    var nsImage: NSImage { NSImage(cgImage: image, size: pointSize) }
}

// MARK: - Image storage / clipboard

enum ImageStore {
    static let nameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return f
    }()

    static func pngData(_ img: CGImage, scale: CGFloat) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        let dpi = 72 * scale
        let props: [CFString: Any] = [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    @discardableResult
    static func save(_ img: CGImage, scale: CGFloat, suffix: String = "") throws -> URL {
        let folder = Prefs.saveFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = "Glint \(nameFormatter.string(from: Date()))\(suffix)"
        var url = folder.appendingPathComponent(base + ".png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).png"); n += 1
        }
        guard let data = pngData(img, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url, options: .atomic)
        return url
    }

    static func write(_ img: CGImage, scale: CGFloat, to url: URL) throws {
        let isJPEG = ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
        if isJPEG {
            let rep = NSBitmapImageRep(cgImage: img)
            guard let d = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { throw CocoaError(.fileWriteUnknown) }
            try d.write(to: url, options: .atomic)
        } else {
            guard let d = pngData(img, scale: scale) else { throw CocoaError(.fileWriteUnknown) }
            try d.write(to: url, options: .atomic)
        }
    }

    static func copy(_ img: CGImage, scale: CGFloat) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        if let png = pngData(img, scale: scale) { item.setData(png, forType: .png) }
        let ns = NSImage(cgImage: img, size: CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale))
        if let tiff = ns.tiffRepresentation { item.setData(tiff, forType: .tiff) }
        pb.writeObjects([item])
    }

    static func copyText(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    /// Loads an image and infers its Retina scale from DPI metadata.
    static func load(url: URL) -> Shot? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        var scale: CGFloat = 1
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 72 {
            scale = max(1, (CGFloat(dpi) / 72).rounded())
        }
        return Shot(image: img, scale: scale, url: url)
    }

    static func thumbnail(url: URL, maxPixel: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    static func downscale(_ img: CGImage, by factor: CGFloat) -> CGImage {
        let w = max(1, Int(CGFloat(img.width) * factor)), h = max(1, Int(CGFloat(img.height) * factor))
        let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return img }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? img
    }
}

// MARK: - Sound

enum Sound {
    static let shutter: NSSound? = {
        let p = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/Screen Capture.aif"
        return NSSound(contentsOfFile: p, byReference: true) ?? NSSound(named: "Pop")
    }()

    static func play() {
        guard Prefs.playSound, let s = shutter else { return }
        s.stop(); s.volume = 0.6; s.play()
    }
}

// MARK: - Hotkeys (Carbon)

final class HotKeyCenter {
    static let shared = HotKeyCenter()
    fileprivate var handlers: [UInt32: () -> Void] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false

    func install() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeyCenter.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Returns false when macOS refuses the combination (usually: another app owns it).
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, _ handler: @escaping () -> Void) -> Bool {
        if let old = refs.removeValue(forKey: id) { UnregisterEventHotKey(old) }
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x474C_4E54), id: id) // 'GLNT'
        let status = RegisterEventHotKey(keyCode, modifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        return true
    }

    func unregisterAll() {
        refs.values.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
    }
}

// MARK: - Helpers

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
    static var withMouse: NSScreen {
        let p = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(p, $0.frame, false) } ?? main ?? screens[0]
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension CGRect {
    init(_ a: CGPoint, _ b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

enum MenuBarIcon {
    static let image: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            NSColor.black.set()
            let corners = NSBezierPath()
            corners.lineWidth = 1.7
            corners.lineCapStyle = .round
            corners.lineJoinStyle = .round
            let i: CGFloat = 2, L: CGFloat = 4.5, m = r.width - i
            corners.move(to: NSPoint(x: i, y: i + L)); corners.line(to: NSPoint(x: i, y: i)); corners.line(to: NSPoint(x: i + L, y: i))
            corners.move(to: NSPoint(x: m - L, y: i)); corners.line(to: NSPoint(x: m, y: i)); corners.line(to: NSPoint(x: m, y: i + L))
            corners.move(to: NSPoint(x: m, y: m - L)); corners.line(to: NSPoint(x: m, y: m)); corners.line(to: NSPoint(x: m - L, y: m))
            corners.move(to: NSPoint(x: i + L, y: m)); corners.line(to: NSPoint(x: i, y: m)); corners.line(to: NSPoint(x: i, y: m - L))
            corners.stroke()
            sparkle(center: NSPoint(x: 9, y: 9), radius: 4.6).fill()
            return true
        }
        img.isTemplate = true
        return img
    }()

    static func sparkle(center c: NSPoint, radius R: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        let k = R * 0.16
        p.move(to: NSPoint(x: c.x, y: c.y + R))
        p.curve(to: NSPoint(x: c.x + R, y: c.y), controlPoint1: NSPoint(x: c.x + k, y: c.y + k), controlPoint2: NSPoint(x: c.x + k, y: c.y + k))
        p.curve(to: NSPoint(x: c.x, y: c.y - R), controlPoint1: NSPoint(x: c.x + k, y: c.y - k), controlPoint2: NSPoint(x: c.x + k, y: c.y - k))
        p.curve(to: NSPoint(x: c.x - R, y: c.y), controlPoint1: NSPoint(x: c.x - k, y: c.y - k), controlPoint2: NSPoint(x: c.x - k, y: c.y - k))
        p.curve(to: NSPoint(x: c.x, y: c.y + R), controlPoint1: NSPoint(x: c.x - k, y: c.y + k), controlPoint2: NSPoint(x: c.x - k, y: c.y + k))
        p.close()
        return p
    }
}
