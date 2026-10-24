import AppKit
import ApplicationServices
import ScreenCaptureKit
import SwiftUI

/// Scrolling capture: grabs the selected region repeatedly while the content scrolls
/// (automatically, or by the user) and stitches the frames into one tall — or wide — image.
/// Horizontal mode rotates each frame a quarter turn so the same vertical stitcher does the work.
@MainActor
final class ScrollSession: ObservableObject {
    static var active: ScrollSession?

    @Published var heightPx = 0 // length along the scroll direction
    @Published var autoScroll = false
    @Published var paused = false
    @Published private(set) var horizontal = Prefs.d.bool(forKey: "scrollHorizontal")

    private let screen: NSScreen
    private let local: CGRect // region, screen-local points (bottom-left)
    private let global: CGRect // region, Cocoa global points
    private let scale: CGFloat
    private var stitcher: Stitcher
    private var filter: SCContentFilter?
    private var border: NSPanel?
    private var hud: NSPanel?
    private var scrollTimer: Timer?
    private var keyMonitor: Any?
    private var running = true
    private var lastGrowth = Date()
    private let maxHeightPx = 40_000

    static func start(screen: NSScreen, local: CGRect) {
        guard active == nil else { return }
        let s = ScrollSession(screen: screen, local: local)
        active = s
        Task { await s.run() }
    }

    private init(screen: NSScreen, local: CGRect) {
        self.screen = screen
        self.local = local.integral
        self.global = self.local.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
        self.scale = screen.backingScaleFactor
        self.stitcher = Stitcher()
    }

    private func run() async {
        // Auto-scrolling posts scroll events, which macOS gates behind Accessibility.
        autoScroll = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.noDisplay }
            filter = SCContentFilter(display: display, excludingWindows: CaptureService.chromeWindows(in: content))
        } catch {
            Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            teardown(); return
        }
        showChrome()
        if autoScroll {
            CGWarpMouseCursorPosition(cgPoint(NSPoint(x: global.midX, y: global.midY)))
            startScrolling()
        }
        lastGrowth = Date()
        while running {
            if var frame = await grab() {
                let st = stitcher, wasHorizontal = horizontal
                if wasHorizontal, let r = rotateQuarter(frame, clockwise: true) { frame = r }
                let h = await st.add(frame)
                // Ignore a result from before a direction switch.
                guard st === stitcher, wasHorizontal == horizontal else { continue }
                if h > heightPx { heightPx = h; lastGrowth = Date() }
                if heightPx >= maxHeightPx { finish(); break }
            }
            // At the end of the page nothing moves any more: wrap up on our own.
            if autoScroll, !paused, Date().timeIntervalSince(lastGrowth) > 2.2, heightPx > 0 { finish(); break }
            try? await Task.sleep(nanoseconds: 70_000_000)
        }
    }

    private func grab() async -> CGImage? {
        guard let filter else { return nil }
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = CGRect(x: local.minX, y: screen.frame.height - local.maxY, width: local.width, height: local.height)
        cfg.width = Int(local.width * scale)
        cfg.height = Int(local.height * scale)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }

    /// Switching direction starts the stitch over from what's on screen now.
    func setHorizontal(_ h: Bool) {
        guard h != horizontal, running else { return }
        horizontal = h
        Prefs.d.set(h, forKey: "scrollHorizontal")
        stitcher = Stitcher()
        heightPx = 0
        lastGrowth = Date()
    }

    // MARK: Auto-scroll

    private func startScrolling() {
        scrollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        // Moving the pointer out of the region (e.g. towards Done) pauses scrolling.
        let inside = global.contains(NSEvent.mouseLocation)
        paused = !inside
        guard inside, running else { lastGrowth = Date(); return }
        let e = horizontal
            ? CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -6, wheel3: 0)
            : CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -6, wheel2: 0, wheel3: 0)
        e?.location = cgPoint(NSEvent.mouseLocation)
        e?.post(tap: .cghidEventTap)
    }

    private func cgPoint(_ p: NSPoint) -> CGPoint {
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: primaryH - p.y)
    }

    // MARK: Chrome (border + HUD; Glint's own windows are excluded from the capture)

    private func showChrome() {
        let pad: CGFloat = 4
        let b = makeFloatingPanel(size: global.size, level: .statusBar)
        b.ignoresMouseEvents = true
        b.setFrame(global.insetBy(dx: -pad, dy: -pad), display: false)
        b.contentView = NSHostingView(rootView:
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(hex: 0x8B5CF6), style: StrokeStyle(lineWidth: 2.5, dash: [8, 5]))
                .padding(1))
        b.orderFrontRegardless()
        border = b

        let host = NSHostingView(rootView: ScrollHUD(session: self))
        let size = CGSize(width: 520, height: 74)
        let h = makeFloatingPanel(size: size, level: .statusBar)
        host.frame = CGRect(origin: .zero, size: size)
        h.contentView = host
        let vf = screen.visibleFrame
        var y = global.minY - size.height - 10
        if y < vf.minY { y = global.maxY + 10 }
        if y + size.height > vf.maxY { y = global.minY + 12 }
        let x = min(max(global.midX - size.width / 2, vf.minX + 8), vf.maxX - size.width - 8)
        h.setFrame(CGRect(x: x, y: y, width: size.width, height: size.height), display: false)
        h.orderFrontRegardless()
        hud = h

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self else { return e }
            switch e.keyCode {
            case 36, 76: self.finish(); return nil
            case 53: self.cancel(); return nil
            case 123, 124: self.setHorizontal(true); return nil // ← →
            case 125, 126: self.setHorizontal(false); return nil // ↑ ↓
            default: return e
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Finish

    func finish() {
        guard running else { return }
        running = false
        teardown()
        let wide = horizontal
        Task {
            guard var img = await stitcher.compose() else {
                Toast.show("Nothing captured — try scrolling a scrollable area", symbol: "exclamationmark.triangle.fill"); return
            }
            if wide, let r = rotateQuarter(img, clockwise: false) { img = r }
            AppController.shared.deliver(img, scale: scale)
        }
    }

    func cancel() {
        running = false
        teardown()
    }

    private func teardown() {
        scrollTimer?.invalidate()
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        keyMonitor = nil
        border?.orderOut(nil)
        hud?.orderOut(nil)
        if ScrollSession.active === self { ScrollSession.active = nil }
    }

    var pointHeight: Int { Int(CGFloat(heightPx) / scale) }
}

