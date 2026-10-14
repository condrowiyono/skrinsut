import AppKit

/// Full-screen "frozen screen" selector: one borderless window per display shows the captured
/// snapshot with a crosshair, a pixel loupe, and either a drag-to-select area or a hovered-window highlight.
/// Space toggles between area and window mode; Esc cancels.
final class RegionSelector {
    enum Mode { case area, window }
    enum Outcome {
        case area(Screenshot, globalRect: CGRect, displayID: CGDirectDisplayID)
        case window(CGWindowID)
        case cancelled
    }

    private static var active: RegionSelector?

    private var overlayWindows: [NSWindow] = []
    private var views: [SelectorView] = []
    private let completion: (Outcome) -> Void
    private var finished = false
    let windows: [WindowInfo]
    var mode: Mode { didSet { views.forEach { $0.needsDisplay = true } } }

    static func run(snapshots: [DisplaySnapshot], mode: Mode, completion: @escaping (Outcome) -> Void) {
        active?.finish(.cancelled)
        let selector = RegionSelector(snapshots: snapshots, mode: mode, completion: completion)
        active = selector
        selector.begin(snapshots)
    }

    private init(snapshots: [DisplaySnapshot], mode: Mode, completion: @escaping (Outcome) -> Void) {
        self.mode = mode
        self.completion = completion
        self.windows = Capturer.visibleWindows()
    }

    private func begin(_ snapshots: [DisplaySnapshot]) {
        for snap in snapshots {
            let win = KeyableWindow(contentRect: snap.screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            win.level = .screenSaver
            win.isOpaque = true
            win.hasShadow = false
            win.acceptsMouseMovedEvents = true
            win.isReleasedWhenClosed = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            win.setFrame(snap.screen.frame, display: false)

            let container = NSView(frame: CGRect(origin: .zero, size: snap.screen.frame.size))
            container.wantsLayer = true
            container.layer?.contents = snap.image
            container.layer?.contentsGravity = .resize

            let view = SelectorView(frame: container.bounds, snapshot: snap, selector: self)
            view.autoresizingMask = [.width, .height]
            container.addSubview(view)
            win.contentView = container
            overlayWindows.append(win)
            views.append(view)
        }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for (win, view) in zip(overlayWindows, views) {
            win.orderFrontRegardless()
            if win.frame.contains(mouse) {
                win.makeKey()
                win.makeFirstResponder(view)
            }
        }
        if overlayWindows.allSatisfy({ !$0.isKeyWindow }), let first = overlayWindows.first {
            first.makeKey()
            first.makeFirstResponder(views.first)
        }
        NSCursor.crosshair.push()
    }

    func refreshAll() { views.forEach { $0.needsDisplay = true } }

    func window(atGlobal p: CGPoint) -> WindowInfo? { windows.first { $0.frame.contains(p) } }

    func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        NSCursor.pop()
        overlayWindows.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        views.removeAll()
        if RegionSelector.active === self { RegionSelector.active = nil }
        completion(outcome)
    }
}

