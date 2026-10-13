import AppKit
import CoreImage

/// Editor tools and their single-letter shortcuts (see the Draw menu).
enum Tool: String, CaseIterable {
    case select, arrow, text, ruler, rectangle, oval, line, freehand, highlighter, blur, spotlight, counter, magnifier, crop

    var shortcut: Character? {
        switch self {
        case .select: "v"
        case .arrow: "a"
        case .text: "t"
        case .ruler: "u"
        case .rectangle: "r"
        case .oval: "o"
        case .line: "l"
        case .freehand: "d"
        case .highlighter: "h"
        case .blur: "b"
        case .spotlight: "s"
        case .counter: "c"
        case .magnifier: "m"
        case .crop: "k"
        }
    }

    var title: String {
        switch self {
        case .select: "Select"
        case .arrow: "Arrow"
        case .text: "Text"
        case .ruler: "Ruler"
        case .rectangle: "Rectangle"
        case .oval: "Oval"
        case .line: "Line"
        case .freehand: "Freehand Drawing"
        case .highlighter: "Highlighter"
        case .blur: "Blur"
        case .spotlight: "Spotlight"
        case .counter: "Counter"
        case .magnifier: "Magnifier"
        case .crop: "Crop"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        case .ruler: "ruler"
        case .rectangle: "rectangle"
        case .oval: "circle"
        case .line: "line.diagonal"
        case .freehand: "scribble"
        case .highlighter: "highlighter"
        case .blur: "checkerboard.rectangle"
        case .spotlight: "flashlight.on.fill"
        case .counter: "1.circle"
        case .magnifier: "plus.magnifyingglass"
        case .crop: "crop"
        }
    }

    var annotationKind: Annotation.Kind? {
        switch self {
        case .arrow: .arrow
        case .text: .text
        case .ruler: .ruler
        case .rectangle: .rectangle
        case .oval: .oval
        case .line: .line
        case .freehand: .freehand
        case .highlighter: .highlighter
        case .blur: .blur
        case .spotlight: .spotlight
        case .counter: .counter
        case .magnifier: .magnifier
        case .select, .crop: nil
        }
    }
}

/// Text rendering styles: plain, outlined, boxed, callout.
enum TextStyle: Int, CaseIterable {
    case plain, outline, background, callout

    var title: String {
        switch self {
        case .plain: "Plain"
        case .outline: "Outline"
        case .background: "Background"
        case .callout: "Callout"
        }
    }

    var symbol: String {
        switch self {
        case .plain: "character"
        case .outline: "character.textbox"
        case .background: "rectangle.fill"
        case .callout: "bubble.left.fill"
        }
    }
}

/// One editor object. Coordinates are image points with a top-left origin.
struct Annotation: Identifiable {
    enum Kind { case arrow, line, ruler, rectangle, oval, freehand, highlighter, blur, spotlight, counter, magnifier, text, image }

    let id = UUID()
    var kind: Kind
    var start: CGPoint
    var end: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var size: CGFloat           // 1...10 abstract size from the toolbar slider
    var filled = false
    /// Fill opacity for filled rectangles/ovals (0.05…1). Below 1 the shape keeps a solid border.
    var fillOpacity: CGFloat = 1
    var text = ""
    var textStyle: TextStyle = .background
    var number = 0
    /// Embedded picture for `.image` objects ("Add Capture"); drawn into `rect`.
    var image: CGImage?
    /// Auto-measured rulers: where the horizontal and vertical measurements cross; labels sit beside it.
    var labelAnchor: CGPoint?

    var rect: CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    var lineWidth: CGFloat { 1 + size * 1.2 }
    var fontSize: CGFloat { 10 + size * 4 }
    var counterRadius: CGFloat { 9 + size * 2.4 }

    var isTwoPoint: Bool { !isStroke && kind != .counter && kind != .text }
    /// Drawn from a list of points (pen and highlighter).
    var isStroke: Bool { kind == .freehand || kind == .highlighter }
    /// Highlighter nib width: a broad chisel tip, like a Stabilo marker.
    var markerWidth: CGFloat { 8 + size * 4 }
    var strokeWidth: CGFloat { kind == .highlighter ? markerWidth : lineWidth }
    var isCallout: Bool { kind == .text && textStyle == .callout }
    /// Objects whose `end` point can be dragged with a handle (a callout's `end` is its pointer tip).
    var hasEndHandle: Bool { isTwoPoint || isCallout }

