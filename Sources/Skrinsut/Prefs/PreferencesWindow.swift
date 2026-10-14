import AppKit
import ServiceManagement
import SwiftUI

/// System Settings–style window: sidebar (General, Image, Video, Shortcuts) with grouped forms.
final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private init() {
        let host = NSHostingController(rootView: PreferencesView())
        host.sizingOptions = [] // the window sets the size; NavigationSplitView fills it
        let window = NSWindow(contentViewController: host)
        // Sidebar material runs full height, behind the traffic lights; SwiftUI insets the
        // sidebar list and gives the detail pane a scroll-edge blur under the title bar.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.title = "" // no title; an unset title would read "Untitled" in the Window menu
        window.setContentSize(CGSize(width: 720, height: 560))
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Opens Settings, optionally on a specific pane.
    func present(pane: SettingsPane? = nil) {
        if let pane { SettingsNavigation.shared.pane = pane }
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, image, toolbar, video, shortcuts, deepLinks, about, help
    var id: String { rawValue }
    /// Settings proper, then (after a divider) About and Help.
    static let main: [SettingsPane] = [.general, .image, .toolbar, .video, .shortcuts, .deepLinks]
    static let info: [SettingsPane] = [.about, .help]
    var title: String {
        switch self {
        case .general: "General"
        case .image: "Image"
        case .toolbar: "Toolbar"
        case .video: "Video"
        case .shortcuts: "Shortcuts"
        case .deepLinks: "Deep Links"
        case .about: "About"
        case .help: "Help"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .image: "photo.fill"
        case .toolbar: "menubar.rectangle"
        case .video: "video.fill"
        case .shortcuts: "command"
        case .deepLinks: "link"
        case .about: "info"
        case .help: "questionmark"
        }
    }
    var tint: Color {
        switch self {
        case .general: .gray
        case .image: .blue
        case .toolbar: .purple
        case .video: .red
        case .shortcuts: .indigo
        case .deepLinks: .orange
        case .about: .teal
        case .help: .green
        }
    }
}

/// Selected sidebar pane, shared so other parts of the app can deep-link into Settings.
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var pane: SettingsPane? = .general
}

struct PreferencesView: View {
    @ObservedObject private var nav = SettingsNavigation.shared
    private var pane: SettingsPane { nav.pane ?? .general }

    var body: some View {
        NavigationSplitView {
            List(selection: $nav.pane) {
                Section { ForEach(SettingsPane.main, content: row) }
                Section { ForEach(SettingsPane.info, content: row) }
            }
            .navigationSplitViewColumnWidth(215)
        } detail: {
            Group {
                switch pane {
                case .general: GeneralPane()
                case .image: ImagePane()
                case .toolbar: ToolbarPane()
                case .video: VideoPane()
                case .shortcuts: ShortcutsPane()
                case .deepLinks: DeepLinksPane()
                case .about: AboutPane()
                case .help: HelpPane()
                }
            }
            .formStyle(.grouped)
        }
    }

    private func row(_ p: SettingsPane) -> some View {
        Label { Text(p.title) } icon: { SettingsIcon(symbol: p.symbol, tint: p.tint) }
            .tag(p)
    }
}

/// White glyph on a rounded colored square, like System Settings' sidebar icons.
private struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(tint.gradient))
    }
}

// MARK: - General

private struct GeneralPane: View {
    @AppStorage(SettingKey.defaultFolder) private var folder = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section {
                LabeledContent("Save location") {
                    HStack(spacing: 6) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: folder))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text((folder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder)
                    }
                }
                HStack {
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
                    Button("Change…", action: pickFolder)
                }
            } footer: {
                Text("Screenshots and recordings are saved here.").foregroundStyle(.secondary)
            }

            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

        }
        .onAppear { if folder.isEmpty { folder = Settings.saveFolder.path } }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where Skrinsut saves screenshots and recordings"
        panel.directoryURL = URL(fileURLWithPath: folder)
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

// MARK: - Image

