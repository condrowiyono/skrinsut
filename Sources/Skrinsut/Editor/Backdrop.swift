import AppKit
import CoreImage
import ScreenCaptureKit

/// Backdrop ("beautify") settings: a background around the screenshot with padding, rounded corners, and a shadow.
struct BackdropSettings: Codable, Equatable {
    enum Fill: String, Codable, CaseIterable, Identifiable {
        case gradient, solid, wallpaper
        var id: String { rawValue }
        var title: String {
            switch self {
            case .gradient: "Gradient"
            case .solid: "Solid"
            case .wallpaper: "Wallpaper"
            }
        }
    }

    enum Aspect: String, Codable, CaseIterable, Identifiable {
        case auto, square, r4x3, r3x2, r16x9, r16x10, r9x16
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: "Auto"
            case .square: "1:1"
            case .r4x3: "4:3"
            case .r3x2: "3:2"
            case .r16x9: "16:9"
            case .r16x10: "16:10"
            case .r9x16: "9:16"
            }
        }
        var ratio: CGFloat? {
            switch self {
            case .auto: nil
            case .square: 1
            case .r4x3: 4 / 3
            case .r3x2: 3 / 2
            case .r16x9: 16 / 9
            case .r16x10: 16 / 10
            case .r9x16: 9 / 16
            }
        }
    }

    var enabled = false
    var fill: Fill = .gradient
    var gradientIndex = 0
    var solidHex = "#E9EBEE"
    /// Padding as a fraction of the image's average side (0...0.4).
    var padding: CGFloat = 0.1
    var innerRadius: CGFloat = 10
    var outerRadius: CGFloat = 0
    /// Shadow strength 0...1.
    var shadow: CGFloat = 0.5
    /// Wallpaper blur radius in points.
    var blur: CGFloat = 0
    var aspect: Aspect = .auto

    private static let storageKey = "backdrop-settings"

    /// Last-used style; each editor starts with the backdrop disabled.
    static func load() -> BackdropSettings {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              var s = try? JSONDecoder().decode(BackdropSettings.self, from: data) else { return BackdropSettings() }
        s.enabled = false
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }

    var solidColor: NSColor { NSColor(hex: solidHex) ?? .white }
}

struct GradientPreset {
    let colors: [NSColor]
    let angle: CGFloat

    init(_ hexes: [String], angle: CGFloat = 135) {
        colors = hexes.compactMap(NSColor.init(hex:))
        self.angle = angle
    }

    var gradient: NSGradient { NSGradient(colors: colors)! }

    static let all: [GradientPreset] = [
        GradientPreset(["#FF9A8B", "#FF6A88", "#FF99AC"]),
        GradientPreset(["#8EC5FC", "#E0C3FC"]),
        GradientPreset(["#4158D0", "#C850C0", "#FFCC70"]),
        GradientPreset(["#0093E9", "#80D0C7"]),
        GradientPreset(["#FBAB7E", "#F7CE68"]),
        GradientPreset(["#85FFBD", "#FFFB7D"]),
        GradientPreset(["#21D4FD", "#B721FF"]),
        GradientPreset(["#FA8BFF", "#2BD2FF", "#2BFF88"]),
        GradientPreset(["#08AEEA", "#2AF598"], angle: 90),
        GradientPreset(["#FEE140", "#FA709A"]),
        GradientPreset(["#667EEA", "#764BA2"]),
        GradientPreset(["#F093FB", "#F5576C"]),
        GradientPreset(["#43E97B", "#38F9D7"], angle: 90),
        GradientPreset(["#30CFD0", "#330867"]),
        GradientPreset(["#D4FC79", "#96E6A1"]),
        GradientPreset(["#232526", "#414345"], angle: 90),
    ]
}

/// Where the screenshot sits inside the backdrop canvas (points, top-left origin).
struct BackdropLayout {
    let canvasSize: CGSize
    let imageRect: CGRect