struct ScrollHUD: View {
    @ObservedObject var session: ScrollSession

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color(hex: 0x8B5CF6).opacity(0.25)).frame(width: 34, height: 34)
                Image(systemName: session.paused ? "pause.fill" : (session.horizontal ? "arrow.right" : "arrow.down"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: 0xC4B5FD))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                Text("\(session.pointHeight) pt \(session.horizontal ? "wide" : "tall")  ·  ⏎ done  ·  esc cancel")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.65))
            }
            Spacer(minLength: 4)
            DirectionSwitch(session: session)
            Button("Cancel") { session.cancel() }
                .buttonStyle(HUDButton(prominent: false))
            Button("Done") { session.finish() }
                .buttonStyle(HUDButton(prominent: true))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .frame(width: 500, height: 56)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.85)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .frame(width: 520, height: 74)
    }

    private var title: String {
        if !session.autoScroll { return "Scroll the content yourself" }
        return session.paused ? "Paused — move back into the area to scroll" : "Scrolling… stop whenever you like"
    }
}

/// ↓ / → toggle for the scroll direction (arrow keys work too).
struct DirectionSwitch: View {
    @ObservedObject var session: ScrollSession
    var body: some View {
        HStack(spacing: 2) {
            seg("arrow.down", "Scroll down  (↓)", !session.horizontal) { session.setHorizontal(false) }
            seg("arrow.right", "Scroll right  (→)", session.horizontal) { session.setHorizontal(true) }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.1)))
    }

    private func seg(_ symbol: String, _ help: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .frame(width: 30, height: 26)
                .foregroundStyle(on ? Color.white : Color.white.opacity(0.55))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(on ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x7C5CFF), Color(hex: 0xC145F5)], startPoint: .topLeading, endPoint: .bottomTrailing)) : AnyShapeStyle(Color.clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Quarter-turn rotation. Clockwise moves the right edge to the bottom, so sideways
/// scrolling (content moving left) becomes ordinary downward scrolling (content moving up).
func rotateQuarter(_ img: CGImage, clockwise: Bool) -> CGImage? {
    let w = img.width, h = img.height
    let cs = img.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: h, height: w, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    if clockwise {
        ctx.translateBy(x: 0, y: CGFloat(w))
        ctx.rotate(by: -.pi / 2)
    } else {
        ctx.translateBy(x: CGFloat(h), y: 0)
        ctx.rotate(by: .pi / 2)
    }
    ctx.interpolationQuality = .none
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

struct HUDButton: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x7C5CFF), Color(hex: 0xC145F5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(Color.white.opacity(0.12)))
            )
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

// MARK: - Stitching