private struct ImagePane: View {
    @AppStorage(SettingKey.afterGrabShow) private var afterShow = true
    @AppStorage(SettingKey.afterGrabCopy) private var afterCopy = false
    @AppStorage(SettingKey.afterGrabSave) private var afterSave = false
    @AppStorage(SettingKey.saveFormat) private var saveFormat = SaveFormat.png.rawValue
    @AppStorage(SettingKey.downscaleOnSave) private var downscale = false
    @AppStorage(SettingKey.windowBackground) private var windowBackground = WindowBackground.transparent.rawValue
    @AppStorage(SettingKey.windowSolidColor) private var solidColor = "#C4C6C8"
    @AppStorage(SettingKey.snapping) private var snapping = true

    var body: some View {
        Form {
            Section("After Screenshot") {
                Toggle("Show in editor", isOn: $afterShow)
                Toggle("Copy to clipboard", isOn: $afterCopy)
                Toggle("Save to save location", isOn: $afterSave)
            }
            Section("Saving") {
                Picker("Format", selection: $saveFormat) {
                    ForEach(SaveFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Toggle("Downscale Retina screenshots to 1×", isOn: $downscale)
            }
            Section("Window Screenshots") {
                Picker("Background", selection: $windowBackground) {
                    ForEach(WindowBackground.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if windowBackground == WindowBackground.solid.rawValue {
                    TextField("Solid color", text: $solidColor, prompt: Text("#C4C6C8"))
                }
            }
            Section("Editor") {
                Toggle("Snap to objects and edges", isOn: $snapping)
            }
        }
    }
}

// MARK: - Toolbar

private struct ToolbarPane: View {
    @State private var order = Self.loadOrder()
    @State private var hidden = ToolbarConfig.hidden

    private static func loadOrder() -> [ToolbarGroup: [String]] {
        Dictionary(uniqueKeysWithValues: ToolbarGroup.allCases.map { ($0, ToolbarConfig.order($0)) })
    }

    var body: some View {
        List {
            ForEach(ToolbarGroup.allCases) { group in
                Section(group.title) {
                    ForEach(order[group] ?? [], id: \.self) { id in
                        HStack(spacing: 10) {
                            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            Toggle(isOn: visibleBinding(id)) {
                                Label(ToolbarGroup.title(id), systemImage: ToolbarGroup.symbol(id))
                            }
                        }
                    }
                    .onMove { from, to in
                        order[group]?.move(fromOffsets: from, toOffset: to)
                        ToolbarConfig.setOrder(order[group] ?? [], for: group)
                    }
                }
            }
            Section {
                HStack {
                    Text("Drag to reorder. Hidden tools still work with their keyboard shortcuts.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset to Default") {
                        ToolbarConfig.reset()
                        order = Self.loadOrder()
                        hidden = ToolbarConfig.hidden
                    }
                }
            }
        }
    }

    private func visibleBinding(_ id: String) -> Binding<Bool> {
        Binding {
            !hidden.contains(id)
        } set: { on in
            if on { hidden.remove(id) } else { hidden.insert(id) }
            ToolbarConfig.setHidden(hidden)
        }
    }
}

// MARK: - Video

private struct VideoPane: View {
    @AppStorage(SettingKey.recordFormat) private var format = RecordFormat.mp4.rawValue
    @AppStorage(VideoKey.maxResolution) private var maxResolution = MaxResolution.original.rawValue
    @AppStorage(VideoKey.fps) private var fps = 30
    @AppStorage(VideoKey.showCursor) private var showCursor = true
    @AppStorage(VideoKey.codec) private var codec = VideoCodec.h264.rawValue
    @AppStorage(VideoKey.encoder) private var encoder = VideoEncoder.software.rawValue
    @AppStorage(VideoKey.rateControl) private var rateControl = RateControl.quality.rawValue
    @AppStorage(VideoKey.quality) private var quality = 0.75
    @AppStorage(VideoKey.bitrateMbps) private var bitrate = 8.0
    @AppStorage(VideoKey.speed) private var speed = EncodeSpeed.fast.rawValue
    @AppStorage(VideoKey.gifFPS) private var gifFPS = 15
    @AppStorage(VideoKey.gifColors) private var gifColors = 256
    @AppStorage(VideoKey.gifDither) private var gifDither = GIFDither.bayer.rawValue

    private var isGIF: Bool { format == RecordFormat.gif.rawValue }
    private var isSoftware: Bool { encoder == VideoEncoder.software.rawValue }

    var body: some View {
        Form {
            Section {
                Picker("Format", selection: $format) {
                    ForEach(RecordFormat.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                Picker("Max resolution", selection: $maxResolution) {
                    ForEach(MaxResolution.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text("Larger recordings are scaled down to fit; smaller ones keep their size.").foregroundStyle(.secondary)
            }

            Section("Capture") {
                Picker("Frame rate", selection: $fps) {
                    ForEach(VideoSettings.frameRates, id: \.self) { Text("\($0) fps").tag($0) }
                }
                Toggle("Show mouse cursor", isOn: $showCursor)
            }

            if isGIF { gifSection } else { mp4Section }

            FFmpegSection()
        }
    }

    @ViewBuilder private var gifSection: some View {
        Section("GIF") {
            Picker("Frame rate", selection: $gifFPS) {
                ForEach(VideoSettings.gifFrameRates, id: \.self) { Text("\($0) fps").tag($0) }
            }
            Picker("Colors", selection: $gifColors) {
                ForEach(VideoSettings.gifColorCounts, id: \.self) { Text("\($0)").tag($0) }
            }
            Picker("Dithering", selection: $gifDither) {
                ForEach(GIFDither.allCases) { Text($0.title).tag($0.rawValue) }
            }
        }
    }

    @ViewBuilder private var mp4Section: some View {
        Section {
            Picker("Codec", selection: $codec) {
                ForEach(VideoCodec.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Encoder", selection: $encoder) {
                ForEach(VideoEncoder.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Picker("Rate control", selection: $rateControl) {
                ForEach(RateControl.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            if rateControl == RateControl.quality.rawValue {
                LabeledContent("Quality") {
                    HStack {
                        Slider(value: $quality, in: 0...1) {
                            EmptyView()
                        } minimumValueLabel: {
                            Text("Smaller").font(.caption)
                        } maximumValueLabel: {
                            Text("Sharper").font(.caption)
                        }
                        Text(qualityText)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 115, alignment: .trailing)
                    }
                }
            } else {
                LabeledContent("Bitrate") {
                    HStack {
                        Slider(value: $bitrate, in: 1...50, step: 0.5)
                        Text(String(format: "%.1f Mbps", bitrate))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }
            if isSoftware {
                Picker("Speed", selection: $speed) {
                    ForEach(EncodeSpeed.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("MP4 Encoding")
        } footer: {
            Text(mp4Footer).foregroundStyle(.secondary)
        }
    }

    private var qualityText: String {
        var s = VideoSettings()
        s.quality = quality
        s.codec = VideoCodec(rawValue: codec) ?? .h264
        return isSoftware ? "\(s.qualityLabel) · CRF \(s.crf)" : s.qualityLabel
    }

    private var mp4Footer: String {
        if rateControl == RateControl.bitrate.rawValue {
            return String(format: "About %.0f MB per minute of video.", bitrate * 60 / 8)
        }
        return isSoftware
            ? "Constant quality keeps detail steady and lets file size follow the content, so static screens stay small."
            : "Hardware encoding is fastest; quality maps to a bitrate based on resolution and frame rate."
    }
}

private struct FFmpegSection: View {
    @AppStorage(SettingKey.ffmpegPath) private var ffmpegOverride = ""
    @State private var ffmpegPath: String?
    @State private var installing = false
    @State private var installStatus = ""

    var body: some View {
        Section {
            LabeledContent("ffmpeg") {
                if let ffmpegPath {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text((ffmpegPath as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    }
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Not found")
                    }
                }
            }
            HStack {
                if !installStatus.isEmpty {
                    Text(installStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Locate…", action: locate)
                if ffmpegPath == nil {
                    Button {
                        install()
                    } label: {
                        if installing { ProgressView().controlSize(.small) } else { Text("Install ffmpeg") }
                    }
                    .disabled(installing)
                }
            }
        } header: {
            Text("Encoder")
        } footer: {
            Text("Recordings are encoded with ffmpeg. Without it, they're saved as .mov.").foregroundStyle(.secondary)
        }
        .onAppear(perform: refresh)
        // Re-check after finishing an install in Terminal.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        ffmpegPath = FFmpeg.locate()?.path
        installing = DependencyInstaller.isInstalling
    }

    private func install() {
        installing = true
        installStatus = DependencyInstaller.brewPath == nil ? "Opening the installer in Terminal…" : "Installing ffmpeg with Homebrew…"
        DependencyInstaller.installFFmpeg(onOutput: { line in
            installStatus = line
        }, completion: { result in
            installing = false
            switch result {
            case .success(.installed(let url)):
                ffmpegPath = url.path
                installStatus = ""
            case .success(.openedTerminal):
                installStatus = "Finish in Terminal (Homebrew asks for your password)."
            case .failure(let error):
                installStatus = error.localizedDescription
            }
        })
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = "Choose the ffmpeg executable"
        panel.directoryURL = URL(fileURLWithPath: "/opt/homebrew/bin")
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            ffmpegOverride = url.path
            refresh()
        }
    }
}

// MARK: - Deep Links

private struct DeepLinksPane: View {
    @AppStorage(SettingKey.allowDeeplinks) private var allowDeeplinks = false

    var body: some View {
        Form {
            Section {
                Toggle("Allow deep links (skrinsut://)", isOn: $allowDeeplinks)
                if allowDeeplinks {
                    ForEach(AppDelegate.deepLinkRoutes, id: \.route) { link in
                        LabeledContent(link.title) {
                            HStack(spacing: 6) {
                                Text("skrinsut://\(link.route)")
                                    .font(.callout.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                Button {
                                    Exporter.copyText("skrinsut://\(link.route)")
                                    Toast.show("Copied link", detail: "skrinsut://\(link.route)")
                                } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless)
                                .help("Copy link")
                            }
                        }
                    }
                }
            } footer: {
                Text("Lets other apps, scripts and launchers (Shortcuts, Raycast, Alfred, Terminal `open skrinsut://grab/area`) trigger captures. Off by default, so websites and apps can't take screenshots without you turning this on.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Shortcuts

private struct ShortcutsPane: View {
    private let editorKeys: [(String, String)] = Tool.allCases.compactMap { t in t.shortcut.map { (t.title, String($0).uppercased()) } } + [
        ("New line while typing text", "⇧↩"),
        ("Copy color under cursor", "Tab"),
        ("Copy image and close", "⌘C"),
        ("Save image", "⌘S"),
        ("Pin to screen", "⌘P"),
        ("Undo / Redo", "⌘Z / ⇧⌘Z"),
        ("Delete selected object", "⌫"),
        ("Constrain angle / square", "Hold ⇧"),
        ("Skip snapping", "Hold ⌘"),
        ("Apply crop", "↩"),
        ("Close editor / cancel", "Esc"),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(HotKeyAction.allCases) { action in
                    LabeledContent(action.title) { HotKeyRecorder(action: action) }
                }
            } header: {
                Text("Global")
            } footer: {
                Text("Click a shortcut, then press the new keys (Esc cancels). To use ⇧⌘3 / ⇧⌘4, first turn off the macOS screenshot shortcuts in System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Screenshots.")
                    .foregroundStyle(.secondary)
            }
            Section("Editor") {
                ForEach(editorKeys, id: \.0) { name, key in
                    LabeledContent(name) {
                        Text(key)
                            .font(.callout.monospaced())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
                    }
                }
            }
        }
    }
}

private struct HotKeyRecorder: View {
    let action: HotKeyAction
    @State private var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(recording ? "Press keys…" : (combo?.display ?? "Record Shortcut")) {
                recording ? stop() : start()
            }
            .frame(minWidth: 120)
            if combo != nil {
                Button {
                    HotKeyManager.shared.setCombo(nil, for: action)
                    combo = nil
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.borderless)
                .help("Remove shortcut")
            }
        }
        .onAppear { combo = HotKeyManager.shared.combo(for: action) }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        HotKeyManager.shared.suspend()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { stop(); return nil } // Esc cancels
            if let c = KeyCombo(event: event) {
                combo = c
                HotKeyManager.shared.setCombo(c, for: action)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if recording { HotKeyManager.shared.reload() }
        recording = false
    }
}

// MARK: - About

private struct AboutPane: View {
    @State private var ffmpegVersion = "Checking…"

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Skrinsut").font(.title2.bold())
                        Text("skrin.sut").font(.callout.monospaced()).foregroundStyle(.tertiary)
                        Text("Version \(version)").foregroundStyle(.secondary)
                        Text("Screenshots, annotation, OCR and screen recording for macOS.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("System") {
                LabeledContent("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("ffmpeg", value: ffmpegVersion)
            }
            Section("The Name") {
                Text("Skrinsut comes from **skrin.sut**: “screen.shot”, the way it sounds in Indonesian.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("Credits") {
                Text("Video encoding uses ffmpeg, installed separately.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            let path = FFmpeg.locate()?.path
            ffmpegVersion = await Task.detached {
                guard let path else { return "Not installed" }
                let line = FFmpeg.runSync(path, ["-version"]).split(separator: "\n").first.map(String.init) ?? ""
                // "ffmpeg version 9.0.2 Copyright …" → "9.0.2"
                let parts = line.split(separator: " ")
                return parts.count > 2 ? String(parts[2]) : "Installed"
            }.value
        }
    }
}

// MARK: - Help

private struct HelpPane: View {
    @State private var hasScreenAccess = CGPreflightScreenCaptureAccess()

    private func keys(_ action: HotKeyAction) -> String {
        HotKeyManager.shared.combo(for: action)?.display ?? "Not set"
    }

    var body: some View {
        Form {
            Section("Getting Started") {
                helpRow("Area screenshot", keys(.area), "Drag to select; click a window to capture it; Space switches to window mode.")
                helpRow("Fullscreen screenshot", keys(.fullscreen), "Captures the display under the pointer.")
                helpRow("Record screen", keys(.record), "Press again (or click the menu-bar timer) to stop. Saved as MP4/GIF.")
                helpRow("Recognize text / QR", keys(.ocr), "Select an area; the text is copied to the clipboard.")
                helpRow("Editor", "Tab · ⌘C", "Press Tab to copy the color under the cursor; ⌘C copies the image and closes the editor.")
            }

            Section {
                LabeledContent("Screen Recording") {
                    HStack(spacing: 4) {
                        Image(systemName: hasScreenAccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(hasScreenAccess ? .green : .orange)
                        Text(hasScreenAccess ? "Allowed" : "Not allowed")
                    }
                }
                HStack {
                    Spacer()
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
            } header: {
                Text("Permissions")
            } footer: {
                Text("Skrinsut needs Screen Recording to capture the screen. After allowing it, quit and reopen Skrinsut.")
                    .foregroundStyle(.secondary)
            }

            Section("Troubleshooting") {
                faq("Captures show only the wallpaper or are blank",
                    "Screen Recording isn't allowed. Turn it on for Skrinsut in Privacy & Security, then reopen Skrinsut. Rebuilt copies of the app may need to be allowed again.")
                faq("A shortcut does nothing",
                    "Another app or macOS may already use it. Pick a different one in Shortcuts. To use ⇧⌘3/⇧⌘4, turn off the macOS screenshot shortcuts first.") {
                    Button("Open Shortcuts") { SettingsNavigation.shared.pane = .shortcuts }
                }
                faq("Recordings are saved as .mov",
                    "ffmpeg isn't installed. Install it with one click in Video ▸ Encoder.") {
                    Button("Open Video Settings") { SettingsNavigation.shared.pane = .video }
                }
                faq("Where are my screenshots and recordings?",
                    "In the save location set in General.") {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Settings.saveFolder]) }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            hasScreenAccess = CGPreflightScreenCaptureAccess()
        }
    }

    private func helpRow(_ title: String, _ key: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(key)
                    .font(.callout.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15)))
            }
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func faq(_ question: String, _ answer: String) -> some View {
        faq(question, answer) { EmptyView() }
    }

    private func faq<Action: View>(_ question: String, _ answer: String, @ViewBuilder action: () -> Action) -> some View {
        let actionView = action()
        return DisclosureGroup(question) {
            VStack(alignment: .leading, spacing: 6) {
                Text(answer).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                actionView
            }
            .padding(.top, 4)
        }
    }
}
