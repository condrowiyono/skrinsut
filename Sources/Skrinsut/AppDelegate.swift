import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var editors: [EditorWindowController] = []
    private var lastArea: (rect: CGRect, displayID: CGDirectDisplayID)?
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Settings.registerDefaults()
        VideoSettings.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.build()
        setupStatusItem()
        HotKeyManager.shared.onAction = { [weak self] in self?.perform($0) }
        HotKeyManager.shared.install()
        RecordingController.shared.onStateChange = { [weak self] in self?.updateStatusItem() }
        if !CGPreflightScreenCaptureAccess() { CGRequestScreenCaptureAccess() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { PreferencesWindowController.shared.present() }
        return true
    }

    // MARK: Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Skrinsut")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, hotkey: HotKeyAction? = nil) {
            var t = title
            if let hotkey, let combo = HotKeyManager.shared.combo(for: hotkey) { t += "\t\(combo.display)" }
            let i = menu.addItem(withTitle: t, action: action, keyEquivalent: "")
            i.target = self
        }
        add("Fullscreen Screenshot", #selector(grabFullscreen), hotkey: .fullscreen)
        add("Area Screenshot", #selector(grabArea), hotkey: .area)
        add("Window Screenshot", #selector(grabWindow), hotkey: .window)
        add("Repeat Area Screenshot", #selector(grabRepeat), hotkey: .repeatArea)
        add("Delayed Screenshot (3 s)", #selector(grabDelayed))
        menu.addItem(.separator())
        add("Recognize Text / QR", #selector(grabOCR), hotkey: .ocr)
        menu.addItem(.separator())
        add("Record Area…", #selector(recordArea), hotkey: .record)
        add("Record Window…", #selector(recordWindow))
        add("Record Fullscreen", #selector(recordFullscreen))
        menu.addItem(.separator())
        add("Open File…", #selector(openFile))
        add("Open From Clipboard", #selector(openFromClipboard))
        menu.addItem(.separator())
        add("Settings…", #selector(showPreferences))
        add("Quit Skrinsut", #selector(quit))
    }

    // MARK: Actions

    func perform(_ action: HotKeyAction) {
        switch action {
        case .fullscreen: grabFullscreen()
        case .area: grabArea()
        case .window: grabWindow()
        case .ocr: grabOCR()
        case .repeatArea: grabRepeat()
        case .record: RecordingController.shared.toggle()
        }
    }

    // MARK: Recording

    @objc func recordArea() { RecordingController.shared.startArea() }
    @objc func recordWindow() { RecordingController.shared.startWindow() }
    @objc func recordFullscreen() { RecordingController.shared.startFullscreen() }
    @objc func stopRecording() { RecordingController.shared.stop() }

    /// While recording, the menu-bar item becomes a "● 0:12" stop button; otherwise the normal menu.
    private func updateStatusItem() {
        guard let item = statusItem, let button = item.button else { return }
        let rec = RecordingController.shared
        switch rec.state {
        case .recording:
            item.length = NSStatusItem.variableLength
            item.menu = nil
            button.image = NSImage(systemSymbolName: "stop.circle.fill", accessibilityDescription: "Stop recording")
            button.imagePosition = .imageLeading
            button.contentTintColor = .systemRed
            button.title = " \(rec.elapsedText)"
            button.target = self
            button.action = #selector(stopRecording)
            button.toolTip = "Stop recording"
        case .encoding:
            button.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Encoding")
            button.title = ""
            button.contentTintColor = nil
            button.action = nil
        default:
            item.length = NSStatusItem.squareLength
            button.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Skrinsut")
            button.title = ""
            button.contentTintColor = nil
            button.action = nil
            button.toolTip = nil
            if item.menu == nil {
                let menu = NSMenu()
                menu.delegate = self
                item.menu = menu
            }
        }
    }

    /// Area/window picker for recording: returns the raw selection instead of a screenshot.
    func pickTarget(mode: RegionSelector.Mode, then: @escaping (RegionSelector.Outcome) -> Void) {
        Task { @MainActor in
            do {
                let snaps = try await Capturer.snapshotAllDisplays()
                RegionSelector.run(snapshots: snaps, mode: mode, completion: then)
            } catch {
                self.report(error)
                then(.cancelled)
            }
        }
    }

    @objc func grabFullscreen() {
        capture { snaps in
            // Capture the display under the mouse pointer.
            let mouse = NSEvent.mouseLocation
            guard let snap = snaps.first(where: { $0.screen.frame.contains(mouse) }) ?? snaps.first else { return }
            self.handleCapture(Screenshot(image: snap.image, scale: snap.scale))
        }
    }

    @objc func grabDelayed() {
        Toast.show("Capturing in 3 seconds…")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.grabFullscreen() }
    }

    @objc func grabArea() { select(mode: .area) { self.handleCapture($0) } }

    @objc func grabWindow() { select(mode: .window) { self.handleCapture($0) } }

    /// Area selection used by the editor's "Add Capture".
    func pickArea(then: @escaping (Screenshot) -> Void) { select(mode: .area, then: then) }

    @objc func grabOCR() { select(mode: .area) { self.runOCR(on: $0.image) } }

    @objc func grabRepeat() {
        guard let last = lastArea else { grabArea(); return }
        capture { snaps in
            guard let snap = snaps.first(where: { $0.screen.displayID == last.displayID }) else { return }
            let f = snap.screen.frame
            let local = CGRect(x: last.rect.minX - f.minX, y: f.maxY - last.rect.maxY, width: last.rect.width, height: last.rect.height)
            if let shot = ImageUtil.crop(Screenshot(image: snap.image, scale: snap.scale), toPointRect: local) {
                self.handleCapture(shot)
            }
        }
    }

    private func capture(_ then: @escaping ([DisplaySnapshot]) -> Void) {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { self.busy = false }
            do {
                then(try await Capturer.snapshotAllDisplays())
            } catch {
                self.report(error)
            }
        }
    }

    private func select(mode: RegionSelector.Mode, then: @escaping (Screenshot) -> Void) {
        capture { snaps in
            RegionSelector.run(snapshots: snaps, mode: mode) { outcome in
                switch outcome {
                case .cancelled:
                    break
                case let .area(shot, rect, displayID):
                    self.lastArea = (rect, displayID)
                    then(shot)
                case let .window(id):
                    Task { @MainActor in
                        do { then(try await Capturer.captureWindow(id: id)) } catch { self.report(error) }
                    }
                }
            }
        }
    }

    func report(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(error: error)
        if error is CaptureError {
            alert.addButton(withTitle: "Open System Settings")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
        } else {
            alert.runModal()
        }
    }

    /// Applies the "After screenshot" preferences.
    func handleCapture(_ shot: Screenshot) {
        if Settings.afterCaptureCopy { Exporter.copy(shot) }
        if Settings.afterCaptureSave { Exporter.save(shot) }
        if Settings.afterCaptureShow {
            openEditor(shot)
        } else if !Settings.afterCaptureCopy && !Settings.afterCaptureSave {
            Exporter.copy(shot) // never drop a capture silently
        }
    }

    func runOCR(on image: CGImage) {
        OCR.recognize(image) { result in
            guard let result else { Toast.show("No text found"); return }
            Exporter.copyText(result.text)
            let preview = result.text.count > 140 ? String(result.text.prefix(140)) + "…" : result.text
            Toast.show(result.isBarcode ? "Copied QR/barcode content" : "Copied recognized text", detail: preview)
        }
    }

    func openEditor(_ shot: Screenshot) {
        let editor = EditorWindowController(shot: shot)
        editor.onClose = { [weak self] e in
            self?.editors.removeAll { $0 === e }
            if self?.editors.isEmpty == true { NSApp.setActivationPolicy(.accessory) }
        }
        editors.append(editor)
        NSApp.setActivationPolicy(.regular)
        editor.present()
    }

    @objc func openFile() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .gif, .tiff, .heic, .image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openImage(at: url)
    }

    func openImage(at url: URL) {
        guard let rep = NSImageRep(contentsOf: url) as? NSBitmapImageRep ?? NSImage(contentsOf: url).flatMap({
            $0.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
        }), let cg = rep.cgImage else {
            Toast.show("Could not open image")
            return
        }
        let scale = rep.size.width > 0 ? CGFloat(rep.pixelsWide) / rep.size.width : 1
        openEditor(Screenshot(image: cg, scale: max(1, scale)))
    }

    @objc func openFromClipboard() {
        guard let image = NSImage(pasteboard: .general),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            Toast.show("No image on the clipboard")
            return
        }
        let scale = image.size.width > 0 ? CGFloat(cg.width) / image.size.width : 1
        openEditor(Screenshot(image: cg, scale: max(1, scale)))
    }

    @objc func showPreferences() { PreferencesWindowController.shared.present() }
    @objc func quit() { NSApp.terminate(nil) }

    // MARK: Files and URL scheme

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.isFileURL { openImage(at: url) } else { handleDeepLink(url) }
        }
    }

    /// skrinsut://grab/fullscreen | grab/area | grab/window | grab/repeat | ocr | load/clipboard
    private func handleDeepLink(_ url: URL) {
        guard url.scheme == "skrinsut" else { return }
        guard Settings.allowDeeplinks else {
            Toast.show("Deep links are disabled", detail: "An app tried to open \(url.absoluteString). Enable deep links in Settings → Advanced.")
            return
        }
        let route = ([url.host].compactMap { $0 } + url.pathComponents.filter { $0 != "/" }).joined(separator: "/")
        switch route {
        case "grab/fullscreen": grabFullscreen()
        case "grab/area": grabArea()
        case "grab/window": grabWindow()
        case "grab/repeat": grabRepeat()
        case "ocr": grabOCR()
        case "load/clipboard": openFromClipboard()
        default: Toast.show("Unknown deep link", detail: url.absoluteString)
        }
    }
}
