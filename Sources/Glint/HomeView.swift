import AppKit
import SwiftUI
import ServiceManagement

// MARK: - Library

/// Text captured with OCR / QR scanning.
struct TextEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var text: String
    var isCode: Bool
}

enum LibraryEntry: Identifiable {
    case image(URL, Date)
    case text(TextEntry)

    var id: String {
        switch self {
        case let .image(u, _): "img:" + u.path
        case let .text(t): "txt:" + t.id.uuidString
        }
    }
    var date: Date {
        switch self {
        case let .image(_, d): d
        case let .text(t): t.date
        }
    }
}

@MainActor
final class Library: ObservableObject {
    static let shared = Library()
    @Published private(set) var images: [(url: URL, date: Date)] = []
    @Published private(set) var texts: [TextEntry] = []
    private var loadedTexts = false

    var items: [URL] { images.map(\.url) }

    var entries: [LibraryEntry] {
        (images.map { LibraryEntry.image($0.url, $0.date) } + texts.map { LibraryEntry.text($0) })
            .sorted { $0.date > $1.date }
    }

    private var textFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Glint", isDirectory: true).appendingPathComponent("text-history.json")
    }

    func reload() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey]
        let urls = (try? fm.contentsOfDirectory(at: Prefs.saveFolder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])) ?? []
        images = urls
            .filter { ["png", "jpg", "jpeg", "heic", "gif"].contains($0.pathExtension.lowercased()) }
            .map { ($0, (try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
            .sorted { $0.1 > $1.1 }
        if !loadedTexts {
            loadedTexts = true
            if let d = try? Data(contentsOf: textFile), let t = try? JSONDecoder().decode([TextEntry].self, from: d) { texts = t }
        }
    }

    func addText(_ s: String, isCode: Bool) {
        reload()
        texts.insert(TextEntry(date: Date(), text: s, isCode: isCode), at: 0)
        saveTexts()
    }

    private func saveTexts() {
        try? FileManager.default.createDirectory(at: textFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(texts) { try? d.write(to: textFile, options: .atomic) }
    }

    /// Images go to the Trash (recoverable); text entries are removed from the history.
    func delete(ids: Set<String>) {
        let urls = images.map(\.url).filter { ids.contains("img:" + $0.path) }
        let before = texts.count
        texts.removeAll { ids.contains("txt:" + $0.id.uuidString) }
        if texts.count != before { saveTexts() }
        if urls.isEmpty { reload(); return }
        urls.forEach { ThumbCache.cache.removeObject(forKey: $0 as NSURL) }
        NSWorkspace.shared.recycle(urls) { _, _ in Task { @MainActor in self.reload() } }
    }

    func trash(_ url: URL) { delete(ids: ["img:" + url.path]) }
}

enum ThumbCache {
    static let cache = NSCache<NSURL, NSImage>()
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var library: Library
    @Environment(\.openWindow) private var openWindow
    @State private var hasPermission = CGPreflightScreenCaptureAccess()
    @State private var filter: RecentFilter = .all
    @State private var selecting = false
    @State private var selection: Set<String> = []

    enum RecentFilter: String, CaseIterable { case all = "All", images = "Images", text = "Text" }

    private var visible: [LibraryEntry] {
        library.entries.filter { e in
            switch (filter, e) {
            case (.all, _), (.images, .image), (.text, .text): true
            default: false
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 220), spacing: 12)]
    private let gallery = [GridItem(.adaptive(minimum: 190, maximum: 280), spacing: 16)]

    var body: some View {
        ZStack {
            Background()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if !hasPermission { permissionBanner }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(CaptureKind.allCases) { ActionTile(kind: $0) }
                    }
                    PresentSection()
                    ClipboardSection(history: ClipboardHistory.shared)
                    recentHeader
                    let shown = visible
                    if shown.isEmpty {
                        EmptyLibrary(filter: filter)
                    } else {
                        LazyVGrid(columns: gallery, spacing: 18) {
                            ForEach(shown) { entry in
                                let sel = selection.contains(entry.id)
                                let toggle = { if sel { selection.remove(entry.id) } else { selection.insert(entry.id) } }
                                switch entry {
                                case let .image(url, _):
                                    LibraryTile(url: url, selecting: selecting, selected: sel, toggle: toggle)
                                case let .text(t):
                                    TextTile(entry: t, selecting: selecting, selected: sel, toggle: toggle)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 40)
                .padding(.bottom, 32)
            }
        }
        .focusEffectDisabled()
        .onAppear {
            library.reload()
            HomeWindow.openAction = openWindow // lets the Dock icon reopen this window later
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasPermission = CGPreflightScreenCaptureAccess()
            library.reload()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 54, height: 54)
                .shadow(color: Color(hex: 0x7C5CFF).opacity(0.35), radius: 10, y: 4)
            VStack(alignment: .leading, spacing: 2) {
                Text("Glint")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Capture, annotate and share — beautifully.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { AppController.shared.openImageFile() } label: {
                Label("Open Image", systemImage: "photo.on.rectangle")
            }
            .buttonStyle(PillButtonStyle(prominent: false))
            SoundToggle()
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 14, weight: .semibold)).frame(width: 14)
            }
            .buttonStyle(PillButtonStyle(prominent: false))
            .help("Settings")
        }
    }

    private var permissionBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 22))
                .foregroundStyle(Color(hex: 0xFF9500))
            VStack(alignment: .leading, spacing: 2) {
                Text("Screen Recording permission needed").font(.system(size: 13.5, weight: .semibold))
                Text("macOS requires it for any screenshot app. Enable Glint, then relaunch.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant Access") {
                CGRequestScreenCaptureAccess()
                AppController.openPrivacySettings()
            }
            .buttonStyle(PillButtonStyle(prominent: true))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(hex: 0xFF9500).opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(hex: 0xFF9500).opacity(0.3)))
    }

    private var recentHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Recent captures")
                .font(.system(size: 17, weight: .semibold, design: .rounded))
            Text("\(visible.count)")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(.primary.opacity(0.08)))
            Picker("", selection: $filter) {
                ForEach(RecentFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            .padding(.leading, 6)
            Spacer()
            if selecting {
                let ids = Set(visible.map(\.id))
                let all = !ids.isEmpty && ids.isSubset(of: selection)
                HeaderButton(title: all ? "Deselect All" : "Select All", symbol: all ? "circle" : "checkmark.circle") {
                    if all { selection.subtract(ids) } else { selection.formUnion(ids) }
                }
                HeaderButton(title: selection.isEmpty ? "Delete" : "Delete (\(selection.count))", symbol: "trash", destructive: true) {
                    deleteSelected()
                }
                .disabled(selection.isEmpty)
                HeaderButton(title: "Done", symbol: "checkmark", prominent: true) { selecting = false; selection = [] }
            } else {
                HeaderButton(title: "Select", symbol: "checkmark.circle") { selecting = true }
                    .disabled(library.entries.isEmpty)
                HeaderButton(title: "Delete All", symbol: "trash", destructive: true) { deleteAll() }
                    .disabled(library.entries.isEmpty)
                HeaderButton(title: "Open Folder", symbol: "folder") {
                    try? FileManager.default.createDirectory(at: Prefs.saveFolder, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(Prefs.saveFolder)
                }
            }
        }
        .padding(.top, 4)
        .onChange(of: filter) { _, _ in selection = selection.intersection(Set(visible.map(\.id))) }
    }

    private func describe(_ ids: Set<String>) -> String {
        let imgs = ids.filter { $0.hasPrefix("img:") }.count, txt = ids.count - imgs
        var parts: [String] = []
        if imgs > 0 { parts.append("\(imgs) image\(imgs == 1 ? "" : "s")") }
        if txt > 0 { parts.append("\(txt) text capture\(txt == 1 ? "" : "s")") }
        return parts.joined(separator: " and ")
    }

    private func confirm(_ title: String, _ ids: Set<String>) -> Bool {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = "This removes \(describe(ids)). Images are moved to the Trash, so you can still recover them there."
        a.alertStyle = .warning
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        return a.runModal() == .alertFirstButtonReturn
    }

    private func deleteSelected() {
        guard !selection.isEmpty, confirm("Delete \(selection.count) selected item\(selection.count == 1 ? "" : "s")?", selection) else { return }
        library.delete(ids: selection)
        selection = []
        selecting = false
    }

    private func deleteAll() {
        let ids = Set(library.entries.map(\.id))
        guard confirm("Delete all captures?", ids) else { return }
        library.delete(ids: ids)
    }
}

