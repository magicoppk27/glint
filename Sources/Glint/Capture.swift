import AppKit
import SwiftUI
import ScreenCaptureKit
import UniformTypeIdentifiers

struct Frozen {
    let screen: NSScreen
    let image: CGImage
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

struct WinInfo {
    let id: CGWindowID
    let frame: CGRect // Cocoa global coordinates
    let app: String
}

enum CaptureError: LocalizedError {
    case noDisplay, noWindow
    var errorDescription: String? {
        switch self {
        case .noDisplay: "Couldn't find that display"
        case .noWindow: "That window is no longer available"
        }
    }
}

@MainActor
final class CaptureService {
    static let shared = CaptureService()

    private func content() async throws -> SCShareableContent {
        try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    }

    /// Glint's transient helper windows (overlay, toasts, HUDs, picker) — never part of a screenshot.
    /// Its real windows (home, editor, pins) are captured like any other app's.
    static func chromeWindows(in content: SCShareableContent) -> [SCWindow] {
        let ids = Set(NSApp.windows.filter { $0.identifier == GlintChrome.id }.map { CGWindowID($0.windowNumber) })
        return content.windows.filter { ids.contains($0.windowID) }
    }

    /// Captures each screen as it looks right now (Glint's helper windows left out).
    func freeze(_ screens: [NSScreen]) async throws -> [Frozen] {
        let content = try await content()
        let chrome = Self.chromeWindows(in: content)
        // All displays are captured at the same time (was one after another).
        var jobs: [(Int, NSScreen, SCContentFilter, SCStreamConfiguration)] = []
        for (i, screen) in screens.enumerated() {
            guard let id = screen.displayID, let display = content.displays.first(where: { $0.displayID == id }) else { continue }
            let cfg = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            cfg.width = Int(screen.frame.width * scale)
            cfg.height = Int(screen.frame.height * scale)
            cfg.showsCursor = false
            cfg.captureResolution = .best
            jobs.append((i, screen, SCContentFilter(display: display, excludingWindows: chrome), cfg))
        }
        let images: [Int: CGImage] = try await withThrowingTaskGroup(of: (Int, CGImage).self) { group in
            for (i, _, filter, cfg) in jobs {
                group.addTask { (i, try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)) }
            }
            var done: [Int: CGImage] = [:]
            for try await (i, img) in group { done[i] = img }
            return done
        }
        let out = jobs.compactMap { job in images[job.0].map { Frozen(screen: job.1, image: $0) } }
        if out.isEmpty { throw CaptureError.noDisplay }
        return out
    }

    func captureWindow(_ windowID: CGWindowID) async throws -> (CGImage, CGFloat) {
        let content = try await content()
        guard let w = content.windows.first(where: { $0.windowID == windowID }) else { throw CaptureError.noWindow }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let scale = CGFloat(filter.pointPixelScale)
        let cfg = SCStreamConfiguration()
        cfg.width = Int(filter.contentRect.width * scale)
        cfg.height = Int(filter.contentRect.height * scale)
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        cfg.captureResolution = .best
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        return (img, scale)
    }

    /// On-screen app windows, front to back.
    func windowsFrontToBack() -> [WinInfo] {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let chrome = Set(NSApp.windows.filter { $0.identifier == GlintChrome.id }.map { UInt32($0.windowNumber) })
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return raw.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0,
                  d[kCGWindowOwnerPID as String] as? Int32 != nil,
                  let num = d[kCGWindowNumber as String] as? UInt32, !chrome.contains(num),
                  let bd = d[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd),
                  (d[kCGWindowAlpha as String] as? Double ?? 1) > 0.01,
                  r.width > 40, r.height > 30 else { return nil }
            let owner = d[kCGWindowOwnerName as String] as? String ?? ""
            if owner == "Window Server" { return nil }
            let cocoa = CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height)
            return WinInfo(id: num, frame: cocoa, app: owner)
        }
    }
}

// MARK: - Orchestration

@MainActor
final class AppController {
    static let shared = AppController()
    private var busy = false
    private var lastArea: (display: CGDirectDisplayID, rect: CGRect)? // rect in screen-local points (bottom-left)

    func run(_ kind: CaptureKind) {
        guard !busy, SelectionOverlay.active == nil, ScrollSession.active == nil else { return }
        guard ensurePermission() else { return }
        busy = true
        Task {
            defer { self.busy = false }
            do { try await perform(kind) } catch {
                Toast.show(error.localizedDescription, symbol: "exclamationmark.triangle.fill")
            }
        }
    }

