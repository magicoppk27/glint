import SwiftUI

/// How Glint's own surfaces look. Liquid Glass needs macOS 26; older systems always get Classic.
///
/// - classic: frosted materials and soft shadows (Glint 1.0–1.3).
/// - liquid: Apple's Liquid Glass on the control layer only (toolbars, pills, floating buttons);
///   content such as the Home tiles stays solid, as the HIG asks.
/// - glint: Liquid Glass with a faint Glint-violet tint, interactive (it reacts to clicks), and on the
///   Home tiles too — they are buttons, so they count as controls.
/// - clear: like macOS 27's menus — the whole window is one sheet of glass, with plain system-style
///   controls on it (light gray fills, no cards, glows or glass on glass).
enum GlassLook: String, CaseIterable, Identifiable {
    case classic, liquid, glint, clear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .liquid: "Liquid Glass"
        case .glint: "Glint Glass"
        case .clear: "Clear Glass"
        }
    }

    var detail: String {
        switch self {
        case .classic: "Frosted materials and soft shadows"
        case .liquid: "Apple's clear glass on toolbars and buttons"
        case .glint: "Violet-tinted glass everywhere you click"
        case .clear: "One sheet of glass, like the menus"
        }
    }

    static let key = "glassLook"
    /// The theme until someone picks another.
    static let standard = GlassLook.clear

    static var supported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    static var current: GlassLook {
        guard supported else { return .classic }
        return GlassLook(rawValue: Prefs.d.string(forKey: key) ?? "") ?? .standard
    }
}

private let violet = Color(hex: 0x7C5CFF)
private let orchid = Color(hex: 0xC145F5)

/// Reads the look from defaults so every surface updates the moment it changes.
private struct LookReader<Content: View>: View {
    @AppStorage(GlassLook.key) private var raw = GlassLook.standard.rawValue
    let content: (GlassLook) -> Content
    init(@ViewBuilder _ content: @escaping (GlassLook) -> Content) { self.content = content }
    var body: some View { content(GlassLook.supported ? GlassLook(rawValue: raw) ?? .standard : .classic) }
}

extension View {
    /// Toolbars, pills and floating controls (the navigation layer).
    func controlSurface<S: InsettableShape>(_ shape: S) -> some View {
        LookReader { look in
            if look == .clear {
                self.background(shape.fill(.primary.opacity(0.05))) // the window is already glass
            } else if #available(macOS 26, *), look != .classic {
                self.glassEffect(look == .glint ? .regular.tint(violet.opacity(0.12)) : .regular, in: shape)
                    .overlay(look == .glint ? shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.55), violet.opacity(0.35), orchid.opacity(0.2)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1) : nil)
            } else {
                self.background(.regularMaterial, in: shape)
                    .overlay(shape.strokeBorder(.primary.opacity(0.08)))
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
            }
        }
    }

    /// Text and controls floating over someone else's content (toasts, keystrokes, the draw toolbar):
    /// always on a dark tint so white text stays readable over a white screenshot.
    func overlaySurface<S: InsettableShape>(_ shape: S, accent: Bool = false) -> some View {
        LookReader { look in
            if #available(macOS 26, *), look != .classic {
                self.glassEffect(.regular.tint((look == .glint || accent ? violet : .black).opacity(look == .glint ? 0.42 : 0.38)), in: shape)
                    .environment(\.colorScheme, .dark)
            } else {
                self.background(shape.fill(Color.black.opacity(0.8)))
                    .overlay(shape.strokeBorder(accent ? AnyShapeStyle(LinearGradient(colors: [violet, orchid], startPoint: .leading, endPoint: .trailing))
                                                       : AnyShapeStyle(Color.white.opacity(0.13)), lineWidth: accent ? 1.5 : 1))
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .environment(\.colorScheme, .dark)
            }
        }
    }

    /// A Home tile. Solid card except in Glint Glass.
    func tileSurface(hover: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return LookReader { look in
            if look == .clear {
                self.background(shape.fill(.primary.opacity(hover ? 0.09 : 0.05)))
            } else if #available(macOS 26, *), look == .glint {
                self.glassEffect(.regular.tint(violet.opacity(hover ? 0.14 : 0.06)).interactive(), in: shape)
                    .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), violet.opacity(0.25), .clear], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            } else {
                self.background(shape.fill(.background.opacity(hover ? 1 : 0.75)))
                    .overlay(shape.strokeBorder(.primary.opacity(hover ? 0.12 : 0.07)))
                    .shadow(color: .black.opacity(hover ? 0.12 : 0.04), radius: hover ? 14 : 6, y: hover ? 6 : 2)
            }
        }
    }

    /// Groups neighbouring glass so it blends instead of stacking (never glass on glass).
    func glassGroup(spacing: CGFloat = 10) -> some View {
        LookReader { look in
            if #available(macOS 26, *), look != .classic, look != .clear {
                GlassEffectContainer(spacing: spacing) { self }
            } else {
                self
            }
        }
    }
}

extension View {
    /// Decoration (tints, dot grids, glows) that Clear Glass leaves out: there the glass is the decoration.
    func hiddenInClearGlass() -> some View {
        LookReader { look in if look != .clear { self } }
    }

