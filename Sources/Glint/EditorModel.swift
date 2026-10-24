import AppKit
import CoreImage
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case select, arrow, line, rect, oval, pen, highlighter, text, counter, stepBox, blur, spotlight, magnifier, measure, picker, crop

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rect: "rectangle"
        case .oval: "circle"
        case .pen: "scribble"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .counter: "1.circle"
        case .stepBox: "number.square"
        case .blur: "eye.slash"
        case .spotlight: "flashlight.on.fill"
        case .magnifier: "plus.magnifyingglass"
        case .measure: "ruler"
        case .picker: "eyedropper"
        case .crop: "crop"
        }
    }

    var label: String {
        switch self {
        case .select: "Select & Move"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rect: "Rectangle"
        case .oval: "Oval"
        case .pen: "Draw"
        case .highlighter: "Highlighter"
        case .text: "Text"
        case .counter: "Step — click, or drag to point"
        case .stepBox: "Box + Step"
        case .blur: "Blur / Redact"
        case .spotlight: "Spotlight"
        case .magnifier: "Magnifier — drag to size the lens"
        case .measure: "Ruler"
        case .picker: "Color Picker"
        case .crop: "Crop"
        }
    }

    var key: Character {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .line: "l"
        case .rect: "r"
        case .oval: "o"
        case .pen: "d"
        case .highlighter: "h"
        case .text: "t"
        case .counter: "n"
        case .stepBox: "q"
        case .blur: "b"
        case .spotlight: "s"
        case .magnifier: "z"
        case .measure: "m"
        case .picker: "i"
        case .crop: "x"
        }
    }

    var usesColor: Bool { ![.select, .blur, .spotlight, .magnifier, .picker, .crop].contains(self) }
}

struct Annotation: Identifiable {
    enum Kind { case arrow, line, rect, oval, pen, highlighter, text, counter, blur, spotlight, magnifier, measure }

    var id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var width: CGFloat
    var text = ""
    var number = 0
    var tip: CGPoint? // counter: optional arrow pointing from the number

    var rect: CGRect { CGRect(start, end) }

    mutating func offset(by d: CGSize) {
        start.x += d.width; start.y += d.height
        end.x += d.width; end.y += d.height
        points = points.map { CGPoint(x: $0.x + d.width, y: $0.y + d.height) }
        if let t = tip { tip = CGPoint(x: t.x + d.width, y: t.y + d.height) }
    }
}

struct GradientPreset {
    let name: String
    let a: NSColor
    let b: NSColor
}

struct Backdrop {
    var enabled = false
    var preset = 0
    var padding: CGFloat = 56 // points
    var radius: CGFloat = 12 // points
    var shadow = true

    static let presets: [GradientPreset] = [
        GradientPreset(name: "Twilight", a: NSColor(hex: 0x5B4BFF), b: NSColor(hex: 0xEC4899)),
        GradientPreset(name: "Lagoon", a: NSColor(hex: 0x06B6D4), b: NSColor(hex: 0x3B5BF6)),
        GradientPreset(name: "Ember", a: NSColor(hex: 0xFB923C), b: NSColor(hex: 0xE11D74)),
        GradientPreset(name: "Mint", a: NSColor(hex: 0x34D399), b: NSColor(hex: 0x0EA5E9)),
        GradientPreset(name: "Peach", a: NSColor(hex: 0xFBC2EB), b: NSColor(hex: 0xA6C1EE)),
        GradientPreset(name: "Lilac", a: NSColor(hex: 0xC084FC), b: NSColor(hex: 0x6366F1)),
        GradientPreset(name: "Graphite", a: NSColor(hex: 0x374151), b: NSColor(hex: 0x111827)),
        GradientPreset(name: "Paper", a: NSColor(hex: 0xF5F5F4), b: NSColor(hex: 0xDCDCE0)),
    ]
}

let palette: [NSColor] = [
    NSColor(hex: 0xFF3B30), NSColor(hex: 0xFF9500), NSColor(hex: 0xFFCC00), NSColor(hex: 0x34C759),
    NSColor(hex: 0x0A84FF), NSColor(hex: 0xAF52DE), NSColor(hex: 0xFFFFFF), NSColor(hex: 0x1C1C1E),
]

/// Color under the cursor; kept separate so hovering doesn't redraw the canvas.
final class HoverColor: ObservableObject {
    @Published var color: NSColor?
    @Published var point: CGPoint = .zero
}

@MainActor
final class EditorModel: ObservableObject {
    let base: CGImage
    let scale: CGFloat
    var sourceURL: URL?

    @Published var annotations: [Annotation] = []
    @Published var tool: Tool = .select { didSet { if tool != .crop { pendingCrop = nil }; if tool != .select { selectedID = nil } } }
    @Published var colorIndex = 0
    @Published var sizeIndex = 1
    @Published var crop: CGRect?
    @Published var pendingCrop: CGRect?
    @Published var backdrop = Backdrop()
    @Published var selectedID: UUID?
    /// Shown briefly when the capture was already copied, so you know you can just paste.
    @Published var showCopiedBadge = false

    private struct Snapshot { var annotations: [Annotation]; var crop: CGRect? }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false

    let hover = HoverColor()
    /// Counter whose label is being typed; the renderer hides its label meanwhile.
    var editingLabelID: UUID?
    private lazy var rep = NSBitmapImageRep(cgImage: base)

