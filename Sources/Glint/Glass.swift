import SwiftUI

/// How Glint's own surfaces look. Liquid Glass needs macOS 26; older systems always get Classic.
///
/// - classic: frosted materials and soft shadows (Glint 1.0–1.3).
/// - liquid: Apple's Liquid Glass on the control layer only (toolbars, pills, floating buttons);
///   content such as the Home tiles stays solid, as the HIG asks.
/// - glint: Liquid Glass with a faint Glint-violet tint, interactive (it reacts to clicks), and on the
///   Home tiles too — they are buttons, so they count as controls.
enum GlassLook: String, CaseIterable, Identifiable {
    case classic, liquid, glint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: "Classic"
        case .liquid: "Liquid Glass"
        case .glint: "Glint Glass"
        }
    }

    var detail: String {
        switch self {
        case .classic: "Frosted materials and soft shadows"
        case .liquid: "Apple's clear glass on toolbars and buttons"
        case .glint: "Violet-tinted glass everywhere you click"
        }
    }

    static let key = "glassLook"

    static var supported: Bool {
        if #available(macOS 26, *) { return true }
        return false
    }

    static var current: GlassLook {
        guard supported else { return .classic }
        return GlassLook(rawValue: Prefs.d.string(forKey: key) ?? "") ?? .liquid
    }
}

private let violet = Color(hex: 0x7C5CFF)
private let orchid = Color(hex: 0xC145F5)

/// Reads the look from defaults so every surface updates the moment it changes.
private struct LookReader<Content: View>: View {
    @AppStorage(GlassLook.key) private var raw = GlassLook.liquid.rawValue
    let content: (GlassLook) -> Content
    init(@ViewBuilder _ content: @escaping (GlassLook) -> Content) { self.content = content }
    var body: some View { content(GlassLook.supported ? GlassLook(rawValue: raw) ?? .liquid : .classic) }
}

extension View {
    /// Toolbars, pills and floating controls (the navigation layer).
    func controlSurface<S: InsettableShape>(_ shape: S) -> some View {
        LookReader { look in
            if #available(macOS 26, *), look != .classic {
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
            if #available(macOS 26, *), look == .glint {
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
            if #available(macOS 26, *), look != .classic {
                GlassEffectContainer(spacing: spacing) { self }
            } else {
                self
            }
        }
    }
}

/// The big buttons (Copy, Apply Crop, Open Image, …).
struct PillButtonStyle: ButtonStyle {
    var prominent: Bool
    @AppStorage(GlassLook.key) private var raw = GlassLook.liquid.rawValue

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 13, style: .continuous)
        let look = GlassLook.supported ? GlassLook(rawValue: raw) ?? .liquid : .classic
        let label = configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .frame(height: 40)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .contentShape(Rectangle())
        return Group {
            if #available(macOS 26, *), look != .classic {
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
    @AppStorage(GlassLook.key) private var raw = GlassLook.liquid.rawValue

    var body: some View {
        let look = GlassLook.supported ? GlassLook(rawValue: raw) ?? .liquid : .classic
        ZStack {
            if look == .classic {
                Color(nsColor: solid)
            } else {
                BehindWindowBlur()
                Color(nsColor: solid).opacity(0.35)
                if look == .glint {
                    LinearGradient(colors: [violet.opacity(0.10), orchid.opacity(0.06), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
        }
        .ignoresSafeArea()
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
    @AppStorage(GlassLook.key) private var look = GlassLook.liquid.rawValue
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
    @AppStorage(GlassLook.key) private var look = GlassLook.liquid.rawValue
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
        .help("Theme: \((GlassLook(rawValue: look) ?? .liquid).title)")
    }
}