/// One-click mute for the shutter sound (handy during calls).
struct SoundToggle: View {
    @AppStorage("playSound") private var playSound = true
    var body: some View {
        Button { playSound.toggle() } label: {
            Image(systemName: playSound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(playSound ? Color.primary : Color(hex: 0xFF3B30))
                .frame(width: 18)
        }
        .buttonStyle(PillButtonStyle(prominent: false))
        .help(playSound ? "Shutter sound on — click to mute" : "Shutter sound muted — click to turn on")
    }
}

struct Background: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color(hex: 0x7C5CFF).opacity(0.16), .clear], center: .topLeading, startRadius: 0, endRadius: 520)
            RadialGradient(colors: [Color(hex: 0xEC4899).opacity(0.10), .clear], center: .topTrailing, startRadius: 0, endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

struct ActionTile: View {
    let kind: CaptureKind
    @ObservedObject private var hotkeys = HotkeyStore.shared
    @State private var hover = false

    var body: some View {
        Button { AppController.shared.run(kind) } label: {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(colors: kind.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                        Image(systemName: kind.symbol)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 36, height: 36)
                    .shadow(color: kind.colors[0].opacity(0.4), radius: hover ? 8 : 4, y: 2)
                    Spacer()
                    Text(kind.shortcutLabel)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.primary.opacity(0.06)))
                }
                Spacer(minLength: 14)
                Text(kind.short)
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                Text(kind.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.background.opacity(hover ? 1 : 0.75)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.primary.opacity(hover ? 0.12 : 0.07)))
            .shadow(color: .black.opacity(hover ? 0.12 : 0.04), radius: hover ? 14 : 6, y: hover ? 6 : 2)
            .scaleEffect(hover ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) { hover = h } }
    }
}

