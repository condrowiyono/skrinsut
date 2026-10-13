import AppKit

/// Post-capture thumbnail in the bottom-right corner with Copy / Save / Edit / Pin / OCR / Close
/// (buttons observed in Preview.storyboard). Click the image to edit; drag it out to drop the file elsewhere.
final class PreviewWindowController: NSWindowController {
    private static var current: PreviewWindowController?

    private let shot: Screenshot
    private var outsideClickMonitor: Any?

    static func show(_ shot: Screenshot) {
        current?.dismiss()
        let c = PreviewWindowController(shot: shot)
        current = c
        c.present()
    }

    private init(shot: Screenshot) {
        self.shot = shot
        let maxSide: CGFloat = 260
        let s = shot.pointSize
        let f = min(maxSide / max(s.width, 1), maxSide / max(s.height, 1), 1)
        let imgSize = CGSize(width: max(s.width * f, 160), height: max(s.height * f, 60))
        let size = CGSize(width: imgSize.width + 16, height: imgSize.height + 52)

        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        super.init(window: panel)

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let imageView = ThumbnailImageView(shot: shot)
        imageView.frame = CGRect(x: 8, y: 44, width: imgSize.width, height: imgSize.height)
        imageView.onClick = { [weak self] in self?.edit() }
        effect.addSubview(imageView)

        func button(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
            b.bezelStyle = .texturedRounded
            b.toolTip = tip
            return b
        }
        let buttons = NSStackView(views: [
            button("doc.on.doc", "Copy", #selector(copyImage)),
            button("square.and.arrow.down", "Save", #selector(saveImage)),
            button("pencil.tip.crop.circle", "Edit", #selector(editImage)),
            button("pin", "Pin", #selector(pinImage)),
            button("text.viewfinder", "Recognize Text", #selector(ocrImage)),
            button("xmark", "Close", #selector(closeThumb)),
        ])
        buttons.spacing = 4
        buttons.frame = CGRect(x: 8, y: 8, width: size.width - 16, height: 28)
        buttons.distribution = .fillEqually
        effect.addSubview(buttons)
        panel.contentView = effect
    }

    required init?(coder: NSCoder) { fatalError() }

    private func present() {
        guard let window, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        window.setFrameOrigin(CGPoint(x: vf.maxX - window.frame.width - 16, y: vf.minY + 16))
        window.alphaValue = 0
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.18; window.animator().alphaValue = 1 }
        if Settings.thumbnailClosing == .automatic {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.dismiss()
            }
        }
    }

    func dismiss() {
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m) }
        outsideClickMonitor = nil
        window?.orderOut(nil)
        if Self.current === self { Self.current = nil }
    }

    private func edit() {
        AppDelegate.shared?.openEditor(shot)
        dismiss()
    }

    @objc private func copyImage() { Exporter.copy(shot); dismiss() }
    @objc private func saveImage() { Exporter.save(shot); dismiss() }
    @objc private func editImage() { edit() }
    @objc private func pinImage() {
        let center = window.map { CGPoint(x: $0.frame.midX, y: $0.frame.midY) }
        dismiss()
        PinWindowController.pin(shot, centeredAt: center.map { CGPoint(x: $0.x - 200, y: $0.y + 200) })
    }
    @objc private func ocrImage() { AppDelegate.shared?.runOCR(on: shot.image); dismiss() }
    @objc private func closeThumb() { dismiss() }
}

private final class ThumbnailImageView: NSImageView, NSDraggingSource {
    private let shot: Screenshot
    var onClick: (() -> Void)?
    private var downEvent: NSEvent?

    init(shot: Screenshot) {
        self.shot = shot
        super.init(frame: .zero)
        image = NSImage(cgImage: shot.image, size: shot.pointSize)
        imageScaling = .scaleProportionallyUpOrDown
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        toolTip = "Click to edit · Drag to drop the image into another app"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { downEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let down = downEvent else { return }
        let a = down.locationInWindow, b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 4, let url = Exporter.temporaryFile(shot) else { return }
        downEvent = nil
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if downEvent != nil { onClick?() }
        downEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
