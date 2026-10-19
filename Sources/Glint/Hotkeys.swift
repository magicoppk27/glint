import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A global shortcut: Carbon key code + Carbon modifier mask.
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32

    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Hotkey.keyName(keyCode)
    }

    /// For menu items: SwiftUI can only show shortcuts whose key is a character.
    var keyEquivalent: KeyEquivalent? {
        let n = Hotkey.keyName(keyCode)
        guard n.count == 1, let c = n.lowercased().first else { return nil }
        return KeyEquivalent(c)
    }

    var eventModifiers: SwiftUI.EventModifiers {
        var m: SwiftUI.EventModifiers = []
        if modifiers & UInt32(cmdKey) != 0 { m.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { m.insert(.shift) }
        if modifiers & UInt32(optionKey) != 0 { m.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { m.insert(.control) }
        return m
    }

    static func carbonModifiers(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func isFunctionKey(_ code: UInt32) -> Bool {
        (special[Int(code)] ?? "").hasPrefix("F") && special[Int(code)]!.count > 1
    }

    /// The character a key produces on the current keyboard layout, without modifiers.
    static func keyName(_ code: UInt32) -> String {
        if let s = special[Int(code)] { return s }
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var len = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
        }
        guard status == noErr, len > 0 else { return "#\(code)" }
        return String(utf16CodeUnits: chars, count: len).uppercased()
    }
}

/// Everything that can have a global shortcut.
enum HotkeyAction: Hashable, Identifiable {
    case capture(CaptureKind)
    case clipboard

    static var all: [HotkeyAction] { CaptureKind.allCases.map { .capture($0) } + [.clipboard] }

    var id: String {
        switch self {
        case let .capture(k): k.rawValue
        case .clipboard: "clipboard"
        }
    }

    var title: String {
        switch self {
        case let .capture(k): k.title
        case .clipboard: "Clipboard History Picker"
        }
    }

    var symbol: String {
        switch self {
        case let .capture(k): k.symbol
        case .clipboard: "doc.on.clipboard"
        }
    }

    var defaultHotkey: Hotkey? {
        let cs = UInt32(cmdKey | shiftKey)
        switch self {
        case .capture(.fullscreen): return Hotkey(keyCode: UInt32(kVK_ANSI_1), modifiers: cs)
        case .capture(.area): return Hotkey(keyCode: UInt32(kVK_ANSI_2), modifiers: cs)
        case .capture(.window): return Hotkey(keyCode: UInt32(kVK_ANSI_6), modifiers: cs)
        case .capture(.color): return Hotkey(keyCode: UInt32(kVK_ANSI_7), modifiers: cs)
        case .capture(.text): return Hotkey(keyCode: UInt32(kVK_ANSI_8), modifiers: cs)
        case .capture(.repeatArea): return Hotkey(keyCode: UInt32(kVK_ANSI_9), modifiers: cs)
        case .capture(.scroll): return Hotkey(keyCode: UInt32(kVK_ANSI_0), modifiers: cs)
        case .capture(.delayed): return nil
        case .clipboard: return Hotkey(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | controlKey))
        }
    }

    @MainActor func perform() {
        switch self {
        case let .capture(k): AppController.shared.run(k)
        case .clipboard: ClipboardPicker.toggle()
        }
    }
}

/// User-editable global shortcuts, persisted in UserDefaults and registered with Carbon.
@MainActor
final class HotkeyStore: ObservableObject {
    static let shared = HotkeyStore()

    /// Stored overrides: action id → [keyCode, modifiers], or [] when the user removed the shortcut.
    @Published private var overrides: [String: [UInt32]] = [:]
    /// Actions whose shortcut macOS refused (already taken by another app).
    @Published private(set) var failed: Set<String> = []
    @Published var recordingID: String?

    private let key = "hotkeys"

    init() {
        if let d = Prefs.d.data(forKey: key), let o = try? JSONDecoder().decode([String: [UInt32]].self, from: d) { overrides = o }
    }

    func hotkey(_ a: HotkeyAction) -> Hotkey? {
        if let o = overrides[a.id] { return o.count == 2 ? Hotkey(keyCode: o[0], modifiers: o[1]) : nil }
        return a.defaultHotkey
    }

    func label(_ a: HotkeyAction) -> String { hotkey(a)?.display ?? "—" }

