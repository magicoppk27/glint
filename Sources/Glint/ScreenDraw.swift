import AppKit
import SwiftUI

/// Draw on the live screen with the editor's own tools and renderer.
///
/// A see-through window covers the screen under the mouse and hosts a `CanvasView` in screen mode
/// (no picture, one image pixel per screen pixel). It is a real Glint window, not chrome, so
/// captures — including the toolbar's Capture button — show the drawing. The toolbar is chrome.
@MainActor
final class ScreenDraw {
    static let shared = ScreenDraw()

    /// Below Glint's capture overlay (so you can capture an area of your drawing), above everything else.
    static let level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)

    private(set) var model: EditorModel?
    private var panel: DrawPanel?
    private var toolbar: NSPanel?
    private var bag: Any?
    let state = DrawState()

    var isShowing: Bool { panel != nil }

    func show() {
        guard panel == nil else { return }
        let screen = NSScreen.withMouse
        let scale = screen.backingScaleFactor
        let m = EditorModel(screenPixels: CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale), scale: scale)
        m.tool = Tool(rawValue: Prefs.d.string(forKey: "drawTool") ?? "").flatMap { m.tools.contains($0) ? $0 : nil } ?? .pen
        m.colorIndex = min(max(Prefs.d.integer(forKey: "drawColor"), 0), palette.count - 1)
        m.sizeIndex = Prefs.d.object(forKey: "drawSize") as? Int ?? 1
        m.closeEditor = { Presenter.shared.set(.draw, false) }
        bag = m.objectWillChange.sink { [weak m] _ in
            DispatchQueue.main.async {
                guard let m else { return }
                Prefs.d.set(m.tool.rawValue, forKey: "drawTool")
                Prefs.d.set(m.colorIndex, forKey: "drawColor")
                Prefs.d.set(m.sizeIndex, forKey: "drawSize")
            }
        }
        model = m
        state.clickThrough = false

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
        panel = p
        p.orderFrontRegardless()
        p.makeKey()

        let host = NSHostingView(rootView: DrawToolbar(model: m, state: state))
        let size = host.fittingSize // measure first, then pin the size
        host.sizingOptions = []
        let t = makeFloatingPanel(size: size, level: .presenting)
        t.contentView = host
        t.setFrameOrigin(NSPoint(x: screen.frame.midX - size.width / 2, y: screen.visibleFrame.minY + 14))
        toolbar = t
        t.orderFrontRegardless()
    }

    func hide() {
        (panel?.contentView as? CanvasView)?.commitText()
        panel?.orderOut(nil)
        toolbar?.orderOut(nil)
        panel = nil
        toolbar = nil
        model = nil
        bag = nil
    }

    /// Lets clicks reach the apps underneath while the drawing stays on screen.
    func setClickThrough(_ on: Bool) {
        state.clickThrough = on
        panel?.ignoresMouseEvents = on
        if !on { panel?.makeKey() }
    }

    /// Screenshot of the screen with the drawing on it, opened in the editor; drawing ends.
    func capture() {
        guard let panel, let screen = panel.screen else { return }
        (panel.contentView as? CanvasView)?.commitText()
        model?.selectedID = nil
        panel.contentView?.display()
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
        case ("\u{8}", [.command]), ("\u{7f}", [.command]): m.clearAll()
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
            IconButton(symbol: "trash", disabled: model.annotations.isEmpty, help: "Clear All  ⌘⌫") { model.clearAll() }
            IconButton(symbol: state.clickThrough ? "hand.point.up.left.fill" : "hand.point.up.left",
                       selected: state.clickThrough, help: state.clickThrough ? "Back to drawing" : "Click through — use the apps underneath, keep the drawing") {
                ScreenDraw.shared.setClickThrough(!state.clickThrough)
            }
            IconButton(symbol: "camera.viewfinder", help: "Capture the screen with your drawing") { ScreenDraw.shared.capture() }
            IconButton(symbol: "xmark", help: "Stop drawing  (esc · right-click)") { Presenter.shared.set(.draw, false) }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.22), radius: 8, y: 3)
        .padding(10) // room for the shadow
        .fixedSize()
        .environment(\.colorScheme, .dark)
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