struct LibraryTile: View {
    let url: URL
    var selecting = false
    var selected = false
    var toggle: () -> Void = {}
    @State private var image: NSImage?
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.primary.opacity(0.05))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                        .padding(10)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(height: 140)
            .overlay(TileBorder(hover: hover, selected: selected))
            .overlay(alignment: .topLeading) { if selecting { SelectBadge(selected: selected) } }
            .overlay(alignment: .topTrailing) {
                if hover && !selecting {
                    HStack(spacing: 4) {
                        MiniButton(symbol: "doc.on.doc", help: "Copy") { copy() }
                        MiniButton(symbol: "pin", help: "Pin") { if let s = ImageStore.load(url: url) { PinWindow.show(s) } }
                    }
                    .padding(8)
                    .transition(.opacity)
                }
            }
            Text(url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "Glint ", with: ""))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onTapGesture(count: 1) { if selecting { toggle() } else { AppController.shared.openImage(url: url) } }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Annotate") { AppController.shared.openImage(url: url) }
            Button("Copy") { copy() }
            Button("Pin to Screen") { if let s = ImageStore.load(url: url) { PinWindow.show(s) } }
            Button("Copy Text (OCR)") {
                if let s = ImageStore.load(url: url) { Task { await AppController.shared.recognize(s.image) } }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Button("Move to Trash") { Library.shared.trash(url) }
        }
        .task(id: url) { await load() }
    }

    private func copy() {
        if let s = ImageStore.load(url: url) { ImageStore.copy(s.image, scale: s.scale); Toast.show("Copied to clipboard") }
    }

    private func load() async {
        if let c = ThumbCache.cache.object(forKey: url as NSURL) { image = c; return }
        let u = url
        let cg = await Task.detached(priority: .utility) { ImageStore.thumbnail(url: u, maxPixel: 560) }.value
        guard let cg else { return }
        let img = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
        ThumbCache.cache.setObject(img, forKey: url as NSURL)
        image = img
    }
}