    init(imageSize s: CGSize, settings: BackdropSettings) {
        guard settings.enabled else {
            canvasSize = s
            imageRect = CGRect(origin: .zero, size: s)
            return
        }
        let pad = (settings.padding * (s.width + s.height) / 2).rounded()
        var w = s.width + pad * 2
        var h = s.height + pad * 2
        if let r = settings.aspect.ratio {
            if w / h < r { w = (h * r).rounded() } else { h = (w / r).rounded() }
        }
        canvasSize = CGSize(width: w, height: h)
        imageRect = CGRect(x: ((w - s.width) / 2).rounded(), y: ((h - s.height) / 2).rounded(), width: s.width, height: s.height)
    }
}

enum BackdropRenderer {
    private static let ciContext = CIContext()
    private static var blurCache: (source: ObjectIdentifier, radius: CGFloat, image: CGImage)?

    /// Draws background, outer clip, and the image's drop shadow into `ctx`
    /// (a top-left-origin context in canvas points). Returns with the outer clip still applied.
    static func drawBackground(in ctx: CGContext, layout: BackdropLayout, settings: BackdropSettings,
                               shadowSource: CGImage, wallpaper: CGImage?) {
        let canvas = CGRect(origin: .zero, size: layout.canvasSize)
        if settings.outerRadius > 0 {
            ctx.addPath(CGPath(roundedRect: canvas, cornerWidth: settings.outerRadius, cornerHeight: settings.outerRadius, transform: nil))
            ctx.clip()
        }

        switch settings.fill {
        case .solid:
            ctx.setFillColor(settings.solidColor.cgColor)
            ctx.fill(canvas)
        case .gradient:
            let preset = GradientPreset.all[settings.gradientIndex % GradientPreset.all.count]
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            preset.gradient.draw(in: canvas, angle: preset.angle)
            NSGraphicsContext.restoreGraphicsState()
        case .wallpaper:
            if let wp = wallpaper.map({ blurred($0, radius: settings.blur) }) {
                drawAspectFill(wp, in: canvas, ctx: ctx)
            } else {
                ctx.setFillColor(NSColor.darkGray.cgColor)
                ctx.fill(canvas)
            }
        }

        // Shadow follows the image's alpha (works for transparent window captures too).
        guard settings.shadow > 0 else { return }
        let device = abs(ctx.convertToDeviceSpace(CGSize(width: 1, height: 1)).width)
        let s = settings.shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -(2 + 10 * s) * device),
                      blur: (6 + 34 * s) * device,
                      color: NSColor.black.withAlphaComponent(0.2 + 0.35 * s).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        clipImage(ctx, layout: layout, settings: settings)
        drawFlipped(shadowSource, in: layout.imageRect, ctx: ctx)
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    static func clipImage(_ ctx: CGContext, layout: BackdropLayout, settings: BackdropSettings) {
        let r = min(settings.innerRadius, layout.imageRect.width / 2, layout.imageRect.height / 2)
        guard r > 0 else { return }
        ctx.addPath(CGPath(roundedRect: layout.imageRect, cornerWidth: r, cornerHeight: r, transform: nil))
        ctx.clip()
    }