    mutating func offset(by d: CGVector) {
        start.x += d.dx; start.y += d.dy
        end.x += d.dx; end.y += d.dy
        points = points.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
        labelAnchor = labelAnchor.map { CGPoint(x: $0.x + d.dx, y: $0.y + d.dy) }
    }

    /// Contrasting color for outlines and text on a colored box.
    var contrastColor: NSColor { color.luminance > 0.6 ? .black : .white }

    var textFont: NSFont { .systemFont(ofSize: fontSize, weight: .bold) }

    var textAttributes: [NSAttributedString.Key: Any] {
        let fg = (textStyle == .background || textStyle == .callout) ? contrastColor : color
        return [.font: textFont, .foregroundColor: fg]
    }

    var textPadding: CGFloat { textStyle == .background || textStyle == .callout ? fontSize * 0.35 : 0 }

    /// Rect occupied by the glyphs; `start` is the text origin.
    var textBounds: CGRect {
        let s = ((text.isEmpty ? " " : text) as NSString).size(withAttributes: textAttributes)
        return CGRect(origin: start, size: CGSize(width: max(s.width, 8), height: s.height))
    }

    /// Text rect plus padding for the background/callout box.
    var textBoxRect: CGRect { textBounds.insetBy(dx: -textPadding * 1.4, dy: -textPadding) }

    /// Callout pointer triangle: base on the box center, tip at `end`.
    var calloutTail: NSBezierPath? {
        guard isCallout else { return nil }
        let box = textBoxRect
        let c = CGPoint(x: box.midX, y: box.midY)
        let dx = end.x - c.x, dy = end.y - c.y
        let len = hypot(dx, dy)
        guard len > 1, !box.contains(end) else { return nil }
        let half = min(box.height * 0.42, box.width * 0.3)
        let nx = -dy / len * half, ny = dx / len * half
        let p = NSBezierPath()
        p.move(to: CGPoint(x: c.x + nx, y: c.y + ny))
        p.line(to: end)
        p.line(to: CGPoint(x: c.x - nx, y: c.y - ny))
        p.close()
        return p
    }

    /// Bounds used for selection outlines.
    var bounds: CGRect {
        switch kind {
        case .text:
            switch textStyle {
            case .plain, .outline: return textBounds
            case .background: return textBoxRect
            case .callout: return textBoxRect.union(CGRect(origin: end, size: .zero))
            }
        case .counter:
            let r = counterRadius
            return CGRect(x: start.x - r, y: start.y - r, width: r * 2, height: r * 2)
        case .freehand, .highlighter:
            guard let f = points.first else { return .zero }
            var r = CGRect(origin: f, size: .zero)
            points.forEach { r = r.union(CGRect(origin: $0, size: .zero)) }
            return r.insetBy(dx: -strokeWidth / 2, dy: -strokeWidth / 2)
        default: return rect
        }
    }

    func hitTest(_ p: CGPoint) -> Bool {
        let tol = max(6, lineWidth)
        switch kind {
        case .arrow, .line, .ruler:
            return distance(p, toSegment: start, end) <= tol
        case .freehand, .highlighter:
            let t = max(tol, strokeWidth / 2)
            if points.count == 1, let only = points.first { return hypot(p.x - only.x, p.y - only.y) <= t }
            return zip(points, points.dropFirst()).contains { distance(p, toSegment: $0, $1) <= t }
        case .rectangle, .oval:
            if filled { return rect.insetBy(dx: -tol, dy: -tol).contains(p) }
            return rect.insetBy(dx: -tol, dy: -tol).contains(p) && !rect.insetBy(dx: tol, dy: tol).contains(p)
        case .counter:
            return hypot(p.x - start.x, p.y - start.y) <= counterRadius + 2
        case .text:
            if textBoxRect.insetBy(dx: -4, dy: -4).contains(p) { return true }
            return calloutTail?.contains(p) ?? false
        default:
            return bounds.insetBy(dx: -4, dy: -4).contains(p)
        }
    }
}

func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

extension NSColor {
    var brightnessComponentSafe: CGFloat { (usingColorSpace(.sRGB) ?? self).brightnessComponent }
    /// Perceived (Rec. 709) luminance, 0...1.
    var luminance: CGFloat {
        let c = usingColorSpace(.sRGB) ?? self
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }
}

/// Draws a document (base image + annotations) into the current NSGraphicsContext,
/// which must be flipped (top-left origin) and measured in image points.
final class Renderer {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private var pixelCache: [String: CGImage] = [:]

