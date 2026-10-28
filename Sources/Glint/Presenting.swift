import AppKit
import Carbon.HIToolbox
import SwiftUI

// Presenting tools: overlays for demos and screen recordings (cursor halo, Zoom Lens, drawing on
// the screen, keystrokes). They live next to the capture tools and share Glint's hotkeys and Settings.

enum PresentFeature: String, CaseIterable, Identifiable {
    case halo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .halo: "Cursor Highlight"
        }
    }

    var subtitle: String {
        switch self {
        case .halo: "Halo follows the mouse, flashes on clicks"
        }
    }

    var symbol: String {
        switch self {
        case .halo: "cursorarrow.rays"
        }
    }

    var colors: [Color] {
        switch self {
        case .halo: [Color(hex: 0xF5A300), Color(hex: 0xFFD60A)]
        }
    }

    var defaultKey: UInt32 {
        switch self {
        case .halo: UInt32(kVK_ANSI_C)
        }
    }

    /// Modes that stay on across launches; the others are one-off sessions.
    var remembered: Bool { self == .halo }
}

@MainActor
final class Presenter: ObservableObject {
    static let shared = Presenter()

    @Published private(set) var active: Set<PresentFeature> = []

    private let key = "presentingOn"

    func isOn(_ f: PresentFeature) -> Bool { active.contains(f) }

    func binding(_ f: PresentFeature) -> Binding<Bool> {
        Binding(get: { self.isOn(f) }, set: { self.set(f, $0) })
    }

    func toggle(_ f: PresentFeature) { set(f, !isOn(f)) }

    func set(_ f: PresentFeature, _ on: Bool) {
        guard on != isOn(f) else { return }
        if on { active.insert(f) } else { active.remove(f) }
        switch f {
        case .halo: on ? CursorHalo.shared.show() : CursorHalo.shared.hide()
        }
        Prefs.d.set(active.filter(\.remembered).map(\.rawValue), forKey: key)
    }

    func hotkeyPressed(_ f: PresentFeature) { toggle(f) }

    func hotkeyReleased(_ f: PresentFeature) {}

    func turnOffAll() { PresentFeature.allCases.forEach { set($0, false) } }

    /// Brings back the modes that were on when Glint quit.
    func restore() {
        let saved = Prefs.d.stringArray(forKey: key) ?? []
        saved.compactMap(PresentFeature.init(rawValue:)).filter(\.remembered).forEach { set($0, true) }
    }
}

// MARK: - Panels

extension NSWindow.Level {
    /// Above full-screen apps, menus and Glint's own capture overlay.
    static let presenting = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
}

/// A click-through chrome panel on every Space; left out of Glint's captures like other chrome.
@MainActor
func makeOverlayPanel(size: CGSize) -> NSPanel {
    let p = makeFloatingPanel(size: size, level: .presenting)
    p.ignoresMouseEvents = true
    p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    return p
}

extension Binding where Value == Color {
    /// A ColorPicker binding over a "#RRGGBB" string stored with @AppStorage.
    static func hex(_ s: Binding<String>) -> Binding<Color> {
        Binding(get: { Color(nsColor: NSColor(hexString: s.wrappedValue) ?? .white) },
                set: { s.wrappedValue = NSColor($0).hexString })
    }
}

// MARK: - Menu, Home and Settings

struct PresentMenuItems: View {
    @ObservedObject private var presenter = Presenter.shared
    @ObservedObject private var hotkeys = HotkeyStore.shared
    var body: some View {
        Menu("Presenting") {
            ForEach(PresentFeature.allCases) { f in
                if let hk = hotkeys.hotkey(.present(f)), let key = hk.keyEquivalent {
                    Toggle(f.title, isOn: presenter.binding(f)).keyboardShortcut(key, modifiers: hk.eventModifiers)
                } else {
                    Toggle(f.title, isOn: presenter.binding(f))
                }
            }
            Divider()
            Button("Turn Off All") { presenter.turnOffAll() }.disabled(presenter.active.isEmpty)
        }
    }
}

