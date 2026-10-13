import AppKit

/// Building blocks for the editor's unified title-bar toolbar.

/// Borderless icon button; draws a rounded highlight when `isSelected` (used for the tool row).
final class ToolbarIconButton: NSButton {
    var isSelected = false { didSet { updateHighlight() } }
    private var hovering = false { didSet { updateHighlight() } }

    init(symbol: String, tip: String, target: AnyObject?, action: Selector?, pointSize: CGFloat = 15) {
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?.withSymbolConfiguration(config)
        imagePosition = .imageOnly
        isBordered = false
        toolTip = tip
        self.target = target
        self.action = action
        contentTintColor = .labelColor
        wantsLayer = true
        layer?.cornerRadius = 7
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    // Keep keyboard focus on the canvas so single-key tools and Tab-to-copy keep working.
    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func updateHighlight() {
        let alpha: CGFloat = isSelected ? 0.16 : (hovering ? 0.08 : 0)
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(alpha).cgColor
    }
}

/// Thin vertical separator between toolbar groups.
final class ToolbarDivider: NSView {
    init(height: CGFloat = 20) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.separatorColor.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 1).isActive = true
        heightAnchor.constraint(equalToConstant: height).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// Two-line read-out ("#000000 / Tab to copy", "382×586pt / Image size", "100% / Zoom"), optionally clickable.
final class ToolbarReadout: NSView {
    let valueLabel = NSTextField(labelWithString: "")
    let captionLabel = NSTextField(labelWithString: "")
    let dot = NSView()
    var onClick: (() -> Void)?

    init(caption: String, showsDot: Bool = false, minWidth: CGFloat = 0) {
        super.init(frame: .zero)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        valueLabel.textColor = .labelColor
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.stringValue = caption
        let text = NSStackView(views: [valueLabel, captionLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 0

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 9
        dot.layer?.borderWidth = 1
        dot.layer?.borderColor = NSColor.separatorColor.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.widthAnchor.constraint(equalToConstant: 18).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 18).isActive = true
        dot.isHidden = !showsDot

        let row = NSStackView(views: [dot, text])
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: minWidth),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func resetCursorRects() {
        if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// Click-through layer above the editor's scroll area that draws the off-canvas part of an object being dragged.
final class OverflowOverlayView: NSView {
    weak var canvas: CanvasView?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let canvas, canvas.overflowPreview != nil, let ctx = NSGraphicsContext.current?.cgContext else { return }
        // Map canvas points into overlay space (accounts for scroll position and magnification).
        let o = convert(CGPoint.zero, from: canvas)
        let u = convert(CGPoint(x: 1, y: 1), from: canvas)
        ctx.saveGState()
        ctx.translateBy(x: o.x, y: o.y)
        ctx.scaleBy(x: u.x - o.x, y: u.y - o.y)
        canvas.drawOverflowPreview()
        ctx.restoreGState()
    }
}

/// Large color circle that opens the annotation style popover.
final class StyleColorButton: NSButton {
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }

    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        isBordered = false
        title = ""
        self.target = target
        self.action = action
        toolTip = "Color, size and style"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 30).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 5, dy: 5)
        color.setFill()
        let p = NSBezierPath(ovalIn: r)
        p.fill()
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        p.lineWidth = 1
        p.stroke()
    }
}

