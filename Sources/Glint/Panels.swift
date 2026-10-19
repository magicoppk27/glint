import AppKit
import SwiftUI
import Vision

// MARK: - Floating panel helper

@MainActor
func makeFloatingPanel(size: CGSize, level: NSWindow.Level = .statusBar) -> NSPanel {
    let p = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.isOpaque = false
    p.backgroundColor = .clear
    p.hasShadow = false
    p.level = level
    p.isReleasedWhenClosed = false
    p.hidesOnDeactivate = false
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    return p
}

// MARK: - Toast

@MainActor
enum Toast {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?

    static func show(_ text: String, symbol: String = "checkmark.circle.fill", tint: NSColor? = nil, duration: TimeInterval = 1.8) {
        let view = ToastView(text: text, symbol: symbol, tint: tint.map { Color(nsColor: $0) })
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let p = panel ?? makeFloatingPanel(size: size, level: .popUpMenu)
        p.contentView = host
        let vf = NSScreen.withMouse.visibleFrame
        let frame = CGRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 24, width: size.width, height: size.height)
        if panel == nil || p.alphaValue < 0.01 {
            p.setFrame(frame.offsetBy(dx: 0, dy: 10), display: false)
            p.alphaValue = 0
        }
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.22
            c.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(frame, display: true)
            p.animator().alphaValue = 1
        }
        panel = p
        hideWork?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ c in
                c.duration = 0.3
                p.animator().alphaValue = 0
            }, completionHandler: { if p.alphaValue < 0.01 { p.orderOut(nil) } })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }
}

struct ToastView: View {
    let text: String
    let symbol: String
    let tint: Color?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint ?? Color(hex: 0x8B7CFF))
            Text(text)
                .font(.system(size: 13.5, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .frame(maxWidth: 420, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(Capsule().fill(Color.black.opacity(0.82)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1))
        .padding(14)
        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
    }
}

// MARK: - Countdown

@MainActor
enum Countdown {
    static func run(seconds: Int) async {
        let size = CGSize(width: 168, height: 168)
        let p = makeFloatingPanel(size: size, level: .popUpMenu)
        let vf = NSScreen.withMouse.frame
        p.setFrame(CGRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height), display: false)
        for i in stride(from: seconds, through: 1, by: -1) {
            p.contentView = NSHostingView(rootView: CountdownView(n: i))
            p.orderFrontRegardless()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        p.orderOut(nil)
        try? await Task.sleep(nanoseconds: 120_000_000)
    }
}

struct CountdownView: View {
    let n: Int
    var body: some View {
        Text("\(n)")
            .font(.system(size: 64, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 128, height: 128)
            .background(RoundedRectangle(cornerRadius: 32, style: .continuous).fill(Color.black.opacity(0.78)))
            .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .frame(width: 168, height: 168)
    }
}

// MARK: - Post-capture thumbnail

@MainActor
enum ThumbnailController {
    private static var panel: NSPanel?
    private static var timer: Timer?
    static var hovering = false
    private static var shot: Shot?

    static func show(_ s: Shot) {
        dismiss(animated: false)
        shot = s
        let pt = s.pointSize
        let w: CGFloat = 264
        let h = min(max(w * pt.height / max(pt.width, 1), 110), 210)
        let pad: CGFloat = 18
        let size = CGSize(width: w + pad * 2, height: h + 40 + pad * 2)
        let p = makeFloatingPanel(size: size)
        let host = NSHostingView(rootView: ThumbnailView(shot: s, imageSize: CGSize(width: w, height: h)))
        host.frame = CGRect(origin: .zero, size: size)
        p.contentView = host
        let vf = NSScreen.withMouse.visibleFrame
        let final = CGRect(x: vf.maxX - size.width - 2, y: vf.minY + 2, width: size.width, height: size.height)
        p.setFrame(final.offsetBy(dx: 60, dy: 0), display: false)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.32
            c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
            p.animator().setFrame(final, display: true)
            p.animator().alphaValue = 1
        }
        panel = p
        scheduleHide()
    }

    static func scheduleHide(after t: TimeInterval = 7) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: t, repeats: false) { _ in
            Task { @MainActor in
                if hovering { scheduleHide(after: 2) } else { dismiss() }
            }
        }
    }

    static func dismiss(animated: Bool = true) {
        timer?.invalidate()
        hovering = false
        guard let p = panel else { return }
        panel = nil
        if !animated { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.25
            p.animator().setFrame(p.frame.offsetBy(dx: 60, dy: 0), display: true)
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }
}