    private func perform(_ kind: CaptureKind) async throws {
        switch kind {
        case .fullscreen:
            ThumbnailController.dismiss(animated: false)
            let f = try await CaptureService.shared.freeze([NSScreen.withMouse])[0]
            deliver(f.image, scale: f.scale)
        case .area: try await select(.area)
        case .window: try await select(.window)
        case .text: try await select(.text)
        case .color: try await select(.color)
        case .scroll: try await select(.scroll)
        case .delayed:
            await Countdown.run(seconds: 3)
            try await select(.area)
        case .repeatArea:
            guard let last = lastArea, let screen = NSScreen.screens.first(where: { $0.displayID == last.display }) else {
                Toast.show("No previous area yet — capture an area first", symbol: "info.circle.fill")
                return
            }
            let f = try await CaptureService.shared.freeze([screen])[0]
            let px = SelectionOverlay.pixelRect(for: last.rect, screenHeight: screen.frame.height, scale: f.scale)
            guard let img = f.image.cropping(to: px) else { return }
            deliver(img, scale: f.scale)
        }
    }

    private func select(_ mode: SelectionOverlay.Mode) async throws {
        ThumbnailController.dismiss(animated: false)
        let windows = CaptureService.shared.windowsFrontToBack()
        let frozen = try await CaptureService.shared.freeze(NSScreen.screens)
        let outcome: SelectionOverlay.Outcome = await withCheckedContinuation { cont in
            SelectionOverlay.present(frozen: frozen, mode: mode, windows: windows) { cont.resume(returning: $0) }
        }
        switch outcome {
        case .cancelled:
            return
        case let .color(color):
            Self.copyColor(color)
        case let .area(f, px, local):
            if let id = f.screen.displayID { lastArea = (id, local) }
            if mode == .scroll {
                ScrollSession.start(screen: f.screen, local: local)
                return
            }
            guard let img = f.image.cropping(to: px) else { return }
            if mode == .text { await recognize(img) } else { deliver(img, scale: f.scale) }
        case let .window(id):
            let (img, scale) = try await CaptureService.shared.captureWindow(id)
            deliver(img, scale: scale)
        }
    }

    func deliver(_ image: CGImage, scale: CGFloat) {
        var img = image, s = scale
        if Prefs.downscaleRetina && s > 1 {
            img = ImageStore.downscale(img, by: 1 / s); s = 1
        }
        Sound.play()
        var shot = Shot(image: img, scale: s)
        if Prefs.autoSave, let url = try? ImageStore.reserveURL() {
            shot.url = url
            ImageStore.saveInBackground(img, scale: s, to: url) { Library.shared.reload() }
        }
        if Prefs.autoCopy { ImageStore.copy(img, scale: s) }
        switch Prefs.afterCapture {
        case "editor":
            EditorWindowController.show(shot)
            if Prefs.autoCopy, let m = EditorWindowController.open.last?.model {
                m.showCopiedBadge = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { withAnimation(.easeOut(duration: 0.4)) { m.showCopiedBadge = false } }
            }
        case "nothing": Toast.show(Prefs.autoCopy ? "Copied to clipboard" : "Captured", symbol: "checkmark.circle.fill")
        default: ThumbnailController.show(shot)
        }
    }

    func recognize(_ img: CGImage) async {
        let r = await OCR.run(img)
        if let code = r.codes.first {
            ImageStore.copyText(code)
            Library.shared.addText(code, isCode: true)
            Toast.show("QR code copied: \(code.prefix(60))", symbol: "qrcode")
        } else if !r.text.isEmpty {
            ImageStore.copyText(r.text)
            Library.shared.addText(r.text, isCode: false)
            let lines = r.text.split(separator: "\n").count
            Toast.show("Copied \(lines) line\(lines == 1 ? "" : "s") of text", symbol: "text.viewfinder")
        } else {
            Toast.show("No text found", symbol: "eye.trianglebadge.exclamationmark")
        }
    }

    static func copyColor(_ color: NSColor, rgb: Bool = false) {
        let text: String
        if rgb, let c = color.usingColorSpace(.sRGB) {
            text = "rgb(\(Int(round(c.redComponent * 255))), \(Int(round(c.greenComponent * 255))), \(Int(round(c.blueComponent * 255))))"
        } else {
            text = color.hexString
        }
        ImageStore.copyText(text)
        Toast.show("Copied \(text)", symbol: "eyedropper.halffull", tint: color)
    }

    // MARK: Opening images

    func openImage(url: URL) {
        guard let shot = ImageStore.load(url: url) else {
            Toast.show("Couldn't open that image", symbol: "exclamationmark.triangle.fill"); return
        }
        EditorWindowController.show(shot)
    }

    func openImageFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.directoryURL = Prefs.saveFolder
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(openImage(url:))
    }

    func openClipboard() {
        guard let img = NSImage(pasteboard: .general),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Toast.show("No image on the clipboard", symbol: "doc.on.clipboard"); return
        }
        let scale = max(1, (CGFloat(cg.width) / max(img.size.width, 1)).rounded())
        EditorWindowController.show(Shot(image: cg, scale: scale))
    }

    // MARK: Permission

    private func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        if CGPreflightScreenCaptureAccess() { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Glint needs Screen Recording access"
        alert.informativeText = "Enable Glint in System Settings › Privacy & Security › Screen & System Audio Recording, then try again. You may need to relaunch Glint."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { Self.openPrivacySettings() }
        return false
    }

    static func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }
}