    func color(at p: CGPoint) -> NSColor? {
        let x = Int(p.x.rounded(.down)), y = Int(p.y.rounded(.down))
        guard x >= 0, y >= 0, x < base.width, y < base.height else { return nil }
        return rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    func copyHoverColor(rgb: Bool) {
        guard let c = hover.color else { return }
        AppController.copyColor(c, rgb: rgb)
    }

    /// Writes the current render to a temp PNG for drag-and-drop into other apps.
    func dragProvider() -> NSItemProvider {
        guard let img = render() else { return NSItemProvider() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("GlintDrag", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Glint \(ImageStore.nameFormatter.string(from: Date())).png")
        try? ImageStore.write(img, scale: scale, to: url)
        return NSItemProvider(contentsOf: url) ?? NSItemProvider(object: NSImage(cgImage: img, size: .zero))
    }

    private var blurCache: [String: CGImage] = [:]
    private static let ci = CIContext(options: [.useSoftwareRenderer: false])

    init(shot: Shot) {
        base = shot.image
        scale = shot.scale
        sourceURL = shot.url
    }

    var baseBounds: CGRect { CGRect(x: 0, y: 0, width: base.width, height: base.height) }
    var imageRect: CGRect { crop ?? baseBounds }
    var padPx: CGFloat { backdrop.enabled ? backdrop.padding * scale : 0 }
    var outputSize: CGSize { CGSize(width: imageRect.width + padPx * 2, height: imageRect.height + padPx * 2) }
    var color: NSColor { palette[colorIndex] }

    var strokeWidth: CGFloat { [3, 5, 9][sizeIndex] * scale }
    var fontSize: CGFloat { [16, 24, 36][sizeIndex] * scale }
    /// Magnifier zoom for the S / M / L size buttons.
    var magnifierZoom: CGFloat { [1.6, 2.2, 3.0][sizeIndex] }
    var counterRadius: CGFloat { [11, 15, 20][sizeIndex] * scale }
    var nextCounter: Int { (annotations.filter { $0.kind == .counter }.map(\.number).max() ?? 0) + 1 }

    // MARK: Mutations

    func checkpoint() {
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        refreshUndo()
    }

    func add(_ a: Annotation) {
        checkpoint()
        annotations.append(a)
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        checkpoint()
        annotations.removeAll { $0.id == id }
        selectedID = nil
    }

    func applyCrop() {
        guard let r = pendingCrop?.integral.intersection(imageRect), r.width >= 4, r.height >= 4 else { pendingCrop = nil; return }
        checkpoint()
        crop = r
        pendingCrop = nil
    }

    func resetCrop() {
        guard crop != nil else { return }
        checkpoint()
        crop = nil
    }

    func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append(Snapshot(annotations: annotations, crop: crop))
        annotations = s.annotations; crop = s.crop; selectedID = nil
        refreshUndo()
    }

    func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append(Snapshot(annotations: annotations, crop: crop))
        annotations = s.annotations; crop = s.crop
        refreshUndo()
    }

    private func refreshUndo() { canUndo = !undoStack.isEmpty; canRedo = !redoStack.isEmpty }

    // MARK: Blur

    func blurred(_ r: CGRect) -> (CGImage, CGRect)? {
        let rr = r.integral.intersection(baseBounds)
        guard !rr.isNull, rr.width > 2, rr.height > 2 else { return nil }
        let key = "\(Int(rr.minX)),\(Int(rr.minY)),\(Int(rr.width)),\(Int(rr.height))"
        if let c = blurCache[key] { return (c, rr) }
        guard let crop = base.cropping(to: rr) else { return nil }
        let ci = CIImage(cgImage: crop)
        let sigma = min(max(min(rr.width, rr.height) / 9, 7 * scale), 40 * scale)
        let out = ci.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: ci.extent)
        guard let img = Self.ci.createCGImage(out, from: ci.extent) else { return nil }
        if blurCache.count > 60 { blurCache.removeAll() }
        blurCache[key] = img
        return (img, rr)
    }

    // MARK: Output

    func render() -> CGImage? { Renderer.render(self) }

    /// Set by the window controller.
    var closeEditor: (() -> Void)?

    func copy() {
        guard let img = render() else { return }
        ImageStore.copy(img, scale: scale)
        Toast.show("Copied to clipboard")
    }

    /// Copy, then disappear completely so you can paste anywhere.
    /// (The capture stays in Glint's Recent captures if you need it again.)
    func copyAndClose() {
        guard let img = render() else { return }
        ImageStore.copy(img, scale: scale)
        ThumbnailController.dismiss(animated: false)
        closeEditor?()
    }

    func save() {
        guard let img = render() else { return }
        do {
            let url = try ImageStore.save(img, scale: scale, suffix: " (edited)")
            Library.shared.reload()
            Toast.show("Saved \(url.lastPathComponent)", symbol: "square.and.arrow.down.fill")
        } catch {
            Toast.show("Couldn't save: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        }
    }

    func saveAs(from window: NSWindow?) {
        guard let img = render() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = "Glint \(ImageStore.nameFormatter.string(from: Date())).png"
        panel.directoryURL = Prefs.saveFolder
        let handler: (NSApplication.ModalResponse) -> Void = { [scale] resp in
            guard resp == .OK, let url = panel.url else { return }
            do {
                try ImageStore.write(img, scale: scale, to: url)
                Library.shared.reload()
                Toast.show("Saved \(url.lastPathComponent)", symbol: "square.and.arrow.down.fill")
            } catch {
                Toast.show("Couldn't save: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
        }
        if let w = window { panel.beginSheetModal(for: w, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    func pin() {
        guard let img = render() else { return }
        PinWindow.show(Shot(image: img, scale: scale))
    }

    func ocr() {
        guard let img = render() else { return }
        Task { await AppController.shared.recognize(img) }
    }
}
