import AppKit

/// Always-on-top floating screenshot ("Pin to Screen"). Drag to move, scroll to resize,
/// right-click for Edit / Copy / 50% / 100% / 200% / Semi-transparent / Close (menu observed in Pin.storyboard).
final class PinWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [PinWindowController] = []

    private let shot: Screenshot
    private var zoom: CGFloat = 1
    private var semiTransparent = false

    static func pin(_ shot: Screenshot, centeredAt center: CGPoint? = nil) {
        let c = PinWindowController(shot: shot)
        open.append(c)
        if let center, let w = c.window {
            w.setFrameOrigin(CGPoint(x: center.x - w.frame.width / 2, y: center.y - w.frame.height / 2))
        }
        c.window?.makeKeyAndOrderFront(nil)
    }

    private init(shot: Screenshot) {
        self.shot = shot
        let panel = PinPanel(contentRect: CGRect(origin: .zero, size: shot.pointSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)
        panel.delegate = self

        let view = PinImageView(frame: CGRect(origin: .zero, size: shot.pointSize))
        view.image = NSImage(cgImage: shot.image, size: shot.pointSize)
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.35).cgColor
        view.layer?.borderWidth = 1
        view.menu = buildMenu()
        view.onScroll = { [weak self] dy in self?.setZoom((self?.zoom ?? 1) * (dy > 0 ? 1.05 : 1 / 1.05)) }
        view.onDoubleClick = { [weak self] in self?.edit(nil) }
        panel.contentView = view

        // Fit oversize captures on screen initially.
        if let vf = NSScreen.main?.visibleFrame {
            let fit = min(1, vf.width * 0.8 / shot.pointSize.width, vf.height * 0.8 / shot.pointSize.height)
            setZoom(fit)
            panel.center()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.addItem(withTitle: "Edit", action: #selector(edit(_:)), keyEquivalent: "").target = self
        m.addItem(withTitle: "Copy", action: #selector(copyImage(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        for (title, z) in [("50%", 0.5), ("100%", 1.0), ("200%", 2.0)] {
            let item = m.addItem(withTitle: title, action: #selector(zoomItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = z
        }
        m.addItem(withTitle: "Semi-transparent", action: #selector(toggleTransparency(_:)), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Close", action: #selector(closePin(_:)), keyEquivalent: "").target = self
        return m
    }

    private func setZoom(_ z: CGFloat) {
        guard let window else { return }
        zoom = max(0.1, min(z, 8))
        let size = CGSize(width: shot.pointSize.width * zoom, height: shot.pointSize.height * zoom)
        let old = window.frame
        let frame = CGRect(x: old.midX - size.width / 2, y: old.midY - size.height / 2, width: size.width, height: size.height)
        window.setFrame(frame, display: true)
    }

    @objc private func zoomItem(_ sender: NSMenuItem) { setZoom(sender.representedObject as? CGFloat ?? 1) }

    @objc private func toggleTransparency(_ sender: NSMenuItem) {
        semiTransparent.toggle()
        sender.state = semiTransparent ? .on : .off
        window?.alphaValue = semiTransparent ? 0.5 : 1
        window?.ignoresMouseEvents = false
    }

    @objc func copyImage(_ sender: Any?) { Exporter.copy(shot) }

    @objc private func edit(_ sender: Any?) {
        AppDelegate.shared?.openEditor(shot)
        closePin(nil)
    }

    @objc func closePin(_ sender: Any?) { window?.close() }

    @objc override func cancelOperation(_ sender: Any?) { closePin(nil) }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c",
           let c = windowController as? PinWindowController {
            c.copyImage(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class PinImageView: NSImageView {
    var onScroll: ((CGFloat) -> Void)?
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        window?.performDrag(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY
        if dy != 0 { onScroll?(dy) }
    }
}