/// Aligns consecutive frames by finding the vertical shift that best matches their overlap,
/// ignoring rows that stay fixed (sticky headers / footers), then appends the newly revealed rows.
actor Stitcher {
    private struct Sig { let rows: [[UInt8]]; let h: Int }
    private static let cols = 96

    private var first: CGImage?
    private var last: CGImage?
    private var lastSig: Sig?
    private var strips: [CGImage] = []
    private var firstCut: Int? // rows of the first frame kept (above any fixed footer)
    private var covered = 0 // in the last frame's coordinates, rows already in the output
    private var total = 0

    func add(_ img: CGImage) -> Int {
        guard let sig = Self.signature(img) else { return total }
        guard let prev = lastSig, let prevImg = last else {
            first = img; last = img; lastSig = sig; total = img.height; covered = img.height
            return total
        }
        guard img.width == prevImg.width, img.height == prevImg.height else { return total }
        let h = sig.h

        // Fixed rows at the top/bottom (identical in both frames) don't take part in matching.
        let limit = h * 2 / 5
        var top = 0
        while top < limit, Self.rowDiff(prev.rows[top], sig.rows[top]) < 2 { top += 1 }
        if top == limit { return total } // nothing moved
        var bottom = 0
        while bottom < limit, Self.rowDiff(prev.rows[h - 1 - bottom], sig.rows[h - 1 - bottom]) < 2 { bottom += 1 }

        let bandStart = top, bandEnd = h - bottom
        let band = bandEnd - bandStart
        guard band > 40 else { return total }

        // Content moved up by dy: cur[y] ≈ prev[y + dy] for y in the band.
        var best = (dy: 0, score: Double.infinity)
        let maxDy = Int(Double(band) * 0.85)
        for dy in 1...max(1, maxDy) {
            var sum = 0, n = 0
            var y = bandStart
            while y + dy < bandEnd {
                let a = prev.rows[y + dy], b = sig.rows[y]
                var c = 0
                while c < Self.cols { sum += abs(Int(a[c]) - Int(b[c])); c += 3 }
                n += 1
                y += 3
            }
            guard n > 6 else { break }
            let score = Double(sum) / Double(n * (Self.cols / 3))
            if score < best.score { best = (dy, score) }
        }
        guard best.score < 10, best.dy > 0 else { return total }

        // The first frame stops above any fixed footer; everything below is appended later.
        if firstCut == nil { firstCut = bandEnd; covered = bandEnd }
        // Continue exactly where the output ends: previously covered rows moved up by dy.
        let start = covered - best.dy
        let end = max(bandEnd, start)
        if end > start, let strip = img.cropping(to: CGRect(x: 0, y: start, width: img.width, height: end - start)) {
            strips.append(strip)
        }
        covered = end
        last = img
        lastSig = sig
        total = (firstCut ?? h) + strips.reduce(0) { $0 + $1.height } + (h - covered)
        return total
    }

    func compose() -> CGImage? {
        guard let first, let last else { return nil }
        guard !strips.isEmpty, let firstCut else { return first }
        let w = first.width, h = first.height
        let headPart = firstCut
        let footer = h - covered
        let height = headPart + strips.reduce(0) { $0 + $1.height } + footer
        let cs = first.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: w, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // CG draws bottom-up; place pieces from the top.
        var y = height
        func put(_ img: CGImage?) {
            guard let img else { return }
            y -= img.height
            ctx.draw(img, in: CGRect(x: 0, y: y, width: img.width, height: img.height))
        }
        put(first.cropping(to: CGRect(x: 0, y: 0, width: w, height: headPart)))
        strips.forEach { put($0) }
        if footer > 0 { put(last.cropping(to: CGRect(x: 0, y: h - footer, width: w, height: footer))) }
        return ctx.makeImage()
    }

    /// Grayscale, horizontally downsampled copy (full vertical resolution) used for matching.
    private static func signature(_ img: CGImage) -> Sig? {
        let h = img.height
        guard h > 0, let ctx = CGContext(data: nil, width: cols, height: h, bitsPerComponent: 8, bytesPerRow: cols,
                                         space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: cols, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.bindMemory(to: UInt8.self, capacity: cols * h)
        // Bitmap memory is top row first.
        let rows = (0..<h).map { r in Array(UnsafeBufferPointer(start: p + r * cols, count: cols)) }
        return Sig(rows: rows, h: h)
    }

    private static func rowDiff(_ a: [UInt8], _ b: [UInt8]) -> Int {
        var s = 0
        for i in 0..<cols { s += abs(Int(a[i]) - Int(b[i])) }
        return s / cols
    }
}