    func invalidateCache() { pixelCache.removeAll() }

    func draw(base: CGImage, scale: CGFloat, annotations: [Annotation], skipping skipID: UUID? = nil) {
        let size = CGSize(width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale)
        let full = CGRect(origin: .zero, size: size)
        NSImage(cgImage: base, size: size).draw(in: full, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        let visible = annotations.filter { $0.id != skipID }
        // Layering: pixelation sits on the image, spotlight dims everything below other markup.
        // Inserted pictures behave like part of the screenshot: other markup draws on top of them.
        for a in visible where a.kind == .image { drawImage(a) }
        for a in visible where a.kind == .blur { drawBlur(a, base: base, scale: scale) }
        let spots = visible.filter { $0.kind == .spotlight && $0.rect.width > 1 && $0.rect.height > 1 }
        if !spots.isEmpty {
            let path = NSBezierPath(rect: full)
            for s in spots {
                path.append(s.filled ? NSBezierPath(ovalIn: s.rect) : NSBezierPath(roundedRect: s.rect, xRadius: 4, yRadius: 4))
            }
            path.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill()
            path.fill()
        }
        for a in visible where a.kind != .blur && a.kind != .spotlight && a.kind != .image {
            draw(a, base: base, scale: scale, imageSize: size)
        }
    }

    func draw(_ a: Annotation, base: CGImage, scale: CGFloat, imageSize: CGSize) {
        a.color.setStroke()
        a.color.setFill()
        switch a.kind {
        case .arrow:
            arrowPath(from: a.start, to: a.end, width: a.lineWidth).fill()
        case .line:
            let p = NSBezierPath()
            p.move(to: a.start); p.line(to: a.end)
            p.lineWidth = a.lineWidth
            p.lineCapStyle = .round
            p.stroke()
        case .rectangle, .oval:
            let path = a.kind == .oval ? NSBezierPath(ovalIn: a.rect)
                                       : NSBezierPath(roundedRect: a.rect, xRadius: a.lineWidth, yRadius: a.lineWidth)
            if a.filled {
                a.color.withAlphaComponent(a.fillOpacity).setFill()
                path.fill()
                if a.fillOpacity < 1 { // translucent fill: keep a crisp outline
                    a.color.setStroke()
                    path.lineWidth = a.lineWidth
                    path.stroke()
                }
            } else {
                path.lineWidth = a.lineWidth
                path.stroke()
            }
        case .freehand:
            guard let first = a.points.first else { return }
            let p = NSBezierPath()
            p.move(to: first)
            a.points.dropFirst().forEach { p.line(to: $0) }
            p.lineWidth = a.lineWidth
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
        case .highlighter:
            // Stabilo-style marker: one smoothed stroke with a flat chisel tip, multiplied onto the content so
            // dark text stays readable. Drawn as a single path, so overlaps inside one stroke don't darken.
            guard a.points.count > 1 else { return }
            let path = Self.smoothPath(a.points)
            path.lineWidth = a.markerWidth
            path.lineCapStyle = .butt
            path.lineJoinStyle = .round
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .multiply
            NSGraphicsContext.current?.cgContext.setAlpha(0.9)
            a.color.setStroke()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        case .counter:
            let r = a.counterRadius
            let circle = NSBezierPath(ovalIn: CGRect(x: a.start.x - r, y: a.start.y - r, width: r * 2, height: r * 2))
            circle.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
            circle.lineWidth = max(1.5, r / 8)
            circle.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: r * 1.1, weight: .bold),
                .foregroundColor: a.color.brightnessComponentSafe > 0.75 ? NSColor.black : NSColor.white,
            ]
            let s = "\(a.number)" as NSString
            let sz = s.size(withAttributes: attrs)
            s.draw(at: CGPoint(x: a.start.x - sz.width / 2, y: a.start.y - sz.height / 2), withAttributes: attrs)
        case .magnifier:
            let rect = a.rect
            guard rect.width > 2, rect.height > 2 else { return }
            let zoom: CGFloat = 2
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: rect).addClip()
            let c = CGPoint(x: rect.midX, y: rect.midY)
            let dest = CGRect(x: c.x - c.x * zoom, y: c.y - c.y * zoom, width: imageSize.width * zoom, height: imageSize.height * zoom)
            NSImage(cgImage: base, size: imageSize).draw(in: dest, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            let ring = NSBezierPath(ovalIn: rect)
            ring.lineWidth = max(2, a.lineWidth / 2)
            ring.stroke()
        case .text:
            drawText(a)
        case .ruler:
            drawRuler(a, scale: scale, imageSize: imageSize)
        case .blur, .spotlight, .image:
            break
        }
    }

    /// Quadratic curve through segment midpoints: removes mouse jitter without lagging behind the pointer.
    static func smoothPath(_ pts: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        guard let first = pts.first else { return path }
        path.move(to: first)
        guard pts.count > 2 else {
            pts.dropFirst().forEach { path.line(to: $0) }
            return path
        }
        for i in 1..<(pts.count - 1) {
            let mid = CGPoint(x: (pts[i].x + pts[i + 1].x) / 2, y: (pts[i].y + pts[i + 1].y) / 2)
            path.curve(to: mid, controlPoint1: pts[i], controlPoint2: pts[i])
        }
        path.line(to: pts[pts.count - 1])
        return path
    }

    /// Draws one object on its own (live previews). Pictures included; blur/spotlight need the image under them, so they're skipped.
    func drawPreview(_ a: Annotation, base: CGImage, scale: CGFloat, imageSize: CGSize) {
        switch a.kind {
        case .image: drawImage(a)
        case .blur, .spotlight: break
        default: draw(a, base: base, scale: scale, imageSize: imageSize)
        }
    }

    private func drawImage(_ a: Annotation) {
        guard let img = a.image, a.rect.width > 1, a.rect.height > 1 else { return }
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 8
        shadow.shadowOffset = CGSize(width: 0, height: -2)
        shadow.set()
        NSImage(cgImage: img, size: a.rect.size).draw(in: a.rect, from: .zero, operation: .sourceOver, fraction: 1,
                                                       respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
        NSColor.black.withAlphaComponent(0.25).setStroke()
        let border = NSBezierPath(rect: a.rect.insetBy(dx: 0.25, dy: 0.25))
        border.lineWidth = 0.5
        border.stroke()
    }

    /// Measurement line with end ticks and a pixel-length label.
    private func drawRuler(_ a: Annotation, scale: CGFloat, imageSize: CGSize) {
        let dx = a.end.x - a.start.x, dy = a.end.y - a.start.y
        let len = hypot(dx, dy)
        guard len > 0.5 else { return }
        let ux = dx / len, uy = dy / len
        let nx = -uy, ny = ux
        let w = max(1.5, a.lineWidth * 0.6)
        let tick = 5 + w * 2

        let path = NSBezierPath()
        path.move(to: a.start); path.line(to: a.end)
        for p in [a.start, a.end] {
            path.move(to: CGPoint(x: p.x + nx * tick, y: p.y + ny * tick))
            path.line(to: CGPoint(x: p.x - nx * tick, y: p.y - ny * tick))
        }
        path.lineWidth = w
        path.lineCapStyle = .round
        // Dark halo first so the ruler reads on any background.
        NSColor.black.withAlphaComponent(0.18).setStroke()
        let halo = path.copy() as! NSBezierPath
        halo.lineWidth = w + 1.5
        halo.stroke()
        a.color.setStroke()
        path.stroke()

        let px = Int((len * scale).rounded())
        let wpx = Int((abs(dx) * scale).rounded()), hpx = Int((abs(dy) * scale).rounded())
        let diagonal = wpx > 0 && hpx > 0
        let label = diagonal ? "\(px) px  (\(wpx) × \(hpx))" : "\(px) px"
        let fontSize = 9 + a.size * 1.2
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: a.contrastColor,
        ]
        let sz = (label as NSString).size(withAttributes: attrs)
        let pad = CGSize(width: fontSize * 0.5, height: fontSize * 0.2)
        // Sit the pill beside the midpoint, far enough along the normal that its box clears the line.
        let boxW = sz.width + pad.width * 2, boxH = sz.height + pad.height * 2
        let offset = tick * 0.6 + abs(nx) * boxW / 2 + abs(ny) * boxH / 2 + 3
        var c = CGPoint(x: (a.start.x + a.end.x) / 2 + nx * offset, y: (a.start.y + a.end.y) / 2 + ny * offset)
        if ny > 0 { c = CGPoint(x: (a.start.x + a.end.x) / 2 - nx * offset, y: (a.start.y + a.end.y) / 2 - ny * offset) }
        if let anchor = a.labelAnchor {
            // Auto-measure pair: width label above-right of the crossing, height label below-right
            // (mirrored to the left near the right edge), so the two never overlap each other or the lines.
            let gap: CGFloat = 6
            let toLeft = anchor.x + gap + boxW > imageSize.width
            let x = toLeft ? anchor.x - gap - boxW / 2 : anchor.x + gap + boxW / 2
            let horizontal = abs(dy) < 0.5
            c = CGPoint(x: x, y: horizontal ? anchor.y - gap - boxH / 2 : anchor.y + gap + boxH / 2)
        }
        let pill = CGRect(x: c.x - sz.width / 2 - pad.width, y: c.y - sz.height / 2 - pad.height,
                          width: sz.width + pad.width * 2, height: sz.height + pad.height * 2)
        a.color.setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        (label as NSString).draw(at: CGPoint(x: pill.minX + pad.width, y: pill.minY + pad.height), withAttributes: attrs)
    }

    private func drawText(_ a: Annotation) {
        let text = a.text as NSString
        switch a.textStyle {
        case .plain:
            text.draw(at: a.start, withAttributes: a.textAttributes)
        case .outline:
            // Stroke pass in the contrasting color (centered stroke, so half sits outside the glyphs), then the fill on top.
            var stroke = a.textAttributes
            stroke[.strokeColor] = a.contrastColor
            stroke[.strokeWidth] = 14
            text.draw(at: a.start, withAttributes: stroke)
            text.draw(at: a.start, withAttributes: a.textAttributes)
        case .background, .callout:
            let box = a.textBoxRect
            let radius = min(box.height / 2, a.fontSize * 0.35)
            a.color.setFill()
            a.calloutTail?.fill()
            NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius).fill()
            text.draw(at: a.start, withAttributes: a.textAttributes)
        }
    }

    private func drawBlur(_ a: Annotation, base: CGImage, scale: CGFloat) {
        let r = a.rect
        guard r.width >= 2, r.height >= 2 else { return }
        let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale).integral
            .intersection(CGRect(x: 0, y: 0, width: base.width, height: base.height))
        guard !px.isEmpty else { return }
        let key = "\(Int(px.minX)),\(Int(px.minY)),\(Int(px.width)),\(Int(px.height)),\(Int(a.size)),\(ObjectIdentifier(base).hashValue)"
        let image: CGImage
        if let cached = pixelCache[key] {
            image = cached
        } else {
            guard let crop = base.cropping(to: px) else { return }
            let ci = CIImage(cgImage: crop)
            let block = max(6, (4 + a.size * 2) * scale)
            let out = ci.clampedToExtent()
                .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: 0, y: 0)])
                .cropped(to: ci.extent)
            guard let cg = ciContext.createCGImage(out, from: ci.extent) else { return }
            if pixelCache.count > 64 { pixelCache.removeAll() }
            pixelCache[key] = cg
            image = cg
        }
        let dest = CGRect(x: px.minX / scale, y: px.minY / scale, width: px.width / scale, height: px.height / scale)
        NSImage(cgImage: image, size: dest.size).draw(in: dest, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Tapered arrow: thin tail widening toward a filled head.
    func arrowPath(from s: CGPoint, to e: CGPoint, width w: CGFloat) -> NSBezierPath {
        let dx = e.x - s.x, dy = e.y - s.y
        let len = hypot(dx, dy)
        let path = NSBezierPath()
        guard len > 1 else { return path }
        let ux = dx / len, uy = dy / len
        let nx = -uy, ny = ux
        let headLen = min(len * 0.6, max(14, w * 4.5))
        let headHalf = headLen * 0.5
        let bx = e.x - ux * headLen, by = e.y - uy * headLen
        let tail = w * 0.2, neck = w * 0.6
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
        path.move(to: pt(s.x + nx * tail, s.y + ny * tail))
        path.line(to: pt(bx + nx * neck, by + ny * neck))
        path.line(to: pt(bx + nx * headHalf, by + ny * headHalf))
        path.line(to: e)
        path.line(to: pt(bx - nx * headHalf, by - ny * headHalf))
        path.line(to: pt(bx - nx * neck, by - ny * neck))
        path.line(to: pt(s.x - nx * tail, s.y - ny * tail))
        path.close()
        path.lineJoinStyle = .round
        return path
    }

    /// Flattens the document into a bitmap at full pixel resolution.
    func flatten(base: CGImage, scale: CGFloat, annotations: [Annotation]) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: base.width, height: base.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(base.height))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        draw(base: base, scale: scale, annotations: annotations)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