    /// Composites a flattened screenshot onto its backdrop at full pixel resolution.
    static func render(_ shot: Screenshot, settings: BackdropSettings, wallpaper: CGImage?) -> Screenshot? {
        guard settings.enabled else { return shot }
        let layout = BackdropLayout(imageSize: shot.pointSize, settings: settings)
        let pw = Int((layout.canvasSize.width * shot.scale).rounded())
        let ph = Int((layout.canvasSize.height * shot.scale).rounded())
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: shot.scale, y: -shot.scale)
        drawBackground(in: ctx, layout: layout, settings: settings, shadowSource: shot.image, wallpaper: wallpaper)
        ctx.saveGState()
        clipImage(ctx, layout: layout, settings: settings)
        drawFlipped(shot.image, in: layout.imageRect, ctx: ctx)
        ctx.restoreGState()
        return ctx.makeImage().map { Screenshot(image: $0, scale: shot.scale) }
    }

    /// Draws a CGImage upright into a top-left-origin (flipped) context.
    static func drawFlipped(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(origin: .zero, size: rect.size))
        ctx.restoreGState()
    }

    private static func drawAspectFill(_ image: CGImage, in rect: CGRect, ctx: CGContext) {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let f = max(rect.width / iw, rect.height / ih)
        let size = CGSize(width: iw * f, height: ih * f)
        let dest = CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height)
        drawFlipped(image, in: dest, ctx: ctx)
    }

    private static func blurred(_ image: CGImage, radius: CGFloat) -> CGImage {
        guard radius > 0.5 else { return image }
        if let c = blurCache, c.source == ObjectIdentifier(image), c.radius == radius { return c.image }
        // Blur a downsampled copy: cheap, and blurred wallpaper needs no detail.
        let ci = CIImage(cgImage: image)
        let down = min(1, 1200 / max(ci.extent.width, ci.extent.height))
        let small = ci.transformed(by: CGAffineTransform(scaleX: down, y: down))
        let out = small.clampedToExtent()
            .applyingGaussianBlur(sigma: Double(radius * down * 2))
            .cropped(to: small.extent)
        guard let cg = ciContext.createCGImage(out, from: small.extent) else { return image }
        blurCache = (ObjectIdentifier(image), radius, cg)
        return cg
    }
}

/// Supplies the current desktop wallpaper image for the "Wallpaper" backdrop fill.
enum WallpaperProvider {
    private static var cached: CGImage?

    /// Synchronous: the wallpaper file of the main screen, if it is a readable image.
    static func current() -> CGImage? {
        if let cached { return cached }
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        cached = img
        return img
    }

    /// Fallback for dynamic/system wallpapers without a plain image file: capture only the desktop
    /// picture window(s) of the main display with ScreenCaptureKit.
    static func captureFromScreen() async -> CGImage? {
        if let cached { return cached }
        guard CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let screen = NSScreen.main,
              let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { return nil }
        let desktop = Capturer.desktopPictureWindows(in: content, display: display)
        guard !desktop.isEmpty else { return nil }
        let filter = SCContentFilter(display: display, including: desktop)
        let config = SCStreamConfiguration()
        config.width = Int(CGFloat(display.width) * screen.backingScaleFactor)
        config.height = Int(CGFloat(display.height) * screen.backingScaleFactor)
        config.showsCursor = false
        guard let img = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) else { return nil }
        cached = img
        return img
    }
}

/// Editor document view: draws the backdrop and hosts the canvas at the layout's image rect.
final class BackdropView: NSView {
    let canvas: CanvasView
    var settings = BackdropSettings() { didSet { relayout() } }
    var wallpaper: CGImage? { didSet { needsDisplay = true } }

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: canvas.frame)
        addSubview(canvas)
        canvas.wantsLayer = true
        canvas.layer?.masksToBounds = true
        // Redraw only when asked; never show stale or empty contents after moves/zooms.
        canvas.layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var layout: BackdropLayout { BackdropLayout(imageSize: canvas.imagePointSize, settings: settings) }

    func relayout() {
        let l = layout
        setFrameSize(l.canvasSize)
        canvas.setFrameOrigin(l.imageRect.origin)
        canvas.layer?.cornerRadius = settings.enabled ? min(settings.innerRadius, l.imageRect.width / 2, l.imageRect.height / 2) : 0
        refreshDisplay()
    }

    /// Forces both the backdrop and the screenshot layer to repaint (after relayout, zoom, or panel changes).
    func refreshDisplay() {
        needsDisplay = true
        canvas.needsDisplay = true
        canvas.layer?.setNeedsDisplay()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard settings.enabled, let ctx = NSGraphicsContext.current?.cgContext else { return }
        BackdropRenderer.drawBackground(in: ctx, layout: layout, settings: settings,
                                        shadowSource: canvas.state.base, wallpaper: wallpaper)
    }
}
