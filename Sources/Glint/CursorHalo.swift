import AppKit
import SwiftUI

/// Pointer state shared by the halo's view.
final class HaloState: ObservableObject {
    enum Press { case none, left, right }
    @Published var press: Press = .none
    @Published var idle = false
    @Published var ripple = 0
    @Published var rippleRight = false
}

/// A click-through halo kept centered on the mouse. Recolors on clicks, dims when the mouse rests.
@MainActor
final class CursorHalo {
    static let shared = CursorHalo()

    enum Defaults {
        static let size = 56.0
        static let ring = 3.0
        static let fill = 0.25
        static let idle = 0.35
        static let color = "#FFD60A"
        static let left = "#FF453A"
        static let right = "#0A84FF"
    }

    let state = HaloState()
    private let side: CGFloat = 320
    private let idleDelay: TimeInterval = 1.5
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var idleTimer: Timer?
    private var lastActivity = Date()

    var isShowing: Bool { panel != nil }

    func show() {
        guard panel == nil else { return }
        let p = makeOverlayPanel(size: CGSize(width: side, height: side))
        let host = NSHostingView(rootView: HaloView(state: state))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        move()
        p.orderFrontRegardless()

        // Global mouse monitors need no permission (keyboard ones would).
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
                                           .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] e in
            MainActor.assumeIsolated { self?.handle(e.type) }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in
            self?.handle(e.type); return e
        }) { monitors.append(m) }
        noteActivity()
    }

    func hide() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        idleTimer?.invalidate()
        idleTimer = nil
        panel?.orderOut(nil)
        panel = nil
        state.press = .none
        state.idle = false
    }

    private func handle(_ type: NSEvent.EventType) {
        switch type {
        case .leftMouseDown: state.press = .left; ripple(right: false)
        case .rightMouseDown: state.press = .right; ripple(right: true)
        case .leftMouseUp, .rightMouseUp: state.press = .none
        default: break
        }
        move()
        noteActivity()
    }

    private func ripple(right: Bool) {
        state.rippleRight = right
        state.ripple += 1
    }

    /// Moving the window is a window-server move: no redraw of the halo itself.
    private func move() {
        let p = NSEvent.mouseLocation
        panel?.setFrameOrigin(NSPoint(x: (p.x - side / 2).rounded(), y: (p.y - side / 2).rounded()))
    }

    /// The idle check runs only until the halo has dimmed, so a resting mouse costs no wake-ups.
    private func noteActivity() {
        lastActivity = Date()
        if state.idle { state.idle = false }
        guard idleTimer == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { return t.invalidate() }
                guard self.state.press == .none, Date().timeIntervalSince(self.lastActivity) > self.idleDelay else { return }
                self.state.idle = true
                t.invalidate()
                self.idleTimer = nil
            }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        idleTimer = t
    }
}

struct HaloView: View {
    @ObservedObject var state: HaloState
    @AppStorage("haloSize") private var size = CursorHalo.Defaults.size
    @AppStorage("haloRing") private var ring = CursorHalo.Defaults.ring
    @AppStorage("haloFill") private var fill = CursorHalo.Defaults.fill
    @AppStorage("haloIdle") private var idleOpacity = CursorHalo.Defaults.idle
    @AppStorage("haloColor") private var colorHex = CursorHalo.Defaults.color
    @AppStorage("haloLeft") private var leftHex = CursorHalo.Defaults.left
    @AppStorage("haloRight") private var rightHex = CursorHalo.Defaults.right

    private func color(_ hex: String) -> Color { Color(nsColor: NSColor(hexString: hex) ?? .systemYellow) }

    var body: some View {
        let c = switch state.press {
        case .none: color(colorHex)
        case .left: color(leftHex)
        case .right: color(rightHex)
        }
        ZStack {
            if state.ripple > 0 {
                Ripple(color: color(state.rippleRight ? rightHex : leftHex), size: size).id(state.ripple)
            }
            ZStack {
                Circle().fill(c.opacity(fill))
                Circle().strokeBorder(c, lineWidth: ring)
            }
            .frame(width: size, height: size)
            .shadow(color: c.opacity(0.45), radius: 6)
            .scaleEffect(state.press == .none ? 1 : 0.8)
            .opacity(state.idle ? idleOpacity : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: state.press)
            .animation(.easeInOut(duration: 0.4), value: state.idle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One expanding ring per click; a new id restarts it.
private struct Ripple: View {
    let color: Color
    let size: CGFloat
    @State private var expanded = false

    var body: some View {
        Circle()
            .stroke(color, lineWidth: 2.5)
            .frame(width: size, height: size)
            .scaleEffect(expanded ? 2.2 : 0.8)
            .opacity(expanded ? 0 : 0.9)
            .onAppear { withAnimation(.easeOut(duration: 0.45)) { expanded = true } }
    }
}
