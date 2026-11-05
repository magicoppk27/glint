import AppKit
import SwiftUI

/// Draw on the live screen with the editor's own tools and renderer.
///
/// A see-through window covers every display and hosts a `CanvasView` in screen mode (no picture, one image
/// pixel per screen pixel), each with its own drawing. Tool, color and size are shared; the toolbar acts on
/// the screen you last drew on and moves there. The surfaces are real Glint windows, not chrome, so
/// captures — including the toolbar's Capture button — show the drawing. The toolbar is chrome.
@MainActor
final class ScreenDraw {
    static let shared = ScreenDraw()

    /// Below Glint's capture overlay (so you can capture an area of your drawing), above everything else.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)

    private struct Surface {
        let panel: DrawPanel
        let model: EditorModel
    }

    private var surfaces: [Surface] = []
    /// The drawing the toolbar acts on: the screen last drawn on.
    private(set) var model: EditorModel?
    private var toolbar: NSPanel?
    private var toolbarHost: NSHostingView<DrawToolbar>?
    private var bags: [Any] = []
    private var syncing = false
    let state = DrawState()

    var isShowing: Bool { !surfaces.isEmpty }
    /// Showing on at least one display that still exists.
    var isVisible: Bool { surfaces.contains { onScreen($0.panel) } }
    var panels: [NSWindow] { surfaces.map(\.panel) }

    private func onScreen(_ p: NSWindow) -> Bool { p.isVisible && NSScreen.screens.contains { $0.frame == p.frame } }

    private var observers: [NSObjectProtocol] = []

    private init() {
        let nc = NotificationCenter.default
        // A display unplugged, slept or rearranged takes its surface with it; the others keep drawing.
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { ScreenDraw.shared.dropLostScreens() }
        })
        // Clicking another screen's surface makes it key: the toolbar follows it.
        observers.append(nc.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            MainActor.assumeIsolated {
                guard let w = note.object as? DrawPanel else { return }
                ScreenDraw.shared.activate(w)
            }
        })
    }

    func show() {
        guard surfaces.isEmpty else { return }
        let tool = Tool(rawValue: Prefs.d.string(forKey: "drawTool") ?? "").flatMap { EditorModel.screenTools.contains($0) ? $0 : nil } ?? .pen
        let color = min(max(Prefs.d.integer(forKey: "drawColor"), 0), palette.count - 1)
        let size = Prefs.d.object(forKey: "drawSize") as? Int ?? 1
        state.clickThrough = false

        for screen in NSScreen.screens {
            let scale = screen.backingScaleFactor
            let m = EditorModel(screenPixels: CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale), scale: scale)
            m.tool = tool
            m.colorIndex = color
            m.sizeIndex = size
            m.closeEditor = { Presenter.shared.set(.draw, false) }
            bags.append(m.objectWillChange.sink { [weak m] _ in
                DispatchQueue.main.async { if let m { ScreenDraw.shared.styleChanged(in: m) } }
            })

            let p = DrawPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = NSColor(white: 0, alpha: 0.01) // fully clear windows let clicks through
            p.hasShadow = false
            p.level = Self.level
            p.isReleasedWhenClosed = false
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            p.model = m
            p.contentView = CanvasView(model: m)
            p.setFrame(screen.frame, display: false)
            p.orderFrontRegardless()
            surfaces.append(Surface(panel: p, model: m))
        }

        let first = surfaces.first { $0.panel.frame.contains(NSEvent.mouseLocation) } ?? surfaces[0]
        let host = NSHostingView(rootView: DrawToolbar(model: first.model, state: state))
        let barSize = host.fittingSize // measure first, then pin the size
        host.sizingOptions = []
        let t = makeFloatingPanel(size: barSize, level: .presenting)
        t.contentView = host
        toolbar = t
        toolbarHost = host
        activate(first.panel)
        first.panel.makeKey()
        t.orderFrontRegardless()
    }

    func hide() {
        for s in surfaces {
            (s.panel.contentView as? CanvasView)?.commitText()
            s.panel.orderOut(nil)
        }
        toolbar?.orderOut(nil)
        surfaces = []
        toolbar = nil
        toolbarHost = nil
        model = nil
        bags = []
    }

    /// Points the toolbar at this surface's drawing and moves it to that screen.
    private func activate(_ panel: NSWindow) {
        guard let s = surfaces.first(where: { $0.panel === panel }), let t = toolbar, let screen = panel.screen else { return }
        if model !== s.model {
            model = s.model
            toolbarHost?.rootView = DrawToolbar(model: s.model, state: state)
        }
        if !screen.frame.intersects(t.frame) {
            t.setFrameOrigin(NSPoint(x: screen.frame.midX - t.frame.width / 2, y: screen.visibleFrame.minY + 14))
        }
    }

    /// Tool, color and size are one setting for every screen.
    private func styleChanged(in m: EditorModel) {
        guard !syncing else { return }
        syncing = true
        for s in surfaces where s.model !== m {
            if s.model.tool != m.tool { s.model.tool = m.tool }
            if s.model.colorIndex != m.colorIndex { s.model.colorIndex = m.colorIndex }
            if s.model.sizeIndex != m.sizeIndex { s.model.sizeIndex = m.sizeIndex }
        }
        syncing = false
        Prefs.d.set(m.tool.rawValue, forKey: "drawTool")
        Prefs.d.set(m.colorIndex, forKey: "drawColor")
        Prefs.d.set(m.sizeIndex, forKey: "drawSize")
    }

    private func dropLostScreens() {
        guard isShowing else { return }
        let lost = surfaces.filter { !onScreen($0.panel) }
        guard !lost.isEmpty else { return }
        if lost.count == surfaces.count { Presenter.shared.set(.draw, false); return }
        lost.forEach { $0.panel.orderOut(nil) }
        surfaces.removeAll { s in lost.contains { $0.panel === s.panel } }
        if let m = model, !surfaces.contains(where: { $0.model === m }) { activate(surfaces[0].panel) }
    }

    func clearAll() { surfaces.forEach { $0.model.clearAll() } }

    /// Lets clicks reach the apps underneath while the drawings stay on screen.
    func setClickThrough(_ on: Bool) {
        state.clickThrough = on
        surfaces.forEach { $0.panel.ignoresMouseEvents = on }
        if !on { surfaces.first { $0.model === model }?.panel.makeKey() }
    }

    /// Screenshot of the active screen with the drawing on it, opened in the editor; drawing ends.
    func capture() {
        guard let s = surfaces.first(where: { $0.model === model }), let screen = s.panel.screen else { return }
        (s.panel.contentView as? CanvasView)?.commitText()
        s.model.selectedID = nil
        s.panel.contentView?.display()
        Task { @MainActor in
            do {
                let f = try await CaptureService.shared.freeze([screen])[0]
                Presenter.shared.set(.draw, false)
                AppController.shared.deliver(f.image, scale: f.scale)
            } catch {
                Toast.show("Couldn't capture: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
            }
        }
    }
}