struct TileBorder: View {
    let hover: Bool
    let selected: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : (hover ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.07)),
                          lineWidth: selected ? 3 : (hover ? 2 : 1))
    }
}

struct SelectBadge: View {
    let selected: Bool
    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 20, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(selected ? Color.white : Color.white.opacity(0.95), selected ? Color.accentColor : Color.black.opacity(0.35))
            .background(Circle().fill(selected ? Color.accentColor : Color.black.opacity(0.25)).padding(2))
            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
            .padding(8)
    }
}

/// A captured-text (OCR / QR) entry in the Recent grid.
struct TextTile: View {
    let entry: TextEntry
    var selecting = false
    var selected = false
    var toggle: () -> Void = {}
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: entry.isCode ? "qrcode" : "text.viewfinder")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(LinearGradient(colors: [Color(hex: 0xFF8A00), Color(hex: 0xFFC94D)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    Text(entry.isCode ? "QR code" : "Text")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(entry.text.split(separator: "\n").count) line\(entry.text.split(separator: "\n").count == 1 ? "" : "s")")
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(entry.text)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(12)
            .frame(height: 140)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.opacity(0.8)))
            .overlay(TileBorder(hover: hover, selected: selected))
            .overlay(alignment: .topLeading) { if selecting { SelectBadge(selected: selected).offset(x: -6, y: -6) } }
            .overlay(alignment: .bottomTrailing) {
                if hover && !selecting {
                    MiniButton(symbol: "doc.on.doc", help: "Copy text") { copy() }.padding(8)
                }
            }
            Text(ImageStore.nameFormatter.string(from: entry.date))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hover = h } }
        .onTapGesture { if selecting { toggle() } else { copy() } }
        .onDrag { NSItemProvider(object: entry.text as NSString) }
        .help(selecting ? "" : "Click to copy")
        .contextMenu {
            Button("Copy") { copy() }
            if entry.isCode, let u = URL(string: entry.text), u.scheme?.hasPrefix("http") == true {
                Button("Open Link") { NSWorkspace.shared.open(u) }
            }
            Divider()
            Button("Delete") { Library.shared.delete(ids: ["txt:" + entry.id.uuidString]) }
        }
    }

    private func copy() {
        ImageStore.copyText(entry.text)
        Toast.show("Text copied", symbol: "doc.on.doc.fill")
    }
}

struct HeaderButton: View {
    let title: String
    let symbol: String
    var destructive = false
    var prominent = false
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5, weight: .semibold))
                .padding(.horizontal, 10)
                .frame(height: 28)
                .foregroundStyle(prominent ? Color.white : (destructive ? Color(hex: 0xFF3B30) : Color.primary.opacity(0.75)))
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(hover ? 0.1 : 0.05))))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct MiniButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct EmptyLibrary: View {
    var filter: HomeView.RecentFilter = .all
    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(hex: 0x7C5CFF).opacity(0.18), Color(hex: 0xEC4899).opacity(0.12)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 84, height: 84)
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(LinearGradient(colors: [Color(hex: 0x7C5CFF), Color(hex: 0xEC4899)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            Text(filter == .text ? "No captured text yet" : "No captures yet").font(.system(size: 15, weight: .semibold, design: .rounded))
            Text(filter == .text ? "Press \(CaptureKind.text.shortcutLabel) and select any text on screen.\nIt will show up here." : "Press \(CaptureKind.area.shortcutLabel) anywhere to capture an area.\nYour shots will show up here.")
                .multilineTextAlignment(.center)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 50)
    }
}