    func action(using hk: Hotkey) -> HotkeyAction? { HotkeyAction.all.first { hotkey($0) == hk } }

    /// Returns an error message instead of saving when the shortcut is unusable.
    @discardableResult
    func set(_ hk: Hotkey?, for a: HotkeyAction) -> String? {
        if let hk {
            if let other = action(using: hk), other != a { return "Already used by “\(other.title)”" }
            if hk.modifiers == UInt32(cmdKey | shiftKey), [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5].contains(Int(hk.keyCode)) {
                return "\(hk.display) is reserved by macOS screenshots"
            }
            overrides[a.id] = [hk.keyCode, hk.modifiers]
        } else {
            overrides[a.id] = []
        }
        save()
        apply()
        return nil
    }

    func resetAll() {
        overrides = [:]
        save()
        apply()
    }

    var isCustomized: Bool { !overrides.isEmpty }

    private func save() {
        if let d = try? JSONEncoder().encode(overrides) { Prefs.d.set(d, forKey: key) }
    }

    /// (Re)registers every shortcut with the system.
    func apply() {
        HotKeyCenter.shared.unregisterAll()
        var bad: Set<String> = []
        for (i, a) in HotkeyAction.all.enumerated() {
            guard let hk = hotkey(a) else { continue }
            let ok = HotKeyCenter.shared.register(keyCode: hk.keyCode, modifiers: hk.modifiers, id: UInt32(i + 1)) { a.perform() }
            if !ok { bad.insert(a.id) }
        }
        failed = bad
    }

    /// While recording, global shortcuts are lifted so the keys reach the recorder.
    func suspend() { HotKeyCenter.shared.unregisterAll() }
}

// MARK: - Recorder

struct ShortcutRecorder: View {
    let action: HotkeyAction
    @ObservedObject var store = HotkeyStore.shared
    @State private var monitor: Any?
    @State private var liveMods: NSEvent.ModifierFlags = []
    @State private var error: String?

    private var recording: Bool { store.recordingID == action.id }

    var body: some View {
        HStack(spacing: 6) {
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Color(hex: 0xFF3B30)).lineLimit(1)
            } else if store.failed.contains(action.id) {
                Label("In use by another app", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11)).foregroundStyle(Color(hex: 0xFF9500)).labelStyle(.titleAndIcon)
            }
            Button(action: toggle) {
                Text(recording ? (liveMods.isEmpty ? "Type shortcut…" : Hotkey(keyCode: 0xFFFF, modifiers: Hotkey.carbonModifiers(liveMods)).display.replacingOccurrences(of: "#65535", with: "…"))
                               : store.label(action))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(recording ? Color.accentColor : (store.hotkey(action) == nil ? Color.secondary : Color.primary))
                    .frame(minWidth: 96)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(recording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: recording ? 1.5 : 1))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(recording ? "Press keys · ⌫ removes · esc cancels" : "Click to change")
            if store.hotkey(action) != nil && !recording {
                Button { error = nil; store.set(nil, for: action) } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove shortcut")
            }
        }
        .onDisappear { stop() }
        .onChange(of: store.recordingID) { _, id in if id != action.id { stop(keepState: true) } }
    }

    private func toggle() { recording ? stop() : start() }

    private func start() {
        error = nil
        store.recordingID = action.id
        store.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { e in
            let mods = e.modifierFlags.intersection([.command, .shift, .option, .control])
            if e.type == .flagsChanged { liveMods = mods; return nil }
            let code = UInt32(e.keyCode)
            if mods.isEmpty && code == UInt32(kVK_Escape) { stop(); return nil }
            if mods.isEmpty && (code == UInt32(kVK_Delete) || code == UInt32(kVK_ForwardDelete)) {
                store.set(nil, for: action); stop(); return nil
            }
            let hk = Hotkey(keyCode: code, modifiers: Hotkey.carbonModifiers(mods))
            if mods.intersection([.command, .option, .control]).isEmpty && !Hotkey.isFunctionKey(code) {
                error = "Add ⌘, ⌥ or ⌃ (or use an F-key)"
                NSSound.beep()
                return nil
            }
            error = store.set(hk, for: action)
            if error != nil { NSSound.beep() }
            stop()
            return nil
        }
    }

    private func stop(keepState: Bool = false) {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        liveMods = []
        if !keepState, store.recordingID == action.id { store.recordingID = nil }
        if store.recordingID == nil { store.apply() }
    }
}
