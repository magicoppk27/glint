import AppKit
import SwiftUI

@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate {
    static var open: [EditorWindowController] = []
    let model: EditorModel

    static func show(_ shot: Shot) {
        let wc = EditorWindowController(model: EditorModel(shot: shot))
        open.append(wc)
        NSApp.activate(ignoringOtherApps: true)
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
    }

    init(model: EditorModel) {
        self.model = model
        let vf = NSScreen.withMouse.visibleFrame
        let pt = CGSize(width: CGFloat(model.base.width) / model.scale, height: CGFloat(model.base.height) / model.scale)
        let chromeW = CanvasInsets.left + CanvasInsets.right, chromeH = CanvasInsets.top + CanvasInsets.bottom
        let z = min(1, (vf.width * 0.86 - chromeW) / pt.width, (vf.height * 0.86 - chromeH) / pt.height)
        let w = max(820, pt.width * z + chromeW), h = max(560, pt.height * z + chromeH)
        let win = NSWindow(contentRect: CGRect(x: 0, y: 0, width: w, height: h),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.title = "Glint Editor"
        win.isReleasedWhenClosed = false
        win.minSize = CGSize(width: 780, height: 520)
        win.backgroundColor = .underPageBackgroundColor
        win.contentView = NSHostingView(rootView: EditorView(model: model))
        win.center()
        super.init(window: win)
        win.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        EditorWindowController.open.removeAll { $0 === self }
    }
}

struct EditorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(nsColor: .underPageBackgroundColor)
            DotGrid().opacity(0.5)
            CanvasRepresentable(model: model)

            // Top row: style controls + actions
            HStack(spacing: 10) {
                StylePill(model: model)
                ColorReadout(hover: model.hover)
                Spacer(minLength: 8)
                ActionsPill(model: model)
            }
            .padding(.leading, CanvasInsets.left)
            .padding(.trailing, 16)
            .padding(.top, 36)

            // Left rail: tools
            VStack {
                Spacer(minLength: 84)
                ToolRail(model: model)
                Spacer(minLength: 20)
            }
            .padding(.leading, 14)

            // Bottom: crop bar
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    if model.pendingCrop != nil {
                        CropBar(apply: model.applyCrop, cancel: { model.pendingCrop = nil })
                    } else if model.crop != nil && model.tool == .crop {
                        Button("Reset Crop") { model.resetCrop() }.buttonStyle(PillButtonStyle(prominent: false))
                    }
                    Spacer()
                }
                .padding(.bottom, 20)
            }
            .allowsHitTesting(model.pendingCrop != nil || model.crop != nil)

            // Title (non-interactive, sits in the titlebar)
            HStack {
                Spacer()
                Text("\(Int(model.outputSize.width)) × \(Int(model.outputSize.height))")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
            }
            .padding(.top, 8)
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
        .focusEffectDisabled()
    }
}

struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let step: CGFloat = 18
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)), with: .color(.primary.opacity(0.12)))
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

struct Pill<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(5)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

struct ToolRail: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        Pill {
            VStack(spacing: 2) {
                ForEach(Tool.allCases) { t in
                    IconButton(symbol: t.symbol, selected: model.tool == t, help: "\(t.label)  (\(t.key.uppercased()))") {
                        model.tool = t
                    }
                    if t == .select || t == .text || t == .picker { Divider().frame(width: 22).padding(.vertical, 3) }
                }
            }
        }
    }
}

struct IconButton: View {
    let symbol: String
    var selected = false
    var disabled = false
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 30)
                .foregroundStyle(selected ? Color.white : Color.primary.opacity(disabled ? 0.3 : 0.85))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(selected ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x7C5CFF), Color(hex: 0xB04BF2)], startPoint: .topLeading, endPoint: .bottomTrailing))
                              : AnyShapeStyle(Color.primary.opacity(hover && !disabled ? 0.08 : 0)))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .onHover { hover = $0 }
    }
}

struct StylePill: View {
    @ObservedObject var model: EditorModel
    @State private var showBackdrop = false