    /// A small content card (clipboard items, text captures): solid in the other looks, a light fill on glass.
    func cardFill(hover: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        return LookReader { look in
            if look == .clear {
                self.background(shape.fill(.primary.opacity(hover ? 0.09 : 0.05)))
            } else {
                self.background(shape.fill(.background.opacity(hover ? 1 : 0.8)))
            }
        }
    }

    /// A floating panel of controls over other apps (the draw toolbar). Clear Glass: light system glass,
    /// like a menu; the other looks: the dark overlay surface.
    func panelSurface<S: InsettableShape>(_ shape: S) -> some View {
        LookReader { look in
            if #available(macOS 26, *), look == .clear {
                self.glassEffect(.regular, in: shape)
            } else {
                self.overlaySurface(shape)
            }
        }
    }
}

/// The big buttons (Copy, Apply Crop, Open Image, …).
struct PillButtonStyle: ButtonStyle {
    var prominent: Bool
    @AppStorage(GlassLook.key) private var raw = GlassLook.standard.rawValue

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let look = GlassLook.supported ? GlassLook(rawValue: raw) ?? .standard : .classic
        let label = configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .frame(height: 40)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .contentShape(Rectangle())
        return Group {
            if look == .clear {
                // Plain buttons, like the ones in system menus: light gray, accent only for the main action.
                label
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(prominent ? AnyShapeStyle(violet) : AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07))))
                    .brightness(prominent && configuration.isPressed ? -0.08 : 0)
            } else if #available(macOS 26, *), look != .classic {
                // The prominent button keeps Glint's gradient under the glass so it still reads as the main action.
                label
                    .background(shape.fill(LinearGradient(colors: [violet, orchid], startPoint: .topLeading, endPoint: .bottomTrailing)).opacity(prominent ? 1 : 0))
                    .glassEffect(prominent ? .regular.tint(violet.opacity(0.5)).interactive() : (look == .glint ? .regular.tint(violet.opacity(0.08)).interactive() : .regular.interactive()), in: shape)
            } else {
                label
                    .background(shape.fill(prominent ? AnyShapeStyle(LinearGradient(colors: [violet, orchid], startPoint: .topLeading, endPoint: .bottomTrailing))
                                                     : AnyShapeStyle(.regularMaterial)))
                    .overlay(shape.strokeBorder(.white.opacity(prominent ? 0.2 : 0.08)))
                    .shadow(color: (prominent ? violet : .black).opacity(0.25), radius: 8, y: 3)
                    .scaleEffect(configuration.isPressed ? 0.97 : 1)
            }
        }
    }
}

/// The window's own background. Classic is solid; the glass looks let the desktop show through,
/// blurred, so the glass controls on top have something to refract.
struct WindowBackdrop: View {
    var solid: NSColor = .windowBackgroundColor
    @AppStorage(GlassLook.key) private var raw = GlassLook.standard.rawValue

    var body: some View {
        let look = GlassLook.supported ? GlassLook(rawValue: raw) ?? .standard : .classic
        ZStack {
            if look == .clear {
                WindowGlass()
            } else if look == .classic {
                Color(nsColor: solid)
            } else {
                BehindWindowBlur()
                Color(nsColor: solid).opacity(0.35)
                if look == .glint {
                    LinearGradient(colors: [violet.opacity(0.10), orchid.opacity(0.06), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
        .background(WindowOpacity(clear: look == .clear, solid: solid))
        .ignoresSafeArea()
    }
}

/// The whole window as one sheet of system glass (Clear Glass).
private struct WindowGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        if #available(macOS 26, *) {
            let g = NSGlassEffectView()
            g.style = .regular
            g.cornerRadius = 0
            return g
        }
        return NSView()
    }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// Glass can only show the desktop when the window itself is see-through; the other looks put the
/// solid background back.
private struct WindowOpacity: NSViewRepresentable {
    let clear: Bool
    let solid: NSColor

    final class Probe: NSView {
        var apply: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { if let w = window { apply?(w) } }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) {
        let clear = clear, solid = solid
        v.apply = { w in
            w.isOpaque = !clear
            w.backgroundColor = clear ? .clear : solid
        }
        if let w = v.window { v.apply?(w) }
    }
}

private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Theme choice for menus (menu bar icon, View menu).
struct ThemeMenu: View {
    @AppStorage(GlassLook.key) private var look = GlassLook.standard.rawValue
    var body: some View {
        Picker("Theme", selection: $look) {
            ForEach(GlassLook.allCases) { l in
                Text(l.title).tag(l.rawValue).disabled(l != .classic && !GlassLook.supported)
            }
        }
        .pickerStyle(.inline)
    }
}

/// Home window header button: the three themes, one click away.
struct ThemeButton: View {
    @AppStorage(GlassLook.key) private var look = GlassLook.standard.rawValue
    var body: some View {
        Menu {
            ForEach(GlassLook.allCases) { l in
                Button { look = l.rawValue } label: {
                    if look == l.rawValue { Label(l.title, systemImage: "checkmark") } else { Text(l.title) }
                }
                .disabled(l != .classic && !GlassLook.supported)
            }
        } label: {
            Image(systemName: "paintpalette").font(.system(size: 14, weight: .semibold)).frame(width: 18)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PillButtonStyle(prominent: false))
        .fixedSize()
        .help("Theme: \((GlassLook(rawValue: look) ?? .standard).title)")
    }
}