/// Popover content: quick colors, color well, size, fill, and text style.
final class StylePopoverController: NSViewController {
    static let quickColors: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemTeal, .systemBlue,
                                         .systemPurple, .systemPink, .black, .darkGray, .white]

    var onColor: ((NSColor) -> Void)?
    var onSize: ((CGFloat) -> Void)?
    var onFill: ((Bool) -> Void)?
    var onFillOpacity: ((CGFloat) -> Void)?
    var onTextStyle: ((TextStyle) -> Void)?

    private let colorWell = NSColorWell(style: .minimal)
    private let sizeSlider = NSSlider(value: 3, minValue: 1, maxValue: 10, target: nil, action: nil)
    private let fillCheckbox = NSButton(checkboxWithTitle: "Fill shapes", target: nil, action: nil)
    private let fillOpacitySlider = NSSlider(value: 100, minValue: 5, maxValue: 100, target: nil, action: nil)
    private let fillOpacityLabel = NSTextField(labelWithString: "100%")
    private let textStyleControl = NSSegmentedControl()

    override func loadView() {
        let swatches = NSGridView()
        swatches.rowSpacing = 6
        swatches.columnSpacing = 6
        let perRow = 6
        for start in stride(from: 0, to: Self.quickColors.count, by: perRow) {
            let row: [NSView] = Self.quickColors[start..<min(start + perRow, Self.quickColors.count)].enumerated().map { offset, c in
                let b = ColorDotButton(color: c, diameter: 22)
                b.tag = start + offset
                b.target = self
                b.action = #selector(swatchPicked(_:))
                return b
            }
            swatches.addRow(with: row)
        }

        colorWell.target = self
        colorWell.action = #selector(wellChanged(_:))
        let colorRow = NSStackView(views: [swatches, colorWell])
        colorRow.alignment = .top
        colorRow.spacing = 10

        sizeSlider.target = self
        sizeSlider.action = #selector(sizeChanged(_:))
        sizeSlider.numberOfTickMarks = 10
        sizeSlider.allowsTickMarkValuesOnly = true
        sizeSlider.widthAnchor.constraint(equalToConstant: 200).isActive = true

        fillCheckbox.target = self
        fillCheckbox.action = #selector(fillChanged(_:))
        fillOpacitySlider.target = self
        fillOpacitySlider.action = #selector(fillOpacityChanged(_:))
        fillOpacitySlider.isContinuous = true
        fillOpacitySlider.widthAnchor.constraint(equalToConstant: 140).isActive = true
        fillOpacityLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        fillOpacityLabel.textColor = .secondaryLabelColor
        fillOpacityLabel.alignment = .right
        fillOpacityLabel.widthAnchor.constraint(equalToConstant: 36).isActive = true
        let opacityTitle = NSTextField(labelWithString: "Opacity")
        opacityTitle.font = .systemFont(ofSize: 11)
        opacityTitle.textColor = .secondaryLabelColor
        let fillRow = NSStackView(views: [fillCheckbox])
        let opacityRow = NSStackView(views: [opacityTitle, fillOpacitySlider, fillOpacityLabel])
        opacityRow.spacing = 6
        let fillGroup = NSStackView(views: [fillRow, opacityRow])
        fillGroup.orientation = .vertical
        fillGroup.alignment = .leading
        fillGroup.spacing = 4
        self.fillGroup = fillGroup

        textStyleControl.segmentCount = TextStyle.allCases.count
        textStyleControl.trackingMode = .selectOne
        for (i, s) in TextStyle.allCases.enumerated() {
            textStyleControl.setLabel(s.title, forSegment: i)
            textStyleControl.setWidth(62, forSegment: i)
        }
        textStyleControl.target = self
        textStyleControl.action = #selector(textStyleChanged(_:))

        func caption(_ s: String) -> NSTextField {
            let l = NSTextField(labelWithString: s)
            l.font = .systemFont(ofSize: 11, weight: .medium)
            l.textColor = .secondaryLabelColor
            return l
        }

        let stack = NSStackView(views: [caption("Color"), colorRow, caption("Size"), sizeSlider, fillGroup,
                                        caption("Text style"), textStyleControl])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: colorRow)
        stack.setCustomSpacing(14, after: fillGroup)
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        view = stack
    }

    private var fillGroup = NSStackView()

    func sync(color: NSColor, size: CGFloat, filled: Bool, fillOpacity: CGFloat, textStyle: TextStyle) {
        _ = view
        colorWell.color = color
        sizeSlider.doubleValue = Double(size)
        fillCheckbox.state = filled ? .on : .off
        fillOpacitySlider.doubleValue = Double(fillOpacity * 100)
        fillOpacitySlider.isEnabled = filled
        fillOpacityLabel.stringValue = "\(Int((fillOpacity * 100).rounded()))%"
        textStyleControl.selectedSegment = textStyle.rawValue
    }

    @objc private func swatchPicked(_ sender: NSButton) {
        let c = Self.quickColors[sender.tag]
        colorWell.color = c
        onColor?(c)
    }

    @objc private func wellChanged(_ sender: NSColorWell) { onColor?(sender.color) }
    @objc private func sizeChanged(_ sender: NSSlider) { onSize?(CGFloat(sender.doubleValue.rounded())) }
    @objc private func fillChanged(_ sender: NSButton) {
        fillOpacitySlider.isEnabled = sender.state == .on
        onFill?(sender.state == .on)
    }

    @objc private func fillOpacityChanged(_ sender: NSSlider) {
        let pct = (sender.doubleValue / 5).rounded() * 5 // 5% steps
        fillOpacityLabel.stringValue = "\(Int(pct))%"
        onFillOpacity?(CGFloat(pct / 100))
    }
    @objc private func textStyleChanged(_ sender: NSSegmentedControl) { onTextStyle?(TextStyle(rawValue: sender.selectedSegment) ?? .background) }
}

extension NSColor {
    /// Dark checkerboard used behind the canvas (transparency grid).
    static let editorCheckerboard: NSColor = {
        let tile: CGFloat = 10
        let image = NSImage(size: CGSize(width: tile * 2, height: tile * 2), flipped: false) { _ in
            NSColor(white: 0.17, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: tile * 2, height: tile * 2).fill()
            NSColor(white: 0.21, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: tile, height: tile).fill()
            CGRect(x: tile, y: tile, width: tile, height: tile).fill()
            return true
        }
        return NSColor(patternImage: image)
    }()
}