    var body: some View {
        Pill {
            HStack(spacing: 4) {
                ForEach(Array(palette.enumerated()), id: \.offset) { i, c in
                    Button { model.colorIndex = i } label: {
                        Circle()
                            .fill(Color(nsColor: c))
                            .overlay(Circle().strokeBorder(.primary.opacity(0.18), lineWidth: 1))
                            .frame(width: 17, height: 17)
                            .padding(3)
                            .overlay(Circle().strokeBorder(model.colorIndex == i ? Color.accentColor : .clear, lineWidth: 2))
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Color \(i + 1)")
                }
                Divider().frame(height: 20).padding(.horizontal, 4)
                ForEach(0..<3) { i in
                    Button { model.sizeIndex = i } label: {
                        Circle()
                            .fill(Color.primary.opacity(model.sizeIndex == i ? 0.9 : 0.4))
                            .frame(width: CGFloat(5 + i * 4), height: CGFloat(5 + i * 4))
                            .frame(width: 26, height: 28)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(model.sizeIndex == i ? 0.1 : 0)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(["Thin", "Medium", "Bold"][i])
                }
                Divider().frame(height: 20).padding(.horizontal, 4)
                IconButton(symbol: "sparkles.rectangle.stack", selected: model.backdrop.enabled, help: "Backdrop  (K)") {
                    showBackdrop.toggle()
                }
                .popover(isPresented: $showBackdrop, arrowEdge: .bottom) { BackdropPanel(model: model) }
            }
        }
    }
}

struct BackdropPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle(isOn: $model.backdrop.enabled) {
                Text("Backdrop").font(.system(size: 13, weight: .semibold))
            }
            .toggleStyle(.switch)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(40), spacing: 10), count: 4), spacing: 10) {
                ForEach(Array(Backdrop.presets.enumerated()), id: \.offset) { i, p in
                    Button {
                        model.backdrop.preset = i
                        model.backdrop.enabled = true
                    } label: {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(LinearGradient(colors: [Color(nsColor: p.a), Color(nsColor: p.b)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 40, height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(model.backdrop.preset == i && model.backdrop.enabled ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help(p.name)
                }
            }

            LabeledSlider(title: "Padding", value: $model.backdrop.padding, range: 8...160)
            LabeledSlider(title: "Corners", value: $model.backdrop.radius, range: 0...36)
            Toggle("Drop shadow", isOn: $model.backdrop.shadow)
        }
        .padding(16)
        .frame(width: 230)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(value))").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

struct ActionsPill: View {
    @ObservedObject var model: EditorModel
    @Environment(\.controlActiveState) private var active

    var body: some View {
        HStack(spacing: 8) {
            Pill {
                HStack(spacing: 2) {
                    IconButton(symbol: "arrow.uturn.backward", disabled: !model.canUndo, help: "Undo  ⌘Z") { model.undo() }
                        .keyboardShortcut("z", modifiers: .command)
                    IconButton(symbol: "arrow.uturn.forward", disabled: !model.canRedo, help: "Redo  ⇧⌘Z") { model.redo() }
                        .keyboardShortcut("z", modifiers: [.command, .shift])
                }
            }
            Pill {
                HStack(spacing: 2) {
                    IconButton(symbol: "text.viewfinder", help: "Copy text (OCR)") { model.ocr() }
                    IconButton(symbol: "pin", help: "Pin to screen  ⌘P") { model.pin() }
                        .keyboardShortcut("p", modifiers: .command)
                    IconButton(symbol: "square.and.arrow.down", help: "Save to Glint folder  ⌘S") { model.save() }
                        .keyboardShortcut("s", modifiers: .command)
                    IconButton(symbol: "square.and.arrow.down.on.square", help: "Save As…  ⇧⌘S") { model.saveAs(from: NSApp.keyWindow) }
                        .keyboardShortcut("s", modifiers: [.command, .shift])
                }
            }
            DragHandle(model: model)
            Button { model.copy() } label: {
                Label("Copy", systemImage: "doc.on.doc.fill")
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .keyboardShortcut("c", modifiers: .command)
            .help("Copy to clipboard  ⌘C")
        }
    }
}

/// Drag this into any app (Slack, Mail, Figma, Finder…) to drop the annotated image.
struct DragHandle: View {
    @ObservedObject var model: EditorModel
    @State private var hover = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "hand.draw.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("Drag")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
        }
        .padding(.horizontal, 13)
        .frame(height: 40)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .strokeBorder(hover ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), style: StrokeStyle(lineWidth: 1, dash: hover ? [4, 3] : [])))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .contentShape(Rectangle())
        .onHover { h in
            hover = h
            if h { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .onDrag { model.dragProvider() }
        .help("Drag the image into any app")
    }
}

struct ColorReadout: View {
    @ObservedObject var hover: HoverColor

    var body: some View {
        if let c = hover.color {
            Pill {
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color(nsColor: c))
                        .overlay(Circle().strokeBorder(.primary.opacity(0.2)))
                        .frame(width: 18, height: 18)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(c.hexString).font(.system(size: 12, weight: .semibold, design: .monospaced))
                        Text("⇥ copy · ⇧⇥ rgb").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 6)
                .frame(height: 30)
            }
            .help("Color under the cursor. Press Tab to copy hex, Shift-Tab for rgb(), or use the eyedropper (I).")
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    var prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .padding(.horizontal, 14)
            .frame(height: 40)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(LinearGradient(colors: [Color(hex: 0x7C5CFF), Color(hex: 0xC145F5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(.regularMaterial))
            )
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(.white.opacity(prominent ? 0.2 : 0.08)))
            .shadow(color: (prominent ? Color(hex: 0x7C5CFF) : .black).opacity(0.25), radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Rectangle())
    }
}

struct CropBar: View {
    let apply: () -> Void
    let cancel: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button("Cancel", action: cancel).buttonStyle(PillButtonStyle(prominent: false))
            Button(action: apply) { Label("Apply Crop", systemImage: "checkmark") }
                .buttonStyle(PillButtonStyle(prominent: true))
        }
    }
}