final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class SelectorView: NSView {
    private let snapshot: DisplaySnapshot
    private weak var selector: RegionSelector?
    private lazy var sampler = PixelSampler(snapshot.image)
    private var mouse: CGPoint?
    private var dragStart: CGPoint?
    private var selection: CGRect?

    init(frame: CGRect, snapshot: DisplaySnapshot, selector: RegionSelector) {
        self.snapshot = snapshot
        self.selector = selector
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Reads fall back once the selector is gone; the overlay is on its way out anyway.
    private var mode: RegionSelector.Mode { selector?.mode ?? .area }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect, .cursorUpdate],
                                       owner: self))
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }

    // MARK: coordinates

    private var screenFrame: CGRect { snapshot.screen.frame }

    private func globalRect(fromLocal r: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + r.minX, y: screenFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func localRect(fromGlobal r: CGRect) -> CGRect {
        CGRect(x: r.minX - screenFrame.minX, y: screenFrame.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func globalPoint(fromLocal p: CGPoint) -> CGPoint {
        CGPoint(x: screenFrame.minX + p.x, y: screenFrame.maxY - p.y)
    }

    // MARK: events

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        if window?.isKeyWindow == false {
            window?.makeKey()
            window?.makeFirstResponder(self)
        }
        selector?.refreshAll()
    }

    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        if mode == .area {
            dragStart = p
            selection = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        mouse = p
        guard mode == .area, let start = dragStart else { return }
        var rect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        if event.modifierFlags.contains(.shift) {
            let side = max(rect.width, rect.height)
            rect.size = CGSize(width: side, height: side)
            if p.x < start.x { rect.origin.x = start.x - side }
            if p.y < start.y { rect.origin.y = start.y - side }
        }
        selection = rect.intersection(bounds)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        switch mode {
        case .window:
            if let w = selector?.window(atGlobal: globalPoint(fromLocal: p)) {
                selector?.finish(.window(w.windowID))
            }
        case .area:
            defer { dragStart = nil }
            // A plain click (no drag) captures the window under the cursor.
            guard let sel = selection, sel.width >= 3, sel.height >= 3 else {
                if let w = selector?.window(atGlobal: globalPoint(fromLocal: p)) {
                    selector?.finish(.window(w.windowID))
                }
                return
            }
            let snapRect = pixelAligned(sel)
            let shot = Screenshot(image: snapshot.image, scale: snapshot.scale)
            if let cropped = ImageUtil.crop(shot, toPointRect: snapRect) {
                selector?.finish(.area(cropped, globalRect: globalRect(fromLocal: snapRect), displayID: snapshot.screen.displayID))
            } else {
                selector?.finish(.cancelled)
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53: selector?.finish(.cancelled)                                // Esc
        case 49: selector?.mode = mode == .area ? .window : .area   // Space
        default: super.keyDown(with: event)
        }
    }

    private func pixelAligned(_ r: CGRect) -> CGRect {
        let s = snapshot.scale
        let px = CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s).integral
        return CGRect(x: px.minX / s, y: px.minY / s, width: px.width / s, height: px.height / s)
    }

    // MARK: drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.35)
        var highlight: CGRect?
        switch mode {
        case .area: highlight = selection
        case .window:
            if let m = mouse, let w = selector?.window(atGlobal: globalPoint(fromLocal: m)) {
                highlight = localRect(fromGlobal: w.frame)
            }
        }

        let path = NSBezierPath(rect: bounds)
        if let h = highlight {
            path.append(NSBezierPath(rect: h))
            path.windingRule = .evenOdd
        }
        dim.setFill()
        path.fill()

        if let h = highlight {
            if mode == .window {
                NSColor.systemBlue.withAlphaComponent(0.18).setFill()
                NSBezierPath(rect: h).fill()
            }
            let border = NSBezierPath(rect: h.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            NSColor.white.setStroke()
            border.stroke()
            drawSizeLabel(for: h)
        }

        if let m = mouse, mode == .area {
            drawCrosshair(at: m)
            drawLoupe(at: m)
        }
        drawHint()
    }

    private func drawCrosshair(at m: CGPoint) {
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: m.y.rounded() + 0.5))
        path.line(to: CGPoint(x: bounds.maxX, y: m.y.rounded() + 0.5))
        path.move(to: CGPoint(x: m.x.rounded() + 0.5, y: 0))
        path.line(to: CGPoint(x: m.x.rounded() + 0.5, y: bounds.maxY))
        path.lineWidth = 1
        NSColor.black.withAlphaComponent(0.5).setStroke()
        path.stroke()
        path.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.white.withAlphaComponent(0.9).setStroke()
        path.stroke()
    }

    private func drawLoupe(at m: CGPoint) {
        let cells = 15
        let cell: CGFloat = 8
        let side = CGFloat(cells) * cell
        let s = snapshot.scale
        let px = Int((m.x * s).rounded(.down))
        let py = Int((m.y * s).rounded(.down))

        var origin = CGPoint(x: m.x + 24, y: m.y + 24)
        if origin.x + side > bounds.maxX { origin.x = m.x - 24 - side }
        if origin.y + side + 40 > bounds.maxY { origin.y = m.y - 24 - side - 40 }
        let loupe = CGRect(origin: origin, size: CGSize(width: side, height: side))

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: loupe, xRadius: 6, yRadius: 6).addClip()
        NSColor.black.setFill()
        loupe.fill()
        let src = CGRect(x: px - cells / 2, y: py - cells / 2, width: cells, height: cells)
        if let crop = snapshot.image.cropping(to: src.intersection(CGRect(x: 0, y: 0, width: snapshot.image.width, height: snapshot.image.height))) {
            // Offset if the source rect was clipped at a screen edge.
            let dx = CGFloat(max(0, -src.minX)) * cell
            let dy = CGFloat(max(0, -src.minY)) * cell
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: crop, size: .zero).draw(in: CGRect(x: loupe.minX + dx, y: loupe.minY + dy,
                                                                width: CGFloat(crop.width) * cell, height: CGFloat(crop.height) * cell),
                                                     from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }
        let center = CGRect(x: loupe.minX + CGFloat(cells / 2) * cell, y: loupe.minY + CGFloat(cells / 2) * cell, width: cell, height: cell)
        NSColor.white.setStroke()
        NSBezierPath(rect: center).stroke()
        NSGraphicsContext.restoreGraphicsState()

        let frame = NSBezierPath(roundedRect: loupe, xRadius: 6, yRadius: 6)
        frame.lineWidth = 2
        NSColor.white.withAlphaComponent(0.85).setStroke()
        frame.stroke()

        let hex = sampler?.color(x: px, y: py)?.hexString ?? "—"
        let text = "\(hex)   \(px), \(py)"
        drawBadge(text, at: CGPoint(x: loupe.minX, y: loupe.maxY + 6), width: side)
    }

    private func drawSizeLabel(for r: CGRect) {
        let s = snapshot.scale
        let text = "\(Int((r.width * s).rounded())) × \(Int((r.height * s).rounded()))"
        var p = CGPoint(x: r.maxX - 110, y: r.maxY + 6)
        if p.y + 22 > bounds.maxY { p.y = r.maxY - 28 }
        p.x = max(r.minX, p.x)
        drawBadge(text, at: p, width: 110)
    }

    private func drawHint() {
        let text = mode == .area ? "Drag to select · Click a window · Space: window mode · Esc: cancel"
                                          : "Click a window · Space: area mode · Esc: cancel"
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: bounds.midX - size.width / 2 - 12, y: bounds.maxY - 48, width: size.width + 24, height: 26)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 12, y: rect.minY + (26 - size.height) / 2), withAttributes: attrs)
    }

    private func drawBadge(_ text: String, at p: CGPoint, width: CGFloat) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        let rect = CGRect(x: p.x, y: p.y, width: max(width, size.width + 12), height: size.height + 6)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 3), withAttributes: attrs)
    }
}
