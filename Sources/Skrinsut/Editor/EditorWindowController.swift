import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The editor. Everything lives in a unified title-bar toolbar:
/// Copy Save | Pin | Drag-out OCR · tools … color/size/zoom read-outs; the canvas sits on a dark checkerboard.
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, CanvasViewDelegate {
    var onClose: ((EditorWindowController) -> Void)?

    private let canvas: CanvasView
    private let backdropView: BackdropView
    private let backdropModel = BackdropModel(settings: BackdropSettings.load())
    private var backdropSidebar: NSView!
    private var backdropSeparator: NSView!
    private let scrollView = NSScrollView()
    private var magnificationObserver: NSObjectProtocol?
    private let originalSize: CGSize

    // Toolbar pieces
    private var toolButtons: [Tool: ToolbarIconButton] = [:]
    private var backdropButton: ToolbarIconButton!
    private var addCaptureButton: ToolbarIconButton!
    private var moreButton: ToolbarIconButton!
    /// Buttons in the collapsible tool row, in display order (tools, then Backdrop).
    private var collapsibleButtons: [ToolbarIconButton] = []
    private var actionsView: NSView?
    private var readoutsView: NSView?
    private var styleGroup: NSView?
    private var styleButton: StyleColorButton!
    private let stylePopover = NSPopover()
    private let styleController = StylePopoverController()
    private let colorReadout = ToolbarReadout(caption: "Tab to copy", showsDot: true, minWidth: 104)
    private let sizeReadout = ToolbarReadout(caption: "Image size", minWidth: 92)
    private let zoomReadout = ToolbarReadout(caption: "Zoom", minWidth: 44)
    private var lastHoverColor: NSColor?
    // The highlighter keeps its own color (Stabilo yellow by default); other tools share the pen color.
    private static let highlighterColorKey = "editor-highlighterColor"
    private var penColor: NSColor = .systemRed
    private var highlighterColor = NSColor(hex: UserDefaults.standard.string(forKey: highlighterColorKey) ?? "") ?? NSColor(hex: "#FFEA00")!
    private var lastTool: Tool = .arrow

    private static let toolOrder: [Tool] = [.select, .arrow, .text, .ruler, .rectangle, .blur, .freehand, .magnifier,
                                            .highlighter, .spotlight, .counter, .oval, .line, .crop]

    /// Editor windows open at this width (narrower only if the screen is); height follows the image.
    private static let defaultWidth: CGFloat = 1000

    private enum Item {
        static let actions = NSToolbarItem.Identifier("actions")
        static let tools = NSToolbarItem.Identifier("tools")
        static let readouts = NSToolbarItem.Identifier("readouts")
    }

    init(shot: Screenshot) {
        canvas = CanvasView(shot: shot)
        originalSize = CGSize(width: shot.image.width, height: shot.image.height)
        backdropView = BackdropView(canvas: canvas)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Skrinsut"
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.minSize = CGSize(width: 480, height: 360) // the toolbar collapses into "•••" below this
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        if Settings.alwaysOnTop { window.level = .floating }
        super.init(window: window)
        window.delegate = self
        canvas.delegate = self
        buildToolbar()
        buildContent()
        sizeWindowToImage()
        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let magnificationObserver { NotificationCenter.default.removeObserver(magnificationObserver) }
    }

    // MARK: Toolbar

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "SkrinsutEditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar

        styleController.onColor = { [weak self] c in self?.setStyle(color: c) }
        styleController.onSize = { [weak self] s in self?.setStyle(size: s) }
        styleController.onFill = { [weak self] f in self?.setStyle(filled: f) }
        styleController.onFillOpacity = { [weak self] o in self?.setStyle(fillOpacity: o) }
        styleController.onTextStyle = { [weak self] t in self?.setStyle(textStyle: t) }
        stylePopover.contentViewController = styleController
        stylePopover.behavior = .transient

        colorReadout.onClick = { [weak self] in self?.copyHoverColor() }
        colorReadout.toolTip = "Press Tab (or click) to copy the color under the cursor"
        zoomReadout.onClick = { [weak self] in self?.menuZoomToFit(nil) }
        zoomReadout.toolTip = "Click to zoom to fit (⌘1) · ⌘0 for 100%"
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Item.actions, Item.tools, .flexibleSpace, Item.readouts]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case Item.actions:
            let copy = ToolbarIconButton(symbol: "doc.on.doc", tip: "Copy Image (⇧⌘C)", target: self, action: #selector(menuCopy(_:)))
            let save = ToolbarIconButton(symbol: "square.and.arrow.down", tip: "Save Image (⌘S)", target: self, action: #selector(menuSave(_:)))
            let pin = ToolbarIconButton(symbol: "pin", tip: "Pin to Screen (⌘P)", target: self, action: #selector(menuPin(_:)))
            let drag = DragOutButton { [weak self] in self?.finalImage() }
            let ocr = ToolbarIconButton(symbol: "text.viewfinder", tip: "Recognize Text (⇧⌘R)", target: self, action: #selector(recognizeText(_:)))
            let row = NSStackView(views: [copy, ToolbarDivider(), save, ToolbarDivider(), pin, ToolbarDivider(), drag, ocr])
            row.spacing = 4
            let v = padded(row, leading: 0, trailing: 18)
            actionsView = v
            item.view = v
        case Item.tools:
            var views: [NSView] = []
            for tool in Self.toolOrder {
                let key = tool.shortcut.map { " (\(String($0).uppercased()))" } ?? ""
                let b = ToolbarIconButton(symbol: tool.symbol, tip: tool.title + key, target: self, action: #selector(toolButtonClicked(_:)))
                b.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
                toolButtons[tool] = b
                views.append(b)
            }
            addCaptureButton = ToolbarIconButton(symbol: "photo.badge.plus", tip: "Add Capture / Image", target: self,
                                                 action: #selector(showAddCaptureMenu(_:)))
            views.append(addCaptureButton)
            backdropButton = ToolbarIconButton(symbol: "sparkles.rectangle.stack", tip: "Backdrop / Beautify", target: self,
                                               action: #selector(toggleBackdropPanel(_:)))
            views.append(backdropButton)
            collapsibleButtons = views.compactMap { $0 as? ToolbarIconButton }
            moreButton = ToolbarIconButton(symbol: "ellipsis", tip: "More tools", target: self, action: #selector(showMoreTools(_:)))
            moreButton.isHidden = true
            views.append(moreButton)
            styleButton = StyleColorButton(target: self, action: #selector(showStylePopover(_:)))
            styleButton.color = canvas.color
            let divider = ToolbarDivider()
            views.append(divider)
            views.append(styleButton)
            styleGroup = divider
            let row = NSStackView(views: views)
            row.spacing = 2
            item.view = row
            updateToolSelection()
        case Item.readouts:
            let row = NSStackView(views: [colorReadout, ToolbarDivider(height: 30), sizeReadout, ToolbarDivider(height: 30), zoomReadout])
            row.spacing = 16
            let v = padded(row, leading: 12, trailing: 6)
            readoutsView = v
            item.view = v
        default:
            return nil
        }
        item.isBordered = false   // flat look: no glass capsule behind the group
        return item
    }

    private func padded(_ view: NSView, leading: CGFloat, trailing: CGFloat) -> NSView {
        let row = NSStackView(views: [view])
        row.edgeInsets = NSEdgeInsets(top: 0, left: leading, bottom: 0, right: trailing)
        return row
    }

    private func updateToolSelection() {
        for (tool, button) in toolButtons { button.isSelected = tool == canvas.tool }
        backdropButton?.isSelected = backdropModel.settings.enabled
        // Highlight "•••" when the active tool is folded into it.
        moreButton?.isSelected = toolButtons[canvas.tool]?.isHidden == true
    }

    // MARK: Responsive toolbar

    private static let slotWidth: CGFloat = 36   // button 34 + stack spacing 2

    /// Folds trailing tools into the "•••" menu when the window is too narrow to show them all.
    private func layoutToolbar() {
        guard let window, !collapsibleButtons.isEmpty else { return }
        let width = window.frame.width

        let fixed = [actionsView, readoutsView]
            .compactMap { $0 }
            .filter { !$0.isHidden }
            .reduce(CGFloat(0)) { $0 + $1.fittingSize.width }
        // Traffic lights, toolbar item spacing/margins, and the style divider + color button.
        let reserved: CGFloat = 96 + 4 + 40
        let slots = Int(((width - fixed - reserved) / Self.slotWidth).rounded(.down))

        let total = collapsibleButtons.count
        let visible = slots >= total ? total : max(1, slots - 1)  // keep a slot for "•••"
        for (i, b) in collapsibleButtons.enumerated() { b.isHidden = i >= visible }
        moreButton.isHidden = visible >= total
        updateToolSelection()
    }

    @objc private func showMoreTools(_ sender: NSButton) {
        let menu = NSMenu()
        for button in collapsibleButtons where button.isHidden {
            let item: NSMenuItem
            if button === backdropButton {
                item = NSMenuItem(title: "Backdrop / Beautify", action: #selector(toggleBackdropPanel(_:)), keyEquivalent: "")
                item.state = backdropModel.settings.enabled ? .on : .off
            } else if button === addCaptureButton {
                item = NSMenuItem(title: "Add Capture / Image", action: nil, keyEquivalent: "")
                item.submenu = addCaptureMenu()
            } else {
                guard let raw = button.identifier?.rawValue, let tool = Tool(rawValue: raw) else { continue }
                item = NSMenuItem(title: tool.title, action: #selector(selectTool(_:)), keyEquivalent: tool.shortcut.map(String.init) ?? "")
                item.keyEquivalentModifierMask = []
                item.representedObject = tool.rawValue
                item.state = tool == canvas.tool ? .on : .off
            }
            item.target = self
            item.image = button.image
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    // MARK: Content

    private func buildContent() {
        guard let content = window?.contentView else { return }

        let clip = CenteringClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = backdropView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.05
        scrollView.maxMagnification = 16
        scrollView.backgroundColor = .editorCheckerboard
        scrollView.drawsBackground = true
        scrollView.borderType = .noBorder
        magnificationObserver = NotificationCenter.default.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification,
                                                                       object: scrollView, queue: .main) { [weak self] _ in
            self?.updateStatus()
            self?.backdropView.refreshDisplay()
        }

        let overlay = OverflowOverlayView(frame: scrollView.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.canvas = canvas
        scrollView.addSubview(overlay, positioned: .above, relativeTo: nil)
        canvas.onOverflowPreviewChange = { [weak overlay] in overlay?.needsDisplay = true }

        backdropView.settings = backdropModel.settings
        backdropModel.onChange = { [weak self] settings in self?.backdropChanged(settings) }
        let sidebar = NSHostingView(rootView: BackdropPanel(model: backdropModel))
        sidebar.isHidden = true
        sidebar.setContentHuggingPriority(.required, for: .horizontal)
        backdropSidebar = sidebar
        let sep = NSBox()
        sep.boxType = .separator
        sep.isHidden = true
        backdropSeparator = sep

        let middle = NSStackView(views: [scrollView, sep, sidebar])
        middle.orientation = .horizontal
        middle.spacing = 0
        middle.alignment = .height
        middle.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(middle)
        NSLayoutConstraint.activate([
            middle.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            middle.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            middle.topAnchor.constraint(equalTo: content.topAnchor),
            middle.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func sizeWindowToImage() {
        guard let window, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let img = canvas.imagePointSize
        let w = min(Self.defaultWidth, vf.width * 0.92)
        // Height for the image as it will be shown: zoomed to fit the width, never above 100%.
        let fit = min(1, (w - 48) / max(img.width, 1))
        let h = min(max(img.height * fit + 48, 520), vf.height * 0.92)
        window.setContentSize(CGSize(width: w, height: h))
        window.center()
        DispatchQueue.main.async { self.zoomToFit(maxZoom: 1) }
    }

    func present() {
        layoutToolbar()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Zoom

    private func zoomToFit(maxZoom: CGFloat = 4) {
        let avail = scrollView.contentView.bounds.size.applying(CGAffineTransform(scaleX: scrollView.magnification, y: scrollView.magnification))
        let img = backdropView.frame.size
        guard img.width > 0, img.height > 0 else { return }
        let z = min((avail.width - 48) / img.width, (avail.height - 48) / img.height, maxZoom)
        setZoom(max(z, scrollView.minMagnification))
    }

    private func setZoom(_ z: CGFloat) {
        let center = CGPoint(x: backdropView.bounds.midX, y: backdropView.bounds.midY)
        scrollView.setMagnification(z, centeredAt: center)
        updateStatus()
        backdropView.refreshDisplay()
    }

    @objc func menuZoomIn(_ sender: Any?) { setZoom(min(scrollView.magnification * 1.25, scrollView.maxMagnification)) }
    @objc func menuZoomOut(_ sender: Any?) { setZoom(max(scrollView.magnification / 1.25, scrollView.minMagnification)) }
    @objc func menuZoomToFit(_ sender: Any?) { zoomToFit() }
    @objc func menuZoomTo100(_ sender: Any?) { setZoom(1) }

    @objc func menuZoomToSelection(_ sender: Any?) {
        guard let sel = canvas.selected else { return }
        let r = backdropView.convert(sel.bounds.insetBy(dx: -30, dy: -30), from: canvas)
        scrollView.magnify(toFit: r)
        updateStatus()
    }

    // MARK: Tools and style

    @objc private func toolButtonClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let t = Tool(rawValue: raw) else { return }
        canvas.tool = t
        canvas(canvas, didChangeTool: t)
    }

    @objc func selectTool(_ sender: NSMenuItem) {
        guard let t = Tool(rawValue: sender.representedObject as? String ?? "") else { return }
        canvas.tool = t
        canvas(canvas, didChangeTool: t)
    }

    // MARK: Add Capture

    private func addCaptureMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Capture Area…", #selector(menuAddCapture(_:))),
                                ("From Clipboard", #selector(addImageFromClipboard(_:))),
                                ("From File…", #selector(addImageFromFile(_:)))] {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        return menu
    }

    @objc private func showAddCaptureMenu(_ sender: NSButton) {
        addCaptureMenu().popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }

    /// Takes a new area screenshot and drops it into this image as an object ("Add Capture").
    @objc func menuAddCapture(_ sender: Any?) {
        AppDelegate.shared?.pickArea { [weak self] shot in
            guard let self else { return }
            self.present()
            self.canvas.insertImage(shot)
        }
    }

    @objc private func addImageFromClipboard(_ sender: Any?) { canvas.paste(sender) }

    @objc private func addImageFromFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.beginSheetModal(for: window) { [weak self] resp in
            guard resp == .OK, let url = panel.url, let rep = NSImageRep(contentsOf: url), let cg = rep.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let scale = rep.size.width > 0 ? CGFloat(cg.width) / rep.size.width : 1
            self?.canvas.insertImage(Screenshot(image: cg, scale: max(1, scale)))
        }
    }

    @objc private func showStylePopover(_ sender: NSButton) {
        styleController.sync(color: canvas.color, size: canvas.size, filled: canvas.filled,
                             fillOpacity: canvas.fillOpacity, textStyle: canvas.textStyle)
        stylePopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func setStyle(color: NSColor? = nil, size: CGFloat? = nil, filled: Bool? = nil,
                          fillOpacity: CGFloat? = nil, textStyle: TextStyle? = nil) {
        if let color {
            canvas.color = color
            styleButton.color = color
            if canvas.tool == .highlighter { rememberHighlighterColor(color) }
        }
        if let size { canvas.size = size }
        if let filled { canvas.filled = filled }
        if let fillOpacity { canvas.fillOpacity = fillOpacity }
        if let textStyle { canvas.textStyle = textStyle }
        if canvas.selected != nil { canvas.applyStyleToSelection() }
    }

    private func rememberHighlighterColor(_ c: NSColor) {
        highlighterColor = c
        UserDefaults.standard.set(c.hexString, forKey: Self.highlighterColorKey)
    }

    private func copyHoverColor() {
        guard let c = lastHoverColor else { return }
        Exporter.copyText(c.hexString)
        Toast.show("Copied \(c.hexString)")
    }

    // MARK: File / Edit actions (also reachable from the main menu via the responder chain)

    /// The exported image: annotations flattened, then composited onto the backdrop when enabled.
    func finalImage() -> Screenshot? {
        guard let shot = canvas.flattened() else { return nil }
        return BackdropRenderer.render(shot, settings: backdropModel.settings, wallpaper: backdropView.wallpaper)
    }

    @objc func toggleBackdropPanel(_ sender: Any?) {
        let show = backdropSidebar.isHidden
        backdropSidebar.isHidden = !show
        backdropSeparator.isHidden = !show
        if show, !backdropModel.settings.enabled { backdropModel.settings.enabled = true }
        updateToolSelection()
        // Re-fit and repaint after the sidebar has taken its space in the layout.
        DispatchQueue.main.async {
            self.window?.layoutIfNeeded()
            self.zoomToFit(maxZoom: max(1, self.scrollView.magnification))
            self.backdropView.refreshDisplay()
        }
    }

    private func backdropChanged(_ settings: BackdropSettings) {
        let sizeChanged = BackdropLayout(imageSize: canvas.imagePointSize, settings: settings).canvasSize != backdropView.frame.size
        backdropView.settings = settings
        if settings.enabled, settings.fill == .wallpaper, backdropView.wallpaper == nil { loadWallpaper() }
        updateToolSelection()
        updateStatus()
        if sizeChanged { zoomToFit(maxZoom: max(1, scrollView.magnification)) }
    }

    private func loadWallpaper() {
        if let wp = WallpaperProvider.current() { backdropView.wallpaper = wp; return }
        Task { @MainActor in
            if let wp = await WallpaperProvider.captureFromScreen() { self.backdropView.wallpaper = wp }
        }
    }

    /// Copy Image (toolbar, ⇧⌘C, ⌘C on the canvas): copies, then closes the editor — the copy is the hand-off.
    @objc func menuCopy(_ sender: Any?) {
        guard let shot = finalImage() else { return }
        Exporter.copy(shot)
        window?.close()
    }

    @objc func menuSave(_ sender: Any?) {
        guard let shot = finalImage() else { return }
        Exporter.save(shot)
    }

    @objc func menuSaveAs(_ sender: Any?) {
        guard let shot = finalImage() else { return }
        Exporter.saveAs(shot, from: window)
    }

    @objc func menuPin(_ sender: Any?) {
        guard let shot = finalImage() else { return }
        PinWindowController.pin(shot)
    }

    @objc func menuPrint(_ sender: Any?) {
        guard let shot = finalImage() else { return }
        let iv = NSImageView(image: NSImage(cgImage: shot.image, size: shot.pointSize))
        iv.frame = CGRect(origin: .zero, size: shot.pointSize)
        NSPrintOperation(view: iv).runModal(for: window!, delegate: nil, didRun: nil, contextInfo: nil)
    }

    @objc func recognizeText(_ sender: Any?) {
        guard let shot = canvas.flattened() else { return }
        AppDelegate.shared?.runOCR(on: shot.image)
    }

    @objc func undo(_ sender: Any?) { canvas.undo() }
    @objc func redo(_ sender: Any?) { canvas.redo() }
    @objc func menuRasterize(_ sender: Any?) { canvas.rasterize() }
    @objc func delete(_ sender: Any?) { canvas.deleteSelected() }

    @objc func menuUncrop(_ sender: Any?) {
        // Crops are undoable; walk back to the most recent full-size base.
        while canvas.canUndo, CGFloat(canvas.state.base.width) < originalSize.width || CGFloat(canvas.state.base.height) < originalSize.height {
            canvas.undo()
        }
    }

    @objc func toggleSnapping(_ sender: Any?) {
        Settings.snapping.toggle()
        Toast.show(Settings.snapping ? "Snapping on" : "Snapping off", detail: Settings.snapping ? "Hold ⌘ while dragging to skip snapping" : nil)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(toggleSnapping(_:)):
            item.state = Settings.snapping ? .on : .off
            return true
        case #selector(undo(_:)): return canvas.canUndo
        case #selector(redo(_:)): return canvas.canRedo
        case #selector(delete(_:)), #selector(menuZoomToSelection(_:)): return canvas.selected != nil
        case #selector(selectTool(_:)):
            item.state = (item.representedObject as? String) == canvas.tool.rawValue ? .on : .off
            return true
        default: return true
        }
    }

    // MARK: CanvasViewDelegate

    func canvasDidChange(_ canvas: CanvasView) {
        window?.isDocumentEdited = !canvas.state.annotations.isEmpty
    }

    func canvasDidResize(_ canvas: CanvasView) {
        backdropView.relayout()
        updateStatus()
        DispatchQueue.main.async { self.zoomToFit(maxZoom: max(1, self.scrollView.magnification)) }
    }

    func canvas(_ canvas: CanvasView, hoverPixel: CGPoint?, color: NSColor?) {
        guard let color else { return } // keep the last sampled color visible
        lastHoverColor = color
        colorReadout.valueLabel.stringValue = color.hexString
        colorReadout.dot.layer?.backgroundColor = color.cgColor
    }

    func canvas(_ canvas: CanvasView, didSelect annotation: Annotation?) {
        guard let a = annotation else { return }
        canvas.color = a.color
        canvas.size = a.size
        canvas.filled = a.filled
        if a.kind == .rectangle || a.kind == .oval { canvas.fillOpacity = a.fillOpacity }
        if a.kind == .text { canvas.textStyle = a.textStyle }
        styleButton?.color = a.color
        if stylePopover.isShown {
            styleController.sync(color: a.color, size: a.size, filled: a.filled,
                                 fillOpacity: canvas.fillOpacity, textStyle: canvas.textStyle)
        }
    }

    func canvas(_ canvas: CanvasView, didChangeTool tool: Tool) {
        if (tool == .highlighter) != (lastTool == .highlighter) {
            if tool == .highlighter {
                penColor = canvas.color
                canvas.color = highlighterColor
            } else {
                rememberHighlighterColor(canvas.color)
                canvas.color = penColor
            }
            styleButton?.color = canvas.color
        }
        lastTool = tool
        updateToolSelection()
        window?.makeFirstResponder(canvas)
    }

    func canvasRequestsCopyColor(_ canvas: CanvasView) { copyHoverColor() }

    func canvasRequestsClose(_ canvas: CanvasView) {
        if Settings.copyOnEsc, let shot = finalImage() { Exporter.copy(shot) }
        if Settings.saveOnEsc { menuSave(nil) }
        window?.close()
    }

    private func updateStatus() {
        let pt = canvas.imagePointSize
        if backdropModel.settings.enabled {
            let c = backdropView.layout.canvasSize
            sizeReadout.valueLabel.stringValue = "\(Int(c.width))×\(Int(c.height))pt"
            sizeReadout.captionLabel.stringValue = "With backdrop"
        } else {
            sizeReadout.valueLabel.stringValue = "\(Int(pt.width.rounded()))×\(Int(pt.height.rounded()))pt"
            sizeReadout.captionLabel.stringValue = "Image size"
        }
        sizeReadout.toolTip = "\(canvas.state.base.width)×\(canvas.state.base.height) px at @\(Int(canvas.scale))x"
        zoomReadout.valueLabel.stringValue = "\(Int((scrollView.magnification * 100).rounded()))%"
        if colorReadout.valueLabel.stringValue.isEmpty {
            colorReadout.valueLabel.stringValue = "#------"
            colorReadout.dot.layer?.backgroundColor = NSColor.clear.cgColor
        }
        window?.title = "Skrinsut — \(canvas.state.base.width)×\(canvas.state.base.height)"
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        backdropView.refreshDisplay()
        layoutToolbar()
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }
}

/// Keeps the document centered when it is smaller than the visible area.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

final class ColorDotButton: NSButton {
    private let dotColor: NSColor

    init(color: NSColor, diameter: CGFloat = 16) {
        dotColor = color
        super.init(frame: CGRect(x: 0, y: 0, width: diameter, height: diameter))
        isBordered = false
        title = ""
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: diameter).isActive = true
        heightAnchor.constraint(equalToConstant: diameter).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        dotColor.setFill()
        let p = NSBezierPath(ovalIn: r)
        p.fill()
        NSColor.separatorColor.setStroke()
        p.lineWidth = 1
        p.stroke()
    }
}

/// A button that starts a file drag of the current image (drag-out).
final class DragOutButton: NSButton, NSDraggingSource {
    private let provider: () -> Screenshot?

    init(provider: @escaping () -> Screenshot?) {
        self.provider = provider
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        image = NSImage(systemSymbolName: "doc.viewfinder", accessibilityDescription: "Drag out")?.withSymbolConfiguration(config)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = .labelColor
        toolTip = "Drag the image into another app"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 34).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { false }

    override func mouseDown(with event: NSEvent) {
        guard let shot = provider(), let url = Exporter.temporaryFile(shot) else { return }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let thumb = NSImage(cgImage: shot.image, size: shot.pointSize)
        let w: CGFloat = 120
        let h = w * shot.pointSize.height / max(shot.pointSize.width, 1)
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), contents: thumb)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}
