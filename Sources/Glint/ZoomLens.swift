import AppKit
import CoreImage
import Carbon.HIToolbox
import CoreMedia
import QuartzCore
import ScreenCaptureKit

/// A round, click-through lens that follows the mouse and shows the live screen under it magnified.
///
/// It streams the display under the mouse with ScreenCaptureKit (Glint's Screen Recording grant) and
/// crops each frame with `contentsRect`, so moving the mouse never redraws pixels on the CPU. Glint's
/// overlay chrome (the lens itself, the halo, keystrokes) is left out; its real windows, including
/// drawings on the screen, are magnified like any other app. Nothing is recorded or saved.
///
/// Shortcut (default ⌃⌥M): a tap toggles the lens; holding it shows the lens only while held.
/// While it shows, ⌃⌥= / ⌃⌥− zoom and esc closes.
@MainActor
final class ZoomLens: NSObject {
    static let shared = ZoomLens()

    enum Defaults {
        static let zoom = 2.5
        static let size = 260.0
    }

    static let zoomRange = 1.5...10.0

    private(set) var isShowing = false
    private let holdThreshold: TimeInterval = 0.35
    private var pressedAt: Date?
    private var openedByThisPress = false

    private var panel: NSPanel?
    private let lensLayer = CALayer()
    private let ringLayer = CAShapeLayer()
    private let edgeLayer = CAShapeLayer()
    private let badge = CATextLayer()
    private var badgeTimer: Timer?
    private var monitors: [Any] = []
    private var defaultsObserver: NSObjectProtocol?

    private var stream: SCStream?
    private var streamDisplay: CGDirectDisplayID?
    private var streamFrame: CGRect = .zero
    private var restarting = false
    private let frames = FrameSink()
    /// Frames that reached the lens (for the self-test).
    private(set) var framesShown = 0
    /// Windows the current stream leaves out (for the self-test).
    private(set) var excludedWindowIDs: [CGWindowID] = []

    private var zoom: Double {
        get { Prefs.d.object(forKey: "lensZoom") as? Double ?? Defaults.zoom }
        set { Prefs.d.set(min(max(newValue, Self.zoomRange.lowerBound), Self.zoomRange.upperBound), forKey: "lensZoom") }
    }
    private var size: CGFloat { Prefs.d.object(forKey: "lensSize") as? Double ?? Defaults.size }

    // Carbon ids for the keys that exist only while the lens shows (outside HotkeyStore's range).
    private enum KeyID { static let zoomIn: UInt32 = 200, zoomOut: UInt32 = 201, close: UInt32 = 202 }

    // MARK: Hotkey

    func keyDown() {
        pressedAt = Date()
        if isShowing {
            openedByThisPress = false
            Presenter.shared.set(.lens, false)
        } else {
            openedByThisPress = true
            Presenter.shared.set(.lens, true)
        }
    }

    /// A key held past the threshold makes the lens momentary: it closes on release.
    func keyUp() {
        defer { pressedAt = nil }
        guard openedByThisPress, let pressedAt, Date().timeIntervalSince(pressedAt) >= holdThreshold else { return }
        Presenter.shared.set(.lens, false)
    }

    // MARK: Lifecycle