final class DrawState: ObservableObject {
    @Published var clickThrough = false
}

/// The drawing surface. Takes keys without activating Glint, so the app you present stays in front.
final class DrawPanel: NSPanel {
    weak var model: EditorModel?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let m = model, flags.contains(.command), let ch = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch (ch, flags) {
        case ("z", [.command]): m.undo()
        case ("z", [.command, .shift]): m.redo()
        case ("\u{8}", [.command]), ("\u{7f}", [.command]): ScreenDraw.shared.clearAll()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

// MARK: - Toolbar

struct DrawToolbar: View {
    @ObservedObject var model: EditorModel
    @ObservedObject var state: DrawState

    var body: some View {
        HStack(spacing: 2) {
            WindowGrip()
            ForEach(model.tools) { t in
                IconButton(symbol: t.symbol, selected: model.tool == t && !state.clickThrough, help: "\(t.label)  (\(t.key.uppercased()))") {
                    if state.clickThrough { ScreenDraw.shared.setClickThrough(false) }
                    model.tool = t
                }
            }
            divider
            ForEach(Array(palette.enumerated()), id: \.offset) { i, c in
                Button { model.colorIndex = i } label: {
                    Circle().fill(Color(nsColor: c))
                        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
                        .frame(width: 15, height: 15)
                        .padding(2.5)
                        .overlay(Circle().strokeBorder(model.colorIndex == i ? Color.white : .clear, lineWidth: 2))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Color \(i + 1)")
            }
            divider
            ForEach(0..<3) { i in
                Button { model.sizeIndex = i } label: {
                    Circle().fill(Color.primary.opacity(model.sizeIndex == i ? 0.95 : 0.4))
                        .frame(width: CGFloat(5 + i * 4), height: CGFloat(5 + i * 4))
                        .frame(width: 22, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(["Thin", "Medium", "Bold"][i])
            }
            divider
            IconButton(symbol: "arrow.uturn.backward", disabled: !model.canUndo, help: "Undo  ⌘Z") { model.undo() }
            IconButton(symbol: "trash", help: "Clear All, every screen  ⌘⌫") { ScreenDraw.shared.clearAll() }
            IconButton(symbol: state.clickThrough ? "hand.point.up.left.fill" : "hand.point.up.left",
                       selected: state.clickThrough, help: state.clickThrough ? "Back to drawing" : "Click through — use the apps underneath, keep the drawing") {
                ScreenDraw.shared.setClickThrough(!state.clickThrough)
            }
            IconButton(symbol: "camera.viewfinder", help: "Capture the screen with your drawing") { ScreenDraw.shared.capture() }
            IconButton(symbol: "xmark", help: "Stop drawing  (esc · right-click)") { Presenter.shared.set(.draw, false) }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .panelSurface(Capsule())
        .padding(10) // room for the shadow
        .fixedSize()
    }

    private var divider: some View { Divider().frame(height: 22).padding(.horizontal, 4) }
}

/// Drag handle that moves its (borderless) window.
struct WindowGrip: NSViewRepresentable {
    final class Grip: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func draw(_ dirtyRect: NSRect) {
            NSColor.white.withAlphaComponent(0.45).setFill()
            for r in 0..<3 { for c in 0..<2 {
                NSBezierPath(ovalIn: NSRect(x: 4 + CGFloat(c) * 5, y: 9 + CGFloat(r) * 5, width: 2.5, height: 2.5)).fill()
            } }
        }
    }
    func makeNSView(context: Context) -> Grip { Grip() }
    func updateNSView(_ v: Grip, context: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: Grip, context: Context) -> CGSize? { CGSize(width: 16, height: 30) }
}