/// Home window row: one switch tile per presenting tool.
struct PresentSection: View {
    @ObservedObject private var presenter = Presenter.shared
    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 320), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Presenting").font(.system(size: 17, weight: .bold, design: .rounded))
                Spacer()
                if !presenter.active.isEmpty {
                    Button("Turn Off All") { presenter.turnOffAll() }
                        .buttonStyle(PillButtonStyle(prominent: false))
                        .help("\(HotkeyStore.shared.label(.presentOff))")
                }
            }
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(PresentFeature.allCases) { PresentTile(feature: $0) }
            }
        }
    }
}

struct PresentTile: View {
    let feature: PresentFeature
    @ObservedObject private var presenter = Presenter.shared
    @ObservedObject private var hotkeys = HotkeyStore.shared
    @State private var hover = false

    var body: some View {
        let on = presenter.isOn(feature)
        Button { presenter.toggle(feature) } label: {
            HStack(spacing: 12) {
                Image(systemName: feature.symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: feature.colors, startPoint: .topLeading, endPoint: .bottomTrailing)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title).font(.system(size: 13, weight: .semibold))
                    Text(feature.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 4) {
                    Capsule().fill(on ? Color(hex: 0x34C759) : Color.primary.opacity(0.15))
                        .frame(width: 30, height: 18)
                        .overlay(Circle().fill(.white).padding(2).offset(x: on ? 6 : -6))
                        .animation(.easeOut(duration: 0.15), value: on)
                    Text(hotkeys.label(.present(feature))).font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(hover ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(on ? feature.colors[0].opacity(0.6) : Color.primary.opacity(0.08), lineWidth: on ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct PresentSettings: View {
    @AppStorage("haloSize") private var haloSize = CursorHalo.Defaults.size
    @AppStorage("haloRing") private var haloRing = CursorHalo.Defaults.ring
    @AppStorage("haloFill") private var haloFill = CursorHalo.Defaults.fill
    @AppStorage("haloIdle") private var haloIdle = CursorHalo.Defaults.idle
    @AppStorage("haloColor") private var haloColor = CursorHalo.Defaults.color
    @AppStorage("haloLeft") private var haloLeft = CursorHalo.Defaults.left
    @AppStorage("haloRight") private var haloRight = CursorHalo.Defaults.right

    var body: some View {
        Form {
            Section {
                PresentToggleRow(feature: .halo)
                Slider(value: $haloSize, in: 24...140) { Text("Size") }
                Slider(value: $haloRing, in: 1...8) { Text("Ring width") }
                Slider(value: $haloFill, in: 0...0.6) { Text("Fill") }
                Slider(value: $haloIdle, in: 0...1) { Text("Opacity when idle") }
                ColorPicker("Color", selection: .hex($haloColor), supportsOpacity: false)
                ColorPicker("Left click", selection: .hex($haloLeft), supportsOpacity: false)
                ColorPicker("Right click", selection: .hex($haloRight), supportsOpacity: false)
                HStack {
                    Spacer()
                    Button("Restore Defaults") {
                        haloSize = CursorHalo.Defaults.size; haloRing = CursorHalo.Defaults.ring
                        haloFill = CursorHalo.Defaults.fill; haloIdle = CursorHalo.Defaults.idle
                        haloColor = CursorHalo.Defaults.color; haloLeft = CursorHalo.Defaults.left
                        haloRight = CursorHalo.Defaults.right
                    }
                }
            } header: {
                Text("Cursor highlight")
            } footer: {
                Text("Shown on screen and in other apps' recordings, never in Glint's own screenshots.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct PresentToggleRow: View {
    let feature: PresentFeature
    @ObservedObject private var presenter = Presenter.shared
    @ObservedObject private var hotkeys = HotkeyStore.shared
    var body: some View {
        Toggle(isOn: presenter.binding(feature)) {
            HStack {
                Label(feature.title, systemImage: feature.symbol)
                Text(hotkeys.label(.present(feature))).foregroundStyle(.secondary)
            }
        }
    }
}
