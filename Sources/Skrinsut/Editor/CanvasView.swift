import AppKit

struct EditorState {
    var base: CGImage
    var annotations: [Annotation] = []
    var nextCounter = 1
}

protocol CanvasViewDelegate: AnyObject {
    func canvasDidChange(_ canvas: CanvasView)
    func canvasDidResize(_ canvas: CanvasView)
    func canvas(_ canvas: CanvasView, hoverPixel: CGPoint?, color: NSColor?)
    func canvas(_ canvas: CanvasView, didSelect annotation: Annotation?)
    func canvas(_ canvas: CanvasView, didChangeTool tool: Tool)
    func canvasRequestsClose(_ canvas: CanvasView)
    func canvasRequestsCopyColor(_ canvas: CanvasView)
}

/// The editable document surface. Flipped, measured in image points; magnification is handled by the enclosing scroll view.
final class CanvasView: NSView, NSTextFieldDelegate {
    weak var delegate: CanvasViewDelegate?
    private(set) var state: EditorState
    let scale: CGFloat
    private let renderer = Renderer()
    private var sampler: PixelSampler?
    /// Ruler tool hover preview: auto-detected horizontal/vertical measurements under the cursor.
    private var autoMeasure: [Annotation] = []

    /// Live preview while an object is dragged past the image edge: the object and the area the canvas will grow to.
    struct OverflowPreview {
        let annotation: Annotation
        let extendedBounds: CGRect
        let fill: NSColor
    }
    private(set) var overflowPreview: OverflowPreview? { didSet { onOverflowPreviewChange?() } }
    /// Called whenever `overflowPreview` changes (the editor's overlay redraws).
    var onOverflowPreviewChange: (() -> Void)?
    private var cachedEdgeColor: NSColor?
    private var edgeMap: EdgeMap?
    private var snapGuides: [SnapGuide] = []

