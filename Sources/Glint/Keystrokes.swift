import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The chips on screen. Shortcuts and special keys each get a chip; plain typing merges into one line.
struct KeystrokeLog {
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var updated: Date
        var isCombo: Bool
    }

    static let maxEntries = 4
    static let lifetime: TimeInterval = 2.0
    static let mergeWindow: TimeInterval = 1.2

    private(set) var entries: [Entry] = []

    mutating func add(_ text: String, combo: Bool, isRepeat: Bool = false, at now: Date = Date()) {
        if combo {
            if isRepeat, let i = entries.indices.last, entries[i].isCombo, entries[i].text == text {
                entries[i].updated = now
            } else {
                entries.append(Entry(text: text, updated: now, isCombo: true))
            }
        } else {
            guard !text.isEmpty else { return }
            if let i = entries.indices.last, !entries[i].isCombo, now.timeIntervalSince(entries[i].updated) < Self.mergeWindow {
                entries[i].text = String((entries[i].text + text).suffix(40))
                entries[i].updated = now
            } else {
                entries.append(Entry(text: text, updated: now, isCombo: false))
            }
        }
        if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
    }

    /// Returns true when something was removed.
    mutating func prune(at now: Date = Date()) -> Bool {
        let n = entries.count
        entries.removeAll { now.timeIntervalSince($0.updated) > Self.lifetime }
        return entries.count != n
    }

    // MARK: Formatting

    private static let special: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Space: "␣",
        kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]

    /// What one key-down shows: (text, isCombo). Space alone is typing; with a modifier it's a combo.
    static func describe(keyCode: Int, flags: CGEventFlags, characters: String, plain: String) -> (String, Bool) {
        let shortcut = flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate)
        let isSpecial = keyCode != kVK_Space && special[keyCode] != nil
        guard shortcut || isSpecial else { return (characters, false) }
        var s = ""
        if flags.contains(.maskControl) { s += "⌃" }
        if flags.contains(.maskAlternate) { s += "⌥" }
        if flags.contains(.maskShift) { s += "⇧" }
        if flags.contains(.maskCommand) { s += "⌘" }
        return (s + (special[keyCode] ?? plain.uppercased()), true)
    }
}

final class KeystrokeModel: ObservableObject {
    @Published var log = KeystrokeLog()
}

/// Shows what you type in a fading overlay near the bottom of the screen with the mouse.
/// A listen-only event tap: needs Input Monitoring, can't change or block keys, and macOS hides
/// keys typed into password fields from it.
@MainActor
final class Keystrokes {
    static let shared = Keystrokes()

    enum Defaults { static let fontSize = 26.0 }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
    static var hasPermission: Bool { CGPreflightListenEventAccess() }

    let model = KeystrokeModel()
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var panel: NSPanel?
    private var pruneTimer: Timer?

    var isShowing: Bool { tap != nil }

    /// Returns false without Input Monitoring (after asking for it).
    @discardableResult
    func show() -> Bool {
        guard tap == nil else { return true }
        if !Self.hasPermission {
            CGRequestListenEventAccess()
            if !Self.hasPermission { Self.permissionAlert(); return false }
        }
        let callback: CGEventTapCallBack = { _, type, event, _ in
            // The tap's run loop source is on the main run loop.
            MainActor.assumeIsolated { Keystrokes.shared.handle(type, event) }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                                        callback: callback, userInfo: nil) else {
            Self.permissionAlert()
            return false
        }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)

        let p = makeOverlayPanel(size: CGSize(width: 900, height: 340))
        let host = NSHostingView(rootView: KeystrokeView(model: model))
        host.sizingOptions = []
        p.contentView = host
        panel = p
        place()
        p.orderFrontRegardless()
        return true
    }

    func hide() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        pruneTimer?.invalidate()
        pruneTimer = nil
        panel?.orderOut(nil)
        panel = nil
        model.log = KeystrokeLog()
    }

    func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown else { return }
        let ns = NSEvent(cgEvent: event)
        let (text, combo) = KeystrokeLog.describe(keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
                                                  characters: ns?.characters ?? "", plain: ns?.charactersIgnoringModifiers ?? "")
        withAnimation(.easeOut(duration: 0.15)) {
            model.log.add(text, combo: combo, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
        }
        place()
        startPruning()
    }

    /// Runs only while chips are showing, so an idle overlay costs no wake-ups.
    private func startPruning() {
        guard pruneTimer == nil else { return }
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                var log = self.model.log
                if log.prune() { withAnimation(.easeIn(duration: 0.3)) { self.model.log = log } }
                if self.model.log.entries.isEmpty { self.pruneTimer?.invalidate(); self.pruneTimer = nil }
            }
        }
        t.tolerance = 0.05
        RunLoop.main.add(t, forMode: .common)
        pruneTimer = t
    }

    /// Follows the screen with the mouse.
    private func place() {
        guard let panel else { return }
        let vf = NSScreen.withMouse.visibleFrame
        panel.setFrameOrigin(NSPoint(x: (vf.midX - panel.frame.width / 2).rounded(), y: vf.minY + 40))
    }

    static func permissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Glint needs Input Monitoring to show keystrokes"
        alert.informativeText = "Turn on Glint in System Settings › Privacy & Security › Input Monitoring, then switch Show Keystrokes on again. Glint only displays keys; nothing is stored or sent."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Not Now")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(settingsURL) }
    }
}

struct KeystrokeView: View {
    @ObservedObject var model: KeystrokeModel
    @AppStorage("keysFontSize") private var fontSize = Keystrokes.Defaults.fontSize

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.log.entries) { e in
                Text(e.text)
                    .font(.system(size: fontSize, weight: .semibold, design: e.isCombo ? .rounded : .default))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .padding(.horizontal, fontSize * 0.7)
                    .padding(.vertical, fontSize * 0.36)
                    .overlaySurface(Capsule(), accent: e.isCombo)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
