import SwiftUI
import AppKit
import ApplicationServices
import Carbon.HIToolbox

@main
struct GlintApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = Library.shared

    var body: some Scene {
        Window("Glint", id: "home") {
            HomeView()
                .environmentObject(library)
                .frame(minWidth: 780, minHeight: 540)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1000, height: 680)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Image…") { AppController.shared.openImageFile() }
                    .keyboardShortcut("o")
                Button("Edit Clipboard Image") { AppController.shared.openClipboard() }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandMenu("Capture") { CaptureMenuItems() }
        }

        Settings { SettingsView() }

        MenuBarExtra {
            CaptureMenuItems()
            Divider()
            PresentMenuItems()
            Divider()
            ClipboardMenu(history: ClipboardHistory.shared)
            Button("Edit Clipboard Image") { AppController.shared.openClipboard() }
            Button("Open Image…") { AppController.shared.openImageFile() }
            Divider()
            OpenHomeButton()
            ShutterSoundMenuToggle()
            SettingsLink { Text("Settings…") }
            Divider()
            Button("Quit Glint") { NSApp.terminate(nil) }
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
    }
}

struct CaptureMenuItems: View {
    @ObservedObject private var hotkeys = HotkeyStore.shared
    var body: some View {
        ForEach(CaptureKind.allCases) { kind in
            if let hk = hotkeys.hotkey(.capture(kind)), let key = hk.keyEquivalent {
                Button(kind.title) { AppController.shared.run(kind) }
                    .keyboardShortcut(key, modifiers: hk.eventModifiers)
            } else {
                Button(kind.title) { AppController.shared.run(kind) }
            }
        }
    }
}

struct ShutterSoundMenuToggle: View {
    @AppStorage("playSound") private var playSound = true
    var body: some View { Toggle("Shutter Sound", isOn: $playSound) }
}

struct OpenHomeButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Open Glint") {
            HomeWindow.openAction = HomeWindow.openAction ?? openWindow
            HomeWindow.show()
        }
    }
}

/// Brings the main window back from anywhere (Dock click, menu bar), even after it was closed.
/// SwiftUI's own reopen skips this whenever any other Glint window exists (e.g. the menu bar item).
@MainActor
enum HomeWindow {
    static var openAction: OpenWindowAction?

    static var window: NSWindow? {
        NSApp.windows.first { $0.title == "Glint" && $0.identifier != GlintChrome.id && !($0 is NSPanel) }
    }

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let w = window {
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openAction?(id: "home")
        }
    }
}

enum CaptureKind: String, CaseIterable, Identifiable {
    case area, fullscreen, window, scroll, text, color, repeatArea, delayed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: "Capture Area"
        case .fullscreen: "Capture Screen"
        case .window: "Capture Window"
        case .text: "Copy Text from Screen"
        case .color: "Pick Color"
        case .scroll: "Scrolling Capture"
        case .repeatArea: "Repeat Last Area"
        case .delayed: "Delayed Capture (3s)"
        }
    }

    var short: String {
        switch self {
        case .area: "Area"
        case .fullscreen: "Screen"
        case .window: "Window"
        case .text: "Grab Text"
        case .color: "Color Picker"
        case .scroll: "Scrolling"
        case .repeatArea: "Repeat Area"
        case .delayed: "Timer"
        }
    }

    var subtitle: String {
        switch self {
        case .area: "Drag to select an area"
        case .fullscreen: "The display under the cursor"
        case .window: "Crisp, with transparency"
        case .text: "OCR & QR codes to clipboard"
        case .color: "Click any pixel to copy its hex"
        case .scroll: "Auto-scrolls; stop where you want"
        case .repeatArea: "Same region as last time"
        case .delayed: "3-second countdown"
        }
    }

    var symbol: String {
        switch self {
        case .area: "viewfinder"
        case .fullscreen: "display"
        case .window: "macwindow"
        case .text: "text.viewfinder"
        case .color: "eyedropper.halffull"
        case .scroll: "arrow.down.to.line.compact"
        case .repeatArea: "arrow.clockwise"
        case .delayed: "timer"
        }
    }

    var colors: [Color] {
        switch self {
        case .area: [Color(hex: 0x7C5CFF), Color(hex: 0xC145F5)]
        case .fullscreen: [Color(hex: 0x2F80ED), Color(hex: 0x56CCF2)]
        case .window: [Color(hex: 0x11B886), Color(hex: 0x5EE2A0)]
        case .text: [Color(hex: 0xFF8A00), Color(hex: 0xFFC94D)]
        case .color: [Color(hex: 0x0D9488), Color(hex: 0x5EEAD4)]
        case .scroll: [Color(hex: 0x4F46E5), Color(hex: 0x818CF8)]
        case .repeatArea: [Color(hex: 0xF5468E), Color(hex: 0xFF8CB3)]
        case .delayed: [Color(hex: 0x5B6B8C), Color(hex: 0x95A3BF)]
        }
    }

    @MainActor var shortcutLabel: String { HotkeyStore.shared.label(.capture(self)) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    override init() {
        super.init()
        Prefs.registerDefaults()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        HotKeyCenter.shared.install()
        HotkeyStore.shared.apply()
        ClipboardHistory.shared.start()
        Presenter.shared.restore()
        try? FileManager.default.createDirectory(at: Prefs.saveFolder, withIntermediateDirectories: true)
        Library.shared.reload()
        if let dir = ProcessInfo.processInfo.environment["GLINT_SNAPSHOT"] { DebugSnapshot.run(into: dir) }
        if let dir = ProcessInfo.processInfo.environment["GLINT_STITCH_TEST"] { DebugSnapshot.stitchTest(into: dir) }
        if ProcessInfo.processInfo.environment["GLINT_HOTKEY_TEST"] != nil { DebugSnapshot.hotkeyTest() }
        if ProcessInfo.processInfo.environment["GLINT_PERF"] != nil { DebugSnapshot.perfTest() }
        if let dir = ProcessInfo.processInfo.environment["GLINT_PRESENT_TEST"] { DebugPresent.run(into: dir) }
        // GLINT_CLOSE_HOME=1: close the home window shortly after launch (reopen testing).
        if ProcessInfo.processInfo.environment["GLINT_CLOSE_HOME"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                NSApp.windows.first { $0.title == "Glint" && $0.isVisible }?.performClose(nil)
            }
        }
        // GLINT_DELIVER_TEST=<png>: run an image through the normal after-capture pipeline.
        if let path = ProcessInfo.processInfo.environment["GLINT_DELIVER_TEST"], let shot = ImageStore.load(url: URL(fileURLWithPath: path)) {
            AppController.shared.deliver(shot.image, scale: shot.scale)
        }
        // GLINT_PERMCHECK=1: print whether macOS still recognises this build's permission grants.
        if ProcessInfo.processInfo.environment["GLINT_PERMCHECK"] != nil {
            print("PERMCHECK screenRecording=\(CGPreflightScreenCaptureAccess()) accessibility=\(AXIsProcessTrusted())")
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        ImageStore.resolvePendingCopy()
    }

    /// Dock icon click: always bring the main window back if it isn't showing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if HomeWindow.window?.isVisible != true { HomeWindow.show() }
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { AppController.shared.openImage(url: url) }
    }
}