    var tool: Tool = .arrow {
        didSet {
            if tool != .crop { cropRect = nil }
            autoMeasure = []
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var color: NSColor = .systemRed
    var size: CGFloat = 3
    var filled = false
    var fillOpacity: CGFloat = 1
    var textStyle: TextStyle = .background

    private var undoStack: [EditorState] = []
    private var redoStack: [EditorState] = []
    private var pendingUndo: EditorState?

    private enum Drag {
        case creating(UUID)
        case moving(UUID, start: CGPoint, original: Annotation)
        case handle(UUID, isStart: Bool)
        case crop(start: CGPoint)
    }
    private var drag: Drag?
    private(set) var selectedID: UUID? {
        didSet { delegate?.canvas(self, didSelect: selected) }
    }
    private(set) var cropRect: CGRect?
    private var textField: NSTextField?
    private var editingTextID: UUID?

    var selected: Annotation? { state.annotations.first { $0.id == selectedID } }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var imagePointSize: CGSize { CGSize(width: CGFloat(state.base.width) / scale, height: CGFloat(state.base.height) / scale) }

    init(shot: Screenshot) {
        state = EditorState(base: shot.image)
        scale = shot.scale
        super.init(frame: CGRect(origin: .zero, size: shot.pointSize))
        sampler = PixelSampler(shot.image)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: tool == .select ? .arrow : (tool == .text ? .iBeam : .crosshair))
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    // MARK: Document operations

    func flattened() -> Screenshot? {
        commitTextEditing()
        guard let img = renderer.flatten(base: state.base, scale: scale, annotations: state.annotations) else { return nil }
        return Screenshot(image: img, scale: scale)
    }

    private func beginChange() { pendingUndo = state }

    private func commitChangeIfNeeded() {
        guard let p = pendingUndo else { return }
        undoStack.append(p)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        pendingUndo = nil
    }

    private func mutate(_ body: (inout EditorState) -> Void) {
        beginChange()
        commitChangeIfNeeded()
        body(&state)
        needsDisplay = true
        delegate?.canvasDidChange(self)
    }

    func undo() {
        commitTextEditing()
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(state)
        restore(prev)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(state)
        restore(next)
    }

    private func restore(_ s: EditorState) {
        let resized = s.base !== state.base
        state = s
        if selected == nil { selectedID = nil }
        if resized { baseChanged() }
        needsDisplay = true
        delegate?.canvasDidChange(self)
    }

    private func baseChanged() {
        sampler = PixelSampler(state.base)
        cachedEdgeColor = nil
        edgeMap = nil
        renderer.invalidateCache()
        setFrameSize(imagePointSize)
        delegate?.canvasDidResize(self)
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        mutate { $0.annotations.removeAll { $0.id == id } }
        selectedID = nil
    }

    func applyStyleToSelection() {
        guard let id = selectedID else { return }
        mutate { s in
            guard let i = s.annotations.firstIndex(where: { $0.id == id }) else { return }
            s.annotations[i].color = color
            s.annotations[i].size = size
            s.annotations[i].filled = filled
            s.annotations[i].fillOpacity = fillOpacity
            s.annotations[i].textStyle = textStyle
        }
    }

    func applyCrop() {
        guard let r = cropRect?.intersection(bounds), r.width >= 2, r.height >= 2 else { return }
        let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale).integral
        guard let cropped = state.base.cropping(to: px) else { return }
        let offset = CGVector(dx: -px.minX / scale, dy: -px.minY / scale)
        mutate { s in
            s.base = cropped
            for i in s.annotations.indices { s.annotations[i].offset(by: offset) }
        }
        cropRect = nil
        baseChanged()
    }

    func cancelCrop() {
        cropRect = nil
        needsDisplay = true
    }

    /// Bakes all annotations into the base image ("Rasterize (Merge) Image").
    func rasterize() {
        guard let flat = renderer.flatten(base: state.base, scale: scale, annotations: state.annotations) else { return }
        mutate { s in
            s.base = flat
            s.annotations.removeAll()
        }
        selectedID = nil
        baseChanged()
    }

    // MARK: Mouse

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitTextEditing()
        let p = point(event)
        pendingUndo = nil

        if tool == .crop {
            drag = .crop(start: snapActive(event) ? snapPoint(p, excluding: nil) : p)
            cropRect = nil
            return
        }

        // Endpoint handles of the selected object.
        if let sel = selected, sel.hasEndHandle {
            let tol = 7 / magnification
            if sel.isTwoPoint, hypot(p.x - sel.start.x, p.y - sel.start.y) <= tol { beginChange(); drag = .handle(sel.id, isStart: true); return }
            if hypot(p.x - sel.end.x, p.y - sel.end.y) <= tol { beginChange(); drag = .handle(sel.id, isStart: false); return }
        }

        if let hit = state.annotations.last(where: { $0.hitTest(p) }) {
            selectedID = hit.id
            if hit.kind == .text, event.clickCount == 2 {
                beginTextEditing(hit.id)
                return
            }
            beginChange()
            drag = .moving(hit.id, start: p, original: hit)
            needsDisplay = true
            return
        }

        guard let kind = tool.annotationKind else {
            selectedID = nil
            needsDisplay = true
            return
        }

        // Shapes, lines and rulers start on a snapped point so both corners can land on edges.
        let twoPoint = kind != .text && kind != .counter && kind != .freehand && kind != .highlighter
        let start = twoPoint && snapActive(event) && !event.modifierFlags.contains(.shift) ? snapPoint(p, excluding: nil) : p
        var a = Annotation(kind: kind, start: start, end: start, color: color, size: size, filled: filled)
        a.fillOpacity = fillOpacity
        a.textStyle = textStyle
        switch kind {
        case .text:
            // Callout pointer starts below-left of the text; drag its handle to aim it.
            a.end = CGPoint(x: p.x - a.fontSize * 1.5, y: p.y + a.fontSize * 3)
            mutate { $0.annotations.append(a) }
            selectedID = a.id
            beginTextEditing(a.id)
            return
        case .counter:
            a.number = state.nextCounter
            mutate {
                $0.annotations.append(a)
                $0.nextCounter += 1
            }
            selectedID = a.id
            return
        case .freehand, .highlighter:
            a.points = [p]
        default:
            break
        }
        beginChange()
        state.annotations.append(a)
        selectedID = a.id
        drag = .creating(a.id)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        var p = point(event)
        guard let drag else { return }
        // Crop stays inside the image; drawing may go past the edge (the canvas grows on mouse-up),
        // within a sane limit so a stray drag can't create a huge canvas.
        let limit: CGRect = if case .crop = drag { bounds } else { bounds.insetBy(dx: -Self.maxExtension, dy: -Self.maxExtension) }
        p.x = max(limit.minX, min(limit.maxX, p.x))
        p.y = max(limit.minY, min(limit.maxY, p.y))
        let shift = event.modifierFlags.contains(.shift)
        snapGuides = []
        var draggedPoint: CGPoint { snapActive(event) && !shift ? snapPoint(p, excluding: draggedObjectID) : p }
        switch drag {
        case .crop(let start):
            let p = draggedPoint
            cropRect = CGRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        case .creating(let id):
            let isStroke = state.annotations.first { $0.id == id }?.isStroke == true
            let p = isStroke ? p : draggedPoint
            update(id) { a in
                if a.kind == .highlighter && shift, let first = a.points.first {
                    // ⇧: a perfectly straight marker stroke (0/45/90°), e.g. along a line of text.
                    a.points = [first, constrained(first, p, kind: .line, shift: true)]
                } else if a.isStroke {
                    a.points.append(p)
                } else {
                    a.end = constrained(a.start, p, kind: a.kind, shift: shift)
                }
            }
        case .handle(let id, let isStart):
            commitChangeIfNeeded()
            let p = draggedPoint
            update(id) { a in
                if let img = a.image {
                    // Pictures always keep their aspect ratio while resizing.
                    let aspect = CGFloat(img.width) / CGFloat(max(img.height, 1))
                    if isStart { a.start = aspectLocked(a.end, p, aspect: aspect) } else { a.end = aspectLocked(a.start, p, aspect: aspect) }
                } else if isStart { a.start = constrained(a.end, p, kind: a.kind, shift: shift) } else { a.end = constrained(a.start, p, kind: a.kind, shift: shift) }
                a.labelAnchor = nil // edited by hand: label goes back to the line's midpoint
            }
        case .moving(let id, let start, let original):
            commitChangeIfNeeded()
            // Move from the original position (not incrementally) so snapping never accumulates drift.
            var a = original
            a.offset(by: CGVector(dx: p.x - start.x, dy: p.y - start.y))
            if snapActive(event) { a.offset(by: snapRect(a.bounds, excluding: id)) }
            update(id) { $0 = a }
        }
        updateOverflowPreview()
        needsDisplay = true
    }

