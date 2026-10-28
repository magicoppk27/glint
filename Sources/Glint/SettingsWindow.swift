import ApplicationServices
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, presenting, shortcuts, permissions, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .presenting: "Presenting"
        case .shortcuts: "Shortcuts"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .presenting: "cursorarrow.rays"
        case .shortcuts: "keyboard"
        case .permissions: "lock.shield"
        case .about: "sparkles"
        }
    }

    @ViewBuilder var view: some View {
        switch self {
        case .general: GeneralSettings()
        case .appearance: AppearanceSettings()
        case .presenting: PresentSettings()
        case .shortcuts: ShortcutSettings()
        case .permissions: PermissionSettings()
        case .about: AboutSettings()
        }
    }
}

/// Settings, as toolbar tabs (the Mac default) or as a sidebar like System Settings.
struct SettingsView: View {
    @AppStorage("settingsLayout") private var layout = "tabs"
    @AppStorage("settingsPane") private var pane = SettingsPane.general.rawValue

    private var selection: Binding<SettingsPane?> {
        Binding(get: { SettingsPane(rawValue: pane) ?? .general }, set: { pane = ($0 ?? .general).rawValue })
    }

    var body: some View {
        if layout == "sidebar" {
            NavigationSplitView {
                List(SettingsPane.allCases, selection: selection) { p in
                    Label(p.title, systemImage: p.symbol).tag(p)
                }
                .navigationSplitViewColumnWidth(min: 180, ideal: 190, max: 220)
            } detail: {
                (SettingsPane(rawValue: pane) ?? .general).view
                    .navigationTitle((SettingsPane(rawValue: pane) ?? .general).title)
            }
            .frame(width: 780, height: 580)
        } else {
            TabView(selection: Binding(get: { SettingsPane(rawValue: pane) ?? .general }, set: { pane = $0.rawValue })) {
                ForEach(SettingsPane.allCases) { p in
                    p.view.tabItem { Label(p.title, systemImage: p.symbol) }.tag(p)
                }
            }
            .frame(width: 600, height: 580)
        }
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @AppStorage(GlassLook.key) private var look = GlassLook.liquid.rawValue
    @AppStorage("settingsLayout") private var layout = "tabs"

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    ForEach(GlassLook.allCases) { l in
                        LookCard(look: l, selected: look == l.rawValue, enabled: l == .classic || GlassLook.supported) { look = l.rawValue }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Look")
            } footer: {
                Text(GlassLook.supported ? "Applies to the editor's toolbars, the Home window, toasts and the presenting tools at once."
                                         : "Liquid Glass needs macOS 26 or later.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section("Settings window") {
                Picker("Layout", selection: $layout) {
                    Text("Tabs").tag("tabs")
                    Text("Sidebar").tag("sidebar")
                }
                .pickerStyle(.segmented)
            }
        }
        .formStyle(.grouped)
    }
}

/// A small live preview of one look: a toolbar pill over a picture.
private struct LookCard: View {
    let look: GlassLook
    let selected: Bool
    let enabled: Bool
    let pick: () -> Void

    var body: some View {
        Button(action: pick) {
            VStack(spacing: 8) {
                ZStack {
                    LinearGradient(colors: [Color(hex: 0x5B4BFF), Color(hex: 0xEC4899), Color(hex: 0xFB923C)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "mountain.2.fill").font(.system(size: 38)).foregroundStyle(.white.opacity(0.35)).offset(y: 14)
                    HStack(spacing: 6) {
                        ForEach(["arrow.up.right", "rectangle", "textformat"], id: \.self) { s in
                            Image(systemName: s).font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22)
                        }
                    }
                    .padding(4)
                    .modifier(PreviewSurface(look: look))
                    .offset(y: -18)
                }
                .frame(height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 2.5 : 1))
                VStack(spacing: 2) {
                    Text(look.title).font(.system(size: 12, weight: .semibold))
                    Text(look.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
    }
}

/// Each card previews its own look, whatever the current one is.
private struct PreviewSurface: ViewModifier {
    let look: GlassLook
    func body(content: Content) -> some View {
        let shape = Capsule()
        if #available(macOS 26, *), look != .classic {
            content.glassEffect(look == .glint ? .regular.tint(Color(hex: 0x7C5CFF).opacity(0.25)) : .regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape).shadow(color: .black.opacity(0.15), radius: 5, y: 2)
        }
    }
}

// MARK: - Permissions

struct PermissionSettings: View {
    @State private var screen = CGPreflightScreenCaptureAccess()
    @State private var accessibility = AXIsProcessTrusted()
    @State private var input = CGPreflightListenEventAccess()
    // Rechecked while the pane is open: granting happens in System Settings and nothing calls back.
    private let tick = Timer.publish(every: 1.5, tolerance: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                PermissionRow(title: "Screen Recording", symbol: "rectangle.dashed.badge.record", granted: screen,
                              use: "Every capture, the Zoom Lens", pane: "Privacy_ScreenCapture")
                PermissionRow(title: "Accessibility", symbol: "accessibility", granted: accessibility,
                              use: "Auto-scroll in Scrolling Capture, pasting from clipboard history", pane: "Privacy_Accessibility")
                PermissionRow(title: "Input Monitoring", symbol: "keyboard", granted: input,
                              use: "Show Keystrokes", pane: "Privacy_ListenEvent")
            } footer: {
                Text("Glint asks for each one the first time a feature needs it. Nothing is recorded, stored or sent: captures stay in your Pictures folder.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .onReceive(tick) { _ in
            screen = CGPreflightScreenCaptureAccess()
            accessibility = AXIsProcessTrusted()
            input = CGPreflightListenEventAccess()
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let symbol: String
    let granted: Bool
    let use: String
    let pane: String

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(Color(hex: 0x34C759))
            } else {
                Button("Open System Settings") {
                    if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
                }
            }
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(use).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } icon: { Image(systemName: symbol) }
        }
    }
}