struct ThumbnailView: View {
    let shot: Shot
    let imageSize: CGSize
    @State private var hover = false
    @State private var url: URL?

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: shot.nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: imageSize.width, height: imageSize.height)
                    .clipped()
                    .contentShape(Rectangle())
                    .onTapGesture { edit() }
                    .onDrag { dragProvider() }
                    .help("Click to annotate · drag into any app")
                Button { ThumbnailController.dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.black.opacity(0.6)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .padding(7)
                .opacity(hover ? 1 : 0.0)
            }
            HStack(spacing: 2) {
                ThumbButton(symbol: "doc.on.doc", help: "Copy") { ImageStore.copy(shot.image, scale: shot.scale); Toast.show("Copied to clipboard"); ThumbnailController.dismiss() }
                ThumbButton(symbol: (url ?? shot.url) == nil ? "square.and.arrow.down" : "folder", help: (url ?? shot.url) == nil ? "Save" : "Show in Finder") { save() }
                ThumbButton(symbol: "pencil.tip.crop.circle", help: "Annotate") { edit() }
                ThumbButton(symbol: "pin", help: "Pin to screen") { PinWindow.show(shot); ThumbnailController.dismiss() }
                ThumbButton(symbol: "text.viewfinder", help: "Copy text (OCR)") {
                    Task { await AppController.shared.recognize(shot.image) }
                }
            }
            .frame(width: imageSize.width, height: 40)
            .background(Color.black.opacity(0.86))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
        .padding(18)
        .onHover { h in
            withAnimation(.easeOut(duration: 0.15)) { hover = h }
            ThumbnailController.hovering = h
        }
    }

    private func edit() {
        ThumbnailController.dismiss()
        EditorWindowController.show(Shot(image: shot.image, scale: shot.scale, url: url ?? shot.url))
    }

    private func save() {
        if let u = url ?? shot.url {
            NSWorkspace.shared.activateFileViewerSelecting([u])
            ThumbnailController.dismiss()
        } else if let u = try? ImageStore.save(shot.image, scale: shot.scale) {
            url = u
            Library.shared.reload()
            Toast.show("Saved to \(Prefs.saveFolder.lastPathComponent)", symbol: "square.and.arrow.down.fill")
        }
    }

    private func dragProvider() -> NSItemProvider {
        var u = url ?? shot.url
        if u == nil {
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Glint \(ImageStore.nameFormatter.string(from: shot.date)).png")
            try? ImageStore.write(shot.image, scale: shot.scale, to: tmp)
            u = tmp
        }
        return NSItemProvider(contentsOf: u) ?? NSItemProvider(object: shot.nsImage)
    }
}

struct ThumbButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13.5, weight: .medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.white.opacity(hover ? 1 : 0.8))
                .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(hover ? 0.14 : 0)).padding(4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
    }
}

// MARK: - Pin to screen

@MainActor
final class PinWindow: NSPanel {
    static var all: [PinWindow] = []
    let shot: Shot
    private let aspect: CGFloat

    static func show(_ s: Shot) {
        let vf = NSScreen.withMouse.visibleFrame
        var size = s.pointSize
        let k = min(1, vf.width * 0.6 / size.width, vf.height * 0.6 / size.height)
        size = CGSize(width: size.width * k, height: size.height * k)
        let offset = CGFloat(all.count % 6) * 24
        let rect = CGRect(x: vf.midX - size.width / 2 + offset, y: vf.midY - size.height / 2 - offset, width: size.width, height: size.height)
        let w = PinWindow(shot: s, rect: rect)
        all.append(w)
        w.alphaValue = 0
        w.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; w.animator().alphaValue = 1 }
    }

    init(shot: Shot, rect: CGRect) {
        self.shot = shot
        self.aspect = shot.pointSize.width / max(shot.pointSize.height, 1)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = PinView(frame: CGRect(origin: .zero, size: rect.size), image: shot.image)
    }

    override var canBecomeKey: Bool { true }

    func zoom(by f: CGFloat) {
        let fr = frame
        let nw = min(max(fr.width * f, 60), 6000), nh = nw / aspect
        setFrame(CGRect(x: fr.midX - nw / 2, y: fr.midY - nh / 2, width: nw, height: nh), display: true)
        invalidateShadow()
    }

    func setOpacity(_ a: CGFloat) { alphaValue = min(max(a, 0.15), 1) }

    override func close() {
        PinWindow.all.removeAll { $0 === self }
        super.close()
    }
}

final class PinView: NSView {
    init(frame: CGRect, image: CGImage) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor
        autoresizingMask = [.width, .height]
    }
    required init?(coder: NSCoder) { fatalError() }

    private var pin: PinWindow? { window as? PinWindow }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { pin?.close(); return }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let d = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.08)
        if event.modifierFlags.contains(.option) {
            pin?.setOpacity((window?.alphaValue ?? 1) + d)
        } else {
            pin?.zoom(by: 1 + d)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { pin?.close(); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c", let s = pin?.shot {
            ImageStore.copy(s.image, scale: s.scale); Toast.show("Copied to clipboard"); return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "c").target = self
        m.addItem(withTitle: "Annotate", action: #selector(edit), keyEquivalent: "").target = self
        m.addItem(.separator())
        for pct in [100, 75, 50, 25] {
            let it = m.addItem(withTitle: "Opacity \(pct)%", action: #selector(opacity(_:)), keyEquivalent: "")
            it.target = self; it.tag = pct
        }
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(closePin), keyEquivalent: "").target = self
        return m
    }

    @objc private func copyImage() { if let s = pin?.shot { ImageStore.copy(s.image, scale: s.scale); Toast.show("Copied to clipboard") } }
    @objc private func edit() { if let s = pin?.shot { EditorWindowController.show(s); pin?.close() } }
    @objc private func opacity(_ sender: NSMenuItem) { pin?.setOpacity(CGFloat(sender.tag) / 100) }
    @objc private func closePin() { pin?.close() }
}

// MARK: - OCR

enum OCR {
    struct Result { var text: String; var codes: [String] }

    static func run(_ img: CGImage) async -> Result {
        await Task.detached(priority: .userInitiated) {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = true
            text.automaticallyDetectsLanguage = true
            let codes = VNDetectBarcodesRequest()
            let handler = VNImageRequestHandler(cgImage: img, options: [:])
            try? handler.perform([text, codes])
            let lines = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            let payloads = (codes.results ?? []).compactMap { $0.payloadStringValue }
            return Result(text: lines.joined(separator: "\n"), codes: payloads)
        }.value
    }
}