    private var draggedObjectID: UUID? {
        switch drag {
        case .creating(let id), .moving(let id, _, _), .handle(let id, _): id
        default: nil
        }
    }

    private func updateOverflowPreview() {
        guard let id = draggedObjectID, let a = state.annotations.first(where: { $0.id == id }),
              let needed = overflowRect(for: a) else {
            if overflowPreview != nil { overflowPreview = nil }
            return
        }
        overflowPreview = OverflowPreview(annotation: a, extendedBounds: bounds.union(needed), fill: edgeFillColor())
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; pendingUndo = nil; overflowPreview = nil; snapGuides = []; needsDisplay = true }
        guard let drag else { return }
        switch drag {
        case .crop:
            if let r = cropRect, r.width < 3 || r.height < 3 { cropRect = nil }
        case .creating(let id):
            guard let a = state.annotations.first(where: { $0.id == id }) else { return }
            let degenerate: Bool
            if a.isStroke, let f = a.points.first {
                degenerate = a.points.count < 2 || a.points.allSatisfy { hypot($0.x - f.x, $0.y - f.y) < 2 }
            } else {
                degenerate = hypot(a.end.x - a.start.x, a.end.y - a.start.y) < 3
            }
            if degenerate {
                state.annotations.removeAll { $0.id == id }
                selectedID = nil
                // A plain click with the Ruler measures the gap/element under the cursor automatically.
                if a.kind == .ruler {
                    let rulers = measuredRulers(at: point(event)) // raw click point, not the snapped start
                    if !rulers.isEmpty { mutate { $0.annotations += rulers } }
                    autoMeasure = []
                }
            } else {
                commitChangeIfNeeded()
                extendToFit(id)
                delegate?.canvasDidChange(self)
            }
        case .moving(let id, _, _), .handle(let id, _):
            if pendingUndo == nil { extendToFit(id) } // only when something actually moved (change committed)
            delegate?.canvasDidChange(self)
        }
    }

    // MARK: Snapping

    /// Snapping is on unless disabled in Draw ▸ Snap to Objects; holding ⌘ skips it for one drag.
    private func snapActive(_ event: NSEvent) -> Bool {
        Settings.snapping && !event.modifierFlags.contains(.command)
    }

    private var snapThreshold: CGFloat { 6 / magnification }

    private func screenshotEdges() -> EdgeMap? {
        if edgeMap == nil, let sampler { edgeMap = EdgeMap(sampler: sampler, minRun: Int(16 * scale)) }
        return edgeMap
    }

    private struct SnapTarget {
        let position: CGFloat
        let span: ClosedRange<CGFloat>
    }

    /// Lines to snap to along one axis: canvas edges/center, other objects' edges/centers, and screenshot edges
    /// near `values` that run alongside `cross` (so far-away lines elsewhere in the image don't grab the object).
    private func snapTargets(vertical: Bool, near values: [CGFloat], cross: ClosedRange<CGFloat>, excluding id: UUID?) -> [SnapTarget] {
        let full = vertical ? 0...bounds.height : 0...bounds.width
        var targets = (vertical ? [0, bounds.midX, bounds.maxX] : [0, bounds.midY, bounds.maxY]).map { SnapTarget(position: $0, span: full) }
        for a in state.annotations where a.id != id {
            let b = a.bounds
            let span = vertical ? b.minY...b.maxY : b.minX...b.maxX
            for v in vertical ? [b.minX, b.midX, b.maxX] : [b.minY, b.midY, b.maxY] { targets.append(SnapTarget(position: v, span: span)) }
        }
        if let edges = screenshotEdges() {
            let map = vertical ? edges.vertical : edges.horizontal
            let reach: CGFloat = 24
            for v in values {
                let lo = Int(floor((v - snapThreshold) * scale)), hi = Int(ceil((v + snapThreshold) * scale))
                guard lo <= hi else { continue }
                for px in lo...hi {
                    for run in map[px] ?? [] {
                        let span = CGFloat(run.lowerBound) / scale...CGFloat(run.upperBound) / scale
                        if span.upperBound >= cross.lowerBound - reach && span.lowerBound <= cross.upperBound + reach {
                            targets.append(SnapTarget(position: CGFloat(px) / scale, span: span))
                        }
                    }
                }
            }
        }
        return targets
    }

    /// Smallest adjustment that puts one of `values` onto a target line, with the guide to show.
    private func bestSnap(vertical: Bool, values: [CGFloat], cross: ClosedRange<CGFloat>, excluding id: UUID?) -> (delta: CGFloat, guide: SnapGuide)? {
        var best: (delta: CGFloat, guide: SnapGuide)?
        for t in snapTargets(vertical: vertical, near: values, cross: cross, excluding: id) {
            for v in values {
                let d = t.position - v
                guard abs(d) <= snapThreshold, abs(d) < abs(best?.delta ?? .infinity) else { continue }
                best = (d, SnapGuide(vertical: vertical, position: t.position,
                                     from: min(cross.lowerBound, t.span.lowerBound), to: max(cross.upperBound, t.span.upperBound)))
            }
        }
        return best
    }

    /// Offset that aligns a moving object's edges or center with nearby lines; records guides.
    private func snapRect(_ r: CGRect, excluding id: UUID?) -> CGVector {
        var d = CGVector.zero
        if let s = bestSnap(vertical: true, values: [r.minX, r.midX, r.maxX], cross: r.minY...r.maxY, excluding: id) {
            d.dx = s.delta; snapGuides.append(s.guide)
        }
        if let s = bestSnap(vertical: false, values: [r.minY, r.midY, r.maxY], cross: r.minX...r.maxX, excluding: id) {
            d.dy = s.delta; snapGuides.append(s.guide)
        }
        return d
    }

    /// Snaps a dragged point (shape corner, line end, crop corner) to nearby lines; records guides.
    private func snapPoint(_ p: CGPoint, excluding id: UUID?) -> CGPoint {
        var q = p
        if let s = bestSnap(vertical: true, values: [p.x], cross: p.y...p.y, excluding: id) { q.x += s.delta; snapGuides.append(s.guide) }
        if let s = bestSnap(vertical: false, values: [p.y], cross: p.x...p.x, excluding: id) { q.y += s.delta; snapGuides.append(s.guide) }
        return q
    }

    // MARK: Ruler auto-measure

    /// Horizontal and vertical rulers spanning the run of same-colored pixels through `p`
    /// (edge detection on the screenshot itself, ignoring markup). Spans under 2 px are skipped.
    private func measuredRulers(at p: CGPoint) -> [Annotation] {
        guard let sampler else { return [] }
        let px = Int(floor(p.x * scale)), py = Int(floor(p.y * scale))
        var out: [Annotation] = []
        if let h = sampler.span(x: px, y: py, horizontal: true), h.count >= 2 {
            let y = (CGFloat(py) + 0.5) / scale
            var a = Annotation(kind: .ruler, start: CGPoint(x: CGFloat(h.lowerBound) / scale, y: y),
                               end: CGPoint(x: CGFloat(h.upperBound) / scale, y: y), color: color, size: size)
            a.labelAnchor = CGPoint(x: (CGFloat(px) + 0.5) / scale, y: y)
            out.append(a)
        }
        if let v = sampler.span(x: px, y: py, horizontal: false), v.count >= 2 {
            let x = (CGFloat(px) + 0.5) / scale
            var a = Annotation(kind: .ruler, start: CGPoint(x: x, y: CGFloat(v.lowerBound) / scale),
                               end: CGPoint(x: x, y: CGFloat(v.upperBound) / scale), color: color, size: size)
            a.labelAnchor = CGPoint(x: x, y: (CGFloat(py) + 0.5) / scale)
            out.append(a)
        }
        return out
    }

    // MARK: Canvas extension

    static let maxExtension: CGFloat = 1500
    private static let extensionMargin: CGFloat = 16

    /// Grows the canvas so the object (plus a margin) fits, when it sticks out past the image edge.
    /// Not a separate undo step: callers have already recorded the pre-change state.
    private func extendToFit(_ id: UUID) {
        guard let a = state.annotations.first(where: { $0.id == id }), let needed = overflowRect(for: a) else { return }
        extendCanvas(toInclude: needed)
    }

    /// The rect (object + margin) the canvas must cover, or nil when the object already fits inside the image.
    private func overflowRect(for a: Annotation) -> CGRect? {
        var r = a.bounds
        if a.kind == .arrow || a.kind == .line || a.kind == .ruler { r = r.insetBy(dx: -a.lineWidth * 2, dy: -a.lineWidth * 2) }
        guard !bounds.insetBy(dx: -0.5, dy: -0.5).contains(r) else { return nil }
        return r.insetBy(dx: -Self.extensionMargin, dy: -Self.extensionMargin)
    }

    /// Draws the off-canvas part of the dragged object into an overlay context whose user space is canvas points.
    func drawOverflowPreview() {
        guard let preview = overflowPreview else { return }
        let ext = preview.extendedBounds
        // Area the canvas will grow into (outside the current image).
        let grow = NSBezierPath(rect: ext)
        grow.append(NSBezierPath(rect: bounds))
        grow.windingRule = .evenOdd
        preview.fill.withAlphaComponent(0.85).setFill()
        grow.fill()
        // Object, clipped to outside the image (the canvas draws the inside part itself).
        NSGraphicsContext.saveGraphicsState()
        grow.addClip()
        renderer.drawPreview(preview.annotation, base: state.base, scale: scale, imageSize: ext.size)
        NSGraphicsContext.restoreGraphicsState()
        // Dashed outline of the new canvas size.
        let m = magnification
        let outline = NSBezierPath(rect: ext.insetBy(dx: 0.5 / m, dy: 0.5 / m))
        outline.lineWidth = 1 / m
        outline.setLineDash([5 / m, 4 / m], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()
    }

    /// Enlarges the base image to cover `rect` (canvas points, may extend left/up), filling new area with
    /// the screenshot's dominant edge color, and shifts all objects so nothing moves visually.
    private func extendCanvas(toInclude rect: CGRect) {
        let s = scale
        let old = state.base
        // Work in whole pixels so the original stays pixel-aligned.
        let left = max(0, Int(ceil(-rect.minX * s)))
        let top = max(0, Int(ceil(-rect.minY * s)))
        let right = max(0, Int(ceil(rect.maxX * s)) - old.width)
        let bottom = max(0, Int(ceil(rect.maxY * s)) - old.height)
        guard left + top + right + bottom > 0 else { return }
        let w = old.width + left + right, h = old.height + top + bottom
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(edgeFillColor().cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // CG origin is bottom-left: the old image sits `bottom` px above the new bottom edge.
        ctx.draw(old, in: CGRect(x: left, y: bottom, width: old.width, height: old.height))
        guard let grown = ctx.makeImage() else { return }
        let shift = CGVector(dx: CGFloat(left) / s, dy: CGFloat(top) / s)
        state.base = grown
        for i in state.annotations.indices { state.annotations[i].offset(by: shift) }
        baseChanged()
    }

    /// Most common color on the screenshot's outer 1-px ring (quantized), so extensions blend in.
    private func edgeFillColor() -> NSColor {
        if let cachedEdgeColor { return cachedEdgeColor }
        let c = computeEdgeFillColor()
        cachedEdgeColor = c
        return c
    }

    private func computeEdgeFillColor() -> NSColor {
        guard let sampler, sampler.width > 0, sampler.height > 0 else { return .white }
        var counts: [UInt32: (n: Int, color: NSColor)] = [:]
        func add(_ x: Int, _ y: Int) {
            guard let c = sampler.color(x: x, y: y)?.usingColorSpace(.sRGB) else { return }
            let key = (UInt32(c.redComponent * 31) << 10) | (UInt32(c.greenComponent * 31) << 5) | UInt32(c.blueComponent * 31)
            counts[key, default: (0, c)].n += 1
        }
        let stepX = max(1, sampler.width / 400), stepY = max(1, sampler.height / 400)
        for x in stride(from: 0, to: sampler.width, by: stepX) { add(x, 0); add(x, sampler.height - 1) }
        for y in stride(from: 0, to: sampler.height, by: stepY) { add(0, y); add(sampler.width - 1, y) }
        guard let best = counts.values.max(by: { $0.n < $1.n }) else { return .white }
        return best.color.withAlphaComponent(1)
    }

    override func mouseMoved(with event: NSEvent) {
        let p = point(event)
        if tool == .ruler {
            autoMeasure = bounds.contains(p) ? measuredRulers(at: p) : []
            needsDisplay = true
        }
        guard bounds.contains(p) else { delegate?.canvas(self, hoverPixel: nil, color: nil); return }
        let px = CGPoint(x: floor(p.x * scale), y: floor(p.y * scale))
        delegate?.canvas(self, hoverPixel: px, color: sampler?.color(x: Int(px.x), y: Int(px.y)))
    }

    override func mouseExited(with event: NSEvent) {
        if !autoMeasure.isEmpty { autoMeasure = []; needsDisplay = true }
        delegate?.canvas(self, hoverPixel: nil, color: nil)
    }

    private func update(_ id: UUID, _ body: (inout Annotation) -> Void) {
        guard let i = state.annotations.firstIndex(where: { $0.id == id }) else { return }
        body(&state.annotations[i])
    }

    private func constrained(_ anchor: CGPoint, _ p: CGPoint, kind: Annotation.Kind, shift: Bool) -> CGPoint {
        guard shift else { return p }
        let dx = p.x - anchor.x, dy = p.y - anchor.y
        switch kind {
        case .arrow, .line, .ruler:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: anchor.x + cos(angle) * len, y: anchor.y + sin(angle) * len)
        default:
            let side = max(abs(dx), abs(dy))
            return CGPoint(x: anchor.x + (dx < 0 ? -side : side), y: anchor.y + (dy < 0 ? -side : side))
        }
    }

    private func aspectLocked(_ anchor: CGPoint, _ p: CGPoint, aspect: CGFloat) -> CGPoint {
        let dx = p.x - anchor.x, dy = p.y - anchor.y
        let w = max(abs(dx), abs(dy) * aspect, 8)
        return CGPoint(x: anchor.x + (dx < 0 ? -w : w), y: anchor.y + (dy < 0 ? -1 : 1) * w / aspect)
    }

    private var magnification: CGFloat { enclosingScrollView?.magnification ?? 1 }

    // MARK: Add Capture / image objects

    /// Inserts a picture as a movable, resizable object centered in the visible area (scaled down to fit if needed).
    /// Inserts a picture as a movable object placed next to the screenshot (below a wide image, to the right of a tall one);
    /// the canvas grows to make room, filled with the screenshot's edge color.
    func insertImage(_ shot: Screenshot) {
        commitTextEditing()
        let size = CGSize(width: shot.pointSize.width.rounded(), height: shot.pointSize.height.rounded())
        let gap = Self.extensionMargin
        let origin = bounds.width >= bounds.height
            ? CGPoint(x: 0, y: bounds.maxY + gap)
            : CGPoint(x: bounds.maxX + gap, y: 0)
        var a = Annotation(kind: .image, start: origin, end: CGPoint(x: origin.x + size.width, y: origin.y + size.height),
                           color: color, size: size.width, filled: false)
        a.size = self.size
        a.image = shot.image
        mutate { $0.annotations.append(a) }
        // Margin only on the far sides; the picture stays flush with the screenshot's left/top edge.
        extendCanvas(toInclude: bounds.union(CGRect(origin: a.rect.origin,
                                                    size: CGSize(width: a.rect.width + gap, height: a.rect.height + gap))))
        tool = .select
        delegate?.canvas(self, didChangeTool: .select)
        selectedID = a.id
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    /// ⌘V pastes an image from the clipboard as an object.
    @objc func paste(_ sender: Any?) {
        guard let image = NSImage(pasteboard: .general),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { NSSound.beep(); return }
        let scale = image.size.width > 0 ? CGFloat(cg.width) / image.size.width : 1
        insertImage(Screenshot(image: cg, scale: max(1, scale)))
    }

    // Menu Edit ▸ Undo/Redo arrive here first because the canvas is the first responder.
    @objc func undo(_ sender: Any?) { undo() }
    @objc func redo(_ sender: Any?) { redo() }
    /// ⌘C on the canvas copies the whole annotated image.
    @objc func copy(_ sender: Any?) { (window?.windowController as? EditorWindowController)?.menuCopy(sender) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)): return canUndo
        case #selector(redo(_:)): return canRedo
        case #selector(paste(_:)): return NSImage.canInit(with: .general)
        default: return true
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { super.keyDown(with: event); return }
        switch Int(event.keyCode) {
        case 48: delegate?.canvasRequestsCopyColor(self); return      // tab: copy the color under the cursor
        case 51, 117: deleteSelected(); return                       // delete / forward delete
        case 36, 76: if cropRect != nil { applyCrop() }; return      // return / enter
        case 53:                                                     // esc
            if cropRect != nil { cancelCrop() }
            else if selectedID != nil { selectedID = nil; needsDisplay = true }
            else { delegate?.canvasRequestsClose(self) }
            return
        case 123, 124, 125, 126:
            guard let id = selectedID else { break }
            let step: CGFloat = flags.contains(.shift) ? 10 : 1
            let d: CGVector = switch Int(event.keyCode) {
            case 123: CGVector(dx: -step, dy: 0)
            case 124: CGVector(dx: step, dy: 0)
            case 125: CGVector(dx: 0, dy: step)
            default: CGVector(dx: 0, dy: -step)
            }
            mutate { s in
                if let i = s.annotations.firstIndex(where: { $0.id == id }) { s.annotations[i].offset(by: d) }
            }
            return
        default: break
        }
        if let ch = event.charactersIgnoringModifiers?.lowercased().first,
           let t = Tool.allCases.first(where: { $0.shortcut == ch }) {
            tool = t
            delegate?.canvas(self, didChangeTool: t)
            return
        }
        super.keyDown(with: event)
    }

    // MARK: Text editing

    private func beginTextEditing(_ id: UUID) {
        guard let a = state.annotations.first(where: { $0.id == id }) else { return }
        editingTextID = id
        let field = NSTextField(string: a.text)
        field.font = a.textAttributes[.font] as? NSFont
        field.textColor = a.color
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor.white.withAlphaComponent(0.25)
        field.focusRingType = .none
        field.delegate = self
        // Multi-line: ⇧↩ inserts a line break (see doCommandBy); ↩ alone finishes editing.
        field.usesSingleLineMode = false
        field.cell?.isScrollable = false
        field.cell?.wraps = false
        field.lineBreakMode = .byClipping
        field.frame = CGRect(origin: a.start, size: textFieldSize(for: a.text, font: field.font))
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
        needsDisplay = true
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = textField else { return }
        field.setFrameSize(textFieldSize(for: field.stringValue, font: field.font))
    }

    /// ⇧↩ (and ⌥↩) add a new line; plain ↩ commits the text.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) || flags.contains(.option) {
            textView.insertNewlineIgnoringFieldEditor(nil)
            return true
        }
        return false
    }

    /// Editor field size for (possibly multi-line) text, with room to keep typing.
    private func textFieldSize(for text: String, font: NSFont?) -> CGSize {
        let font = font ?? .systemFont(ofSize: 14)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let lineHeight = ("Ag" as NSString).size(withAttributes: attrs).height
        let sample = text.isEmpty ? " " : text
        var size = (sample as NSString).size(withAttributes: attrs)
        if text.hasSuffix("\n") { size.height += lineHeight } // trailing empty line isn't measured
        return CGSize(width: max(160, size.width + 40), height: max(lineHeight, size.height) + 6)
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitTextEditing() }

    private func commitTextEditing() {
        guard let field = textField, let id = editingTextID else { return }
        let text = field.stringValue
        textField = nil
        editingTextID = nil
        field.removeFromSuperview()
        if text.trimmingCharacters(in: .whitespaces).isEmpty {
            state.annotations.removeAll { $0.id == id }
            if selectedID == id { selectedID = nil }
        } else if state.annotations.first(where: { $0.id == id })?.text != text {
            mutate { s in
                if let i = s.annotations.firstIndex(where: { $0.id == id }) { s.annotations[i].text = text }
            }
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        renderer.draw(base: state.base, scale: scale, annotations: state.annotations, skipping: editingTextID)
        if tool == .ruler, drag == nil, !autoMeasure.isEmpty {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setAlpha(0.85)
            for a in autoMeasure { renderer.draw(a, base: state.base, scale: scale, imageSize: imagePointSize) }
            NSGraphicsContext.restoreGraphicsState()
        }
        let m = magnification

        if !snapGuides.isEmpty {
            let m = magnification
            let path = NSBezierPath()
            for g in snapGuides {
                if g.vertical {
                    path.move(to: CGPoint(x: g.position, y: g.from)); path.line(to: CGPoint(x: g.position, y: g.to))
                } else {
                    path.move(to: CGPoint(x: g.from, y: g.position)); path.line(to: CGPoint(x: g.to, y: g.position))
                }
            }
            path.lineWidth = 1 / m
            NSColor.systemPink.setStroke()
            path.stroke()
        }

        if let sel = selected, editingTextID == nil {
            let outline = NSBezierPath(rect: sel.bounds.insetBy(dx: -4 / m, dy: -4 / m))
            outline.lineWidth = 1 / m
            outline.setLineDash([4 / m, 3 / m], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            outline.stroke()
            if sel.hasEndHandle {
                for p in sel.isTwoPoint ? [sel.start, sel.end] : [sel.end] {
                    let r = 4.5 / m
                    let h = NSBezierPath(ovalIn: CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2))
                    NSColor.white.setFill(); h.fill()
                    h.lineWidth = 1.5 / m
                    NSColor.controlAccentColor.setStroke(); h.stroke()
                }
            }
        }

        if let c = cropRect {
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: c))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill()
            dim.fill()
            let border = NSBezierPath(rect: c)
            border.lineWidth = 1.5 / m
            NSColor.white.setStroke()
            border.stroke()
            let label = "\(Int(c.width * scale)) × \(Int(c.height * scale))  ·  ↩ to crop, esc to cancel"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11 / m, weight: .medium), .foregroundColor: NSColor.white]
            let sz = (label as NSString).size(withAttributes: attrs)
            let bg = CGRect(x: c.minX, y: c.maxY + 4 / m, width: sz.width + 12 / m, height: sz.height + 6 / m)
            NSColor.black.withAlphaComponent(0.75).setFill()
            NSBezierPath(roundedRect: bg, xRadius: 4 / m, yRadius: 4 / m).fill()
            (label as NSString).draw(at: CGPoint(x: bg.minX + 6 / m, y: bg.minY + 3 / m), withAttributes: attrs)
        }
    }
}