// MARK: - Settings

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            PresentSettings().tabItem { Label("Presenting", systemImage: "cursorarrow.rays") }
            ShortcutSettings().tabItem { Label("Shortcuts", systemImage: "command") }
            AboutSettings().tabItem { Label("About", systemImage: "sparkles") }
        }
        .frame(width: 600, height: 560)
    }
}

struct GeneralSettings: View {
    @AppStorage("afterCapture") private var after = "editor"
    @AppStorage("autoCopy") private var autoCopy = true
    @AppStorage("autoSave") private var autoSave = true
    @AppStorage("playSound") private var playSound = true
    @AppStorage("downscaleRetina") private var downscale = false
    @AppStorage("clipboardHistory") private var clipboardHistory = true
    @State private var folder = Prefs.saveFolder
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("After capture") {
                Picker("Show", selection: $after) {
                    Text("Editor").tag("editor")
                    Text("Floating thumbnail").tag("thumbnail")
                    Text("Nothing").tag("nothing")
                }
                Toggle("Copy to clipboard", isOn: $autoCopy)
                Toggle("Save to folder", isOn: $autoSave)
                Toggle("Play shutter sound", isOn: $playSound)
                Toggle("Downscale Retina captures to 1×", isOn: $downscale)
            }
            Section("Storage") {
                LabeledContent("Folder") {
                    HStack {
                        Text(folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") { choose() }
                    }
                }
            }
            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Toggle("Keep clipboard history (last \(ClipboardHistory.limit) text items)", isOn: $clipboardHistory)
                LabeledContent("Screen Recording") {
                    Button("Open Privacy Settings") { AppController.openPrivacySettings() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = folder
        if p.runModal() == .OK, let u = p.url {
            Prefs.saveFolder = u
            folder = u
            Library.shared.reload()
        }
    }
}

struct ShortcutSettings: View {
    @ObservedObject private var store = HotkeyStore.shared

    var body: some View {
        Form {
            Section {
                ForEach(HotkeyAction.all) { a in
                    LabeledContent {
                        ShortcutRecorder(action: a)
                    } label: {
                        Label(a.title, systemImage: a.symbol)
                    }
                }
            } header: {
                Text("Global shortcuts")
            } footer: {
                HStack {
                    Text("Click a shortcut, then press the new keys. ⌫ removes it, esc cancels.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Restore Defaults") { store.resetAll() }
                        .disabled(!store.isCustomized)
                }
            }
            Section("Clipboard") {
                LabeledContent("Paste from history") { Text("\(store.label(.clipboard)), then 1–9 or ⏎").foregroundStyle(.secondary) }
                LabeledContent("Copy without pasting") { Text("⌘⏎").foregroundStyle(.secondary) }
            }
            Section("Editor") {
                LabeledContent("Tools") { Text("V A L R O D H T N Q B S Z M I X").font(.system(.body, design: .monospaced)).foregroundStyle(.secondary) }
                LabeledContent("Colors") { Text("1 – 8").foregroundStyle(.secondary) }
                LabeledContent("Copy color under cursor") { Text("⇥ hex · ⇧⇥ rgb").foregroundStyle(.secondary) }
                LabeledContent("Backdrop") { Text("K").foregroundStyle(.secondary) }
                LabeledContent("Step label") { Text("Opens on placement · double-click to edit").foregroundStyle(.secondary) }
                LabeledContent("Step pointer") { Text("Drag from the number").foregroundStyle(.secondary) }
                LabeledContent("Copy · Save · Pin") { Text("⌘C · ⌘S · ⌘P").foregroundStyle(.secondary) }
                LabeledContent("Constrain / 45°") { Text("Hold ⇧").foregroundStyle(.secondary) }
            }
            Section("Pinned images") {
                LabeledContent("Resize · Opacity") { Text("Scroll · ⌥ Scroll").foregroundStyle(.secondary) }
                LabeledContent("Close") { Text("Double-click or Esc").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text("Glint").font(.system(size: 24, weight: .bold, design: .rounded))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                .foregroundStyle(.secondary)
            Text("Screenshots, annotations, OCR and pins —\nfast, native and beautiful.")
                .multilineTextAlignment(.center)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
