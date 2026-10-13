import AppKit

/// Drives a screen recording: pick a target, record with a visible border and menu-bar timer,
/// then encode with ffmpeg, save to the Save Location, copy the file, and reveal it. No editor.
final class RecordingController {
    static let shared = RecordingController()

    enum State { case idle, picking, starting, recording, encoding }
    private(set) var state: State = .idle { didSet { onStateChange?() } }
    /// Fired on state changes and every second while recording (the status item shows the timer).
    var onStateChange: (() -> Void)?

    private var recorder: ScreenRecorder?
    private var border: NSWindow?
    private var startDate: Date?
    private var ticker: Timer?
    private var encodeProcess: Process?

    var isRecording: Bool { state == .recording }
    var elapsedText: String {
        let s = Int(Date().timeIntervalSince(startDate ?? Date()))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: Start

    /// Hotkey: start an area recording, or stop the current one.
    func toggle() {
        switch state {
        case .idle: startArea()
        case .recording: stop()
        default: NSSound.beep()
        }
    }

    func startArea() { pick(.area) }
    func startWindow() { pick(.window) }

    func startFullscreen() {
        guard state == .idle else { return }
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        begin(.display(screen.displayID), border: nil)
    }

    private func pick(_ mode: RegionSelector.Mode) {
        guard state == .idle else { return }
        state = .picking
        AppDelegate.shared?.pickTarget(mode: mode) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .cancelled:
                self.state = .idle
            case let .area(_, globalRect, displayID):
                guard let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) else { self.state = .idle; return }
                // AppKit global (bottom-left) → display-local points (top-left), as ScreenCaptureKit expects.
                let f = screen.frame
                let local = CGRect(x: globalRect.minX - f.minX, y: f.maxY - globalRect.maxY, width: globalRect.width, height: globalRect.height)
                self.begin(.area(local, displayID: displayID), border: globalRect)
            case let .window(id):
                let frame = Capturer.visibleWindows().first { $0.windowID == id }?.frame
                self.begin(.window(id), border: frame)
            }
        }
    }

    private func begin(_ target: RecordingTarget, border borderRect: CGRect?) {
        state = .starting
        let recorder = ScreenRecorder()
        recorder.onError = { [weak self] error in self?.fail(error) }
        Task { @MainActor in
            do {
                try await recorder.start(target)
                self.recorder = recorder
                self.startDate = Date()
                self.state = .recording
                if let borderRect { self.showBorder(around: borderRect) }
                self.ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    MainActor.assumeIsolated { RecordingController.shared.onStateChange?() }
                }
                Toast.show("Recording", detail: "Press ⇧⌘6 or click the menu-bar timer to stop")
            } catch {
                self.state = .idle
                AppDelegate.shared?.report(error)
            }
        }
    }

    // MARK: Stop + encode

    func stop() {
        guard state == .recording, let recorder else { return }
        state = .encoding
        cleanupRecordingUI()
        Task { @MainActor in
            do {
                let (mov, duration) = try await recorder.stop()
                let size = recorder.pixelSize
                self.recorder = nil
                self.encode(mov, duration: duration, size: size)
            } catch {
                self.recorder = nil
                self.state = .idle
                AppDelegate.shared?.report(error)
            }
        }
    }

    private func fail(_ error: Error) {
        guard state == .recording || state == .starting else { return }
        cleanupRecordingUI()
        recorder = nil
        state = .idle
        AppDelegate.shared?.report(error)
    }

    private func cleanupRecordingUI() {
        ticker?.invalidate()
        ticker = nil
        border?.orderOut(nil)
        border = nil
    }

    private func encode(_ mov: URL, duration: Double, size: CGSize) {
        let format = Settings.recordFormat
        guard FFmpeg.locate() != nil else {
            // Keep the raw recording so nothing is lost, and offer to install ffmpeg.
            let saved = move(mov, toSaveFolderAs: "mov")
            state = .idle
            if let saved { deliver(saved, note: "Saved as .mov (ffmpeg not found)") }
            Self.offerFFmpegInstall()
            return
        }
        let output = Self.outputURL(ext: format.fileExtension)
        Toast.progress("Encoding \(format.title)… 0%")
        encodeProcess = FFmpeg.encode(input: mov, output: output, format: format, duration: duration, size: size, progress: { p in
            Toast.progress("Encoding \(format.title)… \(Int(p * 100))%")
        }, completion: { [weak self] result in
            guard let self else { return }
            self.encodeProcess = nil
            self.state = .idle
            switch result {
            case .success(let url):
                try? FileManager.default.removeItem(at: mov)
                self.deliver(url, note: nil)
            case .failure(let error):
                Toast.dismiss()
                if let saved = self.move(mov, toSaveFolderAs: "mov") { NSWorkspace.shared.activateFileViewerSelecting([saved]) }
                AppDelegate.shared?.report(error)
            }
        })
    }

    /// Final hand-off: copy the file to the clipboard (paste into Slack/Finder), reveal it, confirm.
    private func deliver(_ url: URL, note: String?) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        NSWorkspace.shared.activateFileViewerSelecting([url])
        Toast.show(note ?? "Recording saved", detail: "\(url.lastPathComponent) · copied to clipboard")
    }

    private func move(_ mov: URL, toSaveFolderAs ext: String) -> URL? {
        let dest = Self.outputURL(ext: ext)
        do {
            try FileManager.default.moveItem(at: mov, to: dest)
            return dest
        } catch {
            return nil
        }
    }

    static func outputURL(ext: String) -> URL {
        let folder = Settings.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let base = "Skrinsut Recording \(f.string(from: Date()))"
        var url = folder.appendingPathComponent("\(base).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return url
    }

    // MARK: ffmpeg missing

    static func offerFFmpegInstall() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "ffmpeg is needed for MP4/GIF"
        alert.informativeText = "Your recording was saved as a .mov. Install ffmpeg (one click, via Homebrew) to get MP4 and GIF recordings."
        alert.addButton(withTitle: "Install ffmpeg")
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        switch alert.runModal() {
        case .alertFirstButtonReturn: installFFmpeg()
        case .alertSecondButtonReturn: PreferencesWindowController.shared.present(pane: .video)
        default: break
        }
    }

    static func installFFmpeg() {
        DependencyInstaller.installFFmpeg(onOutput: { line in
            Toast.progress(line)
        }, completion: { result in
            switch result {
            case .success(.installed(let url)):
                Toast.show("ffmpeg installed", detail: url.path)
            case .success(.openedTerminal):
                Toast.show("Finish the install in Terminal", detail: "Homebrew needs your password; ffmpeg installs right after.")
            case .failure(let error):
                Toast.dismiss()
                AppDelegate.shared?.report(error)
            }
        })
    }

    // MARK: Border

    private func showBorder(around rect: CGRect) {
        let inset: CGFloat = -4
        let w = NSWindow(contentRect: rect.insetBy(dx: inset, dy: inset), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .statusBar
        w.sharingType = .none
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        w.contentView = RecordingBorderView()
        w.orderFrontRegardless()
        border = w
    }
}

private final class RecordingBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        path.lineWidth = 2
        path.setLineDash([8, 5], count: 2, phase: 0)
        NSColor.systemRed.setStroke()
        path.stroke()
    }
}