    /// Returns false when Screen Recording is missing (the usual alert has been shown).
    @discardableResult
    func show() -> Bool {
        guard !isShowing else { return true }
        guard AppController.shared.ensurePermission() else { return false }
        isShowing = true
        framesShown = 0

        let p = makeOverlayPanel(size: CGSize(width: size, height: size))
        p.sharingType = .none
        let host = NSView()
        host.wantsLayer = true
        for l in [lensLayer, edgeLayer, ringLayer, badge] { host.layer?.addSublayer(l) }
        p.contentView = host
        panel = p

        let noActions: [String: CAAction] = ["contents": NSNull(), "contentsRect": NSNull(), "bounds": NSNull(),
                                             "position": NSNull(), "frame": NSNull(), "path": NSNull(), "opacity": NSNull()]
        lensLayer.actions = noActions
        lensLayer.magnificationFilter = .linear
        lensLayer.masksToBounds = true
        lensLayer.contents = nil // see-through until the first frame lands
        ringLayer.actions = noActions
        ringLayer.fillColor = nil
        ringLayer.strokeColor = NSColor.white.withAlphaComponent(0.95).cgColor
        edgeLayer.actions = noActions
        edgeLayer.fillColor = nil
        edgeLayer.strokeColor = NSColor.black.withAlphaComponent(0.28).cgColor
        badge.actions = noActions
        badge.contentsScale = NSScreen.withMouse.backingScaleFactor
        badge.alignmentMode = .center
        badge.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        badge.fontSize = 12
        badge.foregroundColor = NSColor.white.cgColor
        badge.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        badge.cornerRadius = 9
        badge.opacity = 0
        layout()
        p.orderFrontRegardless()

        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.follow() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.follow(); return e }) {
            monitors.append(m)
        }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(); self?.follow() }
        }

        let co = UInt32(controlKey | optionKey)
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_Equal), modifiers: co, id: KeyID.zoomIn) { [weak self] in self?.step(1.25) }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_Minus), modifiers: co, id: KeyID.zoomOut) { [weak self] in self?.step(1 / 1.25) }
        HotKeyCenter.shared.register(keyCode: UInt32(kVK_Escape), modifiers: 0, id: KeyID.close) { Presenter.shared.set(.lens, false) }

        follow() // starts the stream for the screen under the mouse
        return true
    }

    func hide() {
        guard isShowing else { return }
        isShowing = false
        HotKeyCenter.shared.unregister(KeyID.zoomIn...KeyID.close)
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        if let o = defaultsObserver { NotificationCenter.default.removeObserver(o) }
        defaultsObserver = nil
        badgeTimer?.invalidate()
        stopStream()
        panel?.orderOut(nil)
        panel = nil
        lensLayer.contents = nil
    }

    private func step(_ factor: Double) {
        zoom *= factor
        follow()
        flashBadge()
    }

    private func flashBadge() {
        badge.string = String(format: "%.1f×", zoom)
        badge.opacity = 1
        badgeTimer?.invalidate()
        badgeTimer = Timer.scheduledTimer(withTimeInterval: 1.1, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                CATransaction.begin()
                CATransaction.setAnimationDuration(0.25)
                self?.badge.opacity = 0
                CATransaction.commit()
            }
        }
    }

    // MARK: Geometry

    private func layout() {
        let s = size
        let ring: CGFloat = 3
        let bounds = CGRect(x: 0, y: 0, width: s, height: s)
        lensLayer.frame = bounds
        lensLayer.cornerRadius = s / 2
        ringLayer.frame = bounds
        ringLayer.lineWidth = ring
        ringLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: ring / 2 + 0.5, dy: ring / 2 + 0.5), transform: nil)
        edgeLayer.frame = bounds
        edgeLayer.lineWidth = 1
        edgeLayer.path = CGPath(ellipseIn: bounds.insetBy(dx: 0.5, dy: 0.5), transform: nil)
        badge.frame = CGRect(x: s / 2 - 26, y: 14, width: 52, height: 18)
        if let panel, panel.frame.width != s { panel.setContentSize(NSSize(width: s, height: s)) }
    }

    /// The part of a display frame (unit coordinates, y = 0 at the bottom like Cocoa) shown in the lens.
    nonisolated static func crop(mouse: CGPoint, display f: CGRect, lens: CGFloat, zoom: Double) -> CGRect {
        guard f.width > 0, f.height > 0 else { return .zero }
        let w = lens / zoom / f.width, h = lens / zoom / f.height
        let cx = (mouse.x - f.minX) / f.width, cy = (mouse.y - f.minY) / f.height
        return CGRect(x: min(max(cx - w / 2, 0), max(1 - w, 0)), y: min(max(cy - h / 2, 0), max(1 - h, 0)), width: w, height: h)
    }

    /// Re-centres the lens on the mouse and moves the crop; switches streams when the mouse changes display.
    private func follow() {
        guard isShowing, let panel else { return }
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(x: (mouse.x - size / 2).rounded(), y: (mouse.y - size / 2).rounded()))
        if NSScreen.withMouse.displayID != streamDisplay { restartStream() }
        lensLayer.contentsRect = Self.crop(mouse: mouse, display: streamFrame, lens: size, zoom: zoom)
    }

    // MARK: Stream

    private func restartStream() {
        let screen = NSScreen.withMouse
        guard !restarting, let displayID = screen.displayID else { return }
        restarting = true
        streamDisplay = displayID
        streamFrame = screen.frame
        let scale = screen.backingScaleFactor
        let old = stream
        stream = nil
        lensLayer.contents = nil

        Task { @MainActor in
            defer { self.restarting = false }
            try? await old?.stopCapture()
            guard self.isShowing else { return }
            do {
                let (display, chrome) = try await self.contentWithLens(displayID)
                let filter = SCContentFilter(display: display, excludingWindows: chrome)
                self.excludedWindowIDs = chrome.map(\.windowID)
                let config = SCStreamConfiguration()
                config.width = Int(CGFloat(display.width) * scale)
                config.height = Int(CGFloat(display.height) * scale)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = false // the real cursor already sits at the lens centre
                config.queueDepth = 3 // the minimum; a 5K BGRA frame is ~57 MB

                let s = SCStream(filter: filter, configuration: config, delegate: self.frames)
                self.frames.onFrame = { [weak self, weak s] surface in
                    MainActor.assumeIsolated {
                        guard let self, self.isShowing, let s, s === self.stream else { return }
                        self.lensLayer.contents = surface
                        self.framesShown += 1
                    }
                }
                self.frames.onStop = { [weak self, weak s] in
                    MainActor.assumeIsolated {
                        if let self, let s, s === self.stream { Presenter.shared.set(.lens, false) }
                    }
                }
                try s.addStreamOutput(self.frames, type: .screen, sampleHandlerQueue: self.frames.queue)
                self.stream = s
                try await s.startCapture()
                guard self.isShowing, s === self.stream else { try? await s.stopCapture(); return }
                self.follow()
            } catch {
                NSLog("Glint: Zoom Lens capture failed: \(error.localizedDescription)")
                Presenter.shared.set(.lens, false)
            }
        }
    }

    /// Shareable content once the lens window is listed, so it can be left out of its own picture.
    private func contentWithLens(_ displayID: CGDirectDisplayID) async throws -> (SCDisplay, [SCWindow]) {
        let lensID = CGWindowID(panel?.windowNumber ?? 0)
        for attempt in 0..<10 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CancellationError() }
            let chrome = CaptureService.chromeWindows(in: content)
            if chrome.contains(where: { $0.windowID == lensID }) || attempt == 9 { return (display, chrome) }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        throw CancellationError()
    }

    /// What the lens shows right now, as an image (for the self-test).
    func snapshot() -> CGImage? {
        guard let surface = lensLayer.contents as! IOSurface? else { return nil }
        let img = CIImage(ioSurface: surface)
        let r = lensLayer.contentsRect
        let e = img.extent
        let crop = CGRect(x: e.width * r.minX, y: e.height * r.minY, width: e.width * r.width, height: e.height * r.height)
        return CIContext().createCGImage(img.cropped(to: crop), from: crop)
    }

    private func stopStream() {
        let s = stream
        stream = nil
        streamDisplay = nil
        Task { try? await s?.stopCapture() }
    }
}

/// Receives frames off the main thread and hands each IOSurface to the lens.
private final class FrameSink: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "app.glint.lens.frames", qos: .userInteractive)
    var onFrame: ((IOSurface) -> Void)?
    var onStop: (() -> Void)?

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid,
              let info = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = info.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = sb.imageBuffer, let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue()
        else { return }
        let deliver = onFrame
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            deliver?(surface)
            CATransaction.commit()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Glint: Zoom Lens stream stopped: \(error.localizedDescription)")
        let stop = onStop
        DispatchQueue.main.async { stop?() }
    }
}
