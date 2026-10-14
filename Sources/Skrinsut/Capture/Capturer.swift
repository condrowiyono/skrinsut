import AppKit
import ScreenCaptureKit

/// A captured bitmap plus its pixels-per-point factor (2 on Retina).
struct Screenshot {
    var image: CGImage
    var scale: CGFloat

    var pointSize: CGSize { CGSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale) }
}

/// A frozen image of one display, used as the backdrop of the area/window selector.
struct DisplaySnapshot {
    let screen: NSScreen
    let image: CGImage
    var scale: CGFloat { CGFloat(image.width) / screen.frame.width }
}

/// A visible on-screen window in AppKit global coordinates (bottom-left origin).
struct WindowInfo {
    let windowID: CGWindowID
    let frame: CGRect
    let ownerName: String
    let title: String
}

enum CaptureError: LocalizedError {
    case permissionDenied, displayNotFound, windowNotFound
    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Screen Recording permission is required. Enable Skrinsut in System Settings → Privacy & Security → Screen Recording, then relaunch."
        case .displayNotFound: "Could not find the display to capture."
        case .windowNotFound: "Could not find the window to capture."
        }
    }
}

enum Capturer {
    static func ensurePermission() throws {
        if CGPreflightScreenCaptureAccess() { return }
        CGRequestScreenCaptureAccess()
        throw CaptureError.permissionDenied
    }

    /// Captures every display (excluding Skrinsut's own windows), returned in `NSScreen.screens` order.
    static func snapshotAllDisplays() async throws -> [DisplaySnapshot] {
        try ensurePermission()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        var result: [DisplaySnapshot] = []
        for screen in NSScreen.screens {
            guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) else { continue }
            let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let config = SCStreamConfiguration()
            let scale = screen.backingScaleFactor
            config.width = Int(CGFloat(display.width) * scale)
            config.height = Int(CGFloat(display.height) * scale)
            config.showsCursor = Settings.captureCursor
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append(DisplaySnapshot(screen: screen, image: image))
        }
        if result.isEmpty { throw CaptureError.displayNotFound }
        return result
    }

    /// Captures a single window independent of occlusion, honoring the window-background preference.
    static func captureWindow(id: CGWindowID) async throws -> Screenshot {
        try ensurePermission()
        let background = Settings.windowBackground
        let content = try await SCShareableContent.excludingDesktopWindows(background != .wallpaper, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.windowNotFound }
        if background == .wallpaper, let shot = try await captureWindowOnWallpaper(window, content: content) {
            return shot
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        config.ignoreShadowsSingleWindow = background == .trimmed
        let rect = background == .trimmed ? window.frame : filter.contentRect
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        config.backgroundColor = .clear
        config.shouldBeOpaque = false
        var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if background == .solid {
            image = ImageUtil.composite(image, over: Settings.windowSolidColor) ?? image
        }
        return Screenshot(image: image, scale: scale)
    }

    /// Renders only the desktop picture plus the target window (other windows and desktop icons are left out),
    /// cropped to the window frame with a margin of wallpaper around it. Returns nil if no desktop picture window is found.
    private static func captureWindowOnWallpaper(_ window: SCWindow, content: SCShareableContent) async throws -> Screenshot? {
        let center = CGPoint(x: window.frame.midX, y: window.frame.midY)
        guard let display = content.displays.first(where: { $0.frame.contains(center) })
                ?? content.displays.first(where: { $0.frame.intersects(window.frame) }) else { return nil }
        let desktop = desktopPictureWindows(in: content, display: display)
        guard !desktop.isEmpty else { return nil }

        // Frames are in global CG points (top-left origin); sourceRect is relative to the display.
        let local = window.frame.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        let margin = max(32, min(80, 0.08 * (local.width + local.height) / 2)).rounded()
        let source = local.insetBy(dx: -margin, dy: -margin)
            .intersection(CGRect(x: 0, y: 0, width: display.frame.width, height: display.frame.height))
            .integral
        guard !source.isEmpty else { return nil }

        let screen = NSScreen.screens.first { $0.displayID == display.displayID }
        let scale = screen?.backingScaleFactor ?? 2
        let filter = SCContentFilter(display: display, including: desktop + [window])
        let config = SCStreamConfiguration()
        config.sourceRect = source
        config.width = Int(source.width * scale)
        config.height = Int(source.height * scale)
        config.showsCursor = false
        config.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return Screenshot(image: image, scale: scale)
    }

    /// The desktop-picture window(s) on a display: below-normal layer, not Finder's desktop-icon window.
    static func desktopPictureWindows(in content: SCShareableContent, display: SCDisplay) -> [SCWindow] {
        content.windows.filter {
            $0.windowLayer < 0
                && $0.owningApplication?.bundleIdentifier != "com.apple.finder"
                && $0.frame.intersects(display.frame)
        }
    }

    /// On-screen normal-layer windows, front to back, excluding our own process.
    static func visibleWindows() -> [WindowInfo] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let pid = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return list.compactMap { info in
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  (info[kCGWindowOwnerPID as String] as? pid_t) != pid,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cg = CGRect(dictionaryRepresentation: boundsDict),
                  cg.width > 20, cg.height > 20
            else { return nil }
            // CoreGraphics global space has a top-left origin on the primary display.
            let frame = CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
            return WindowInfo(windowID: id, frame: frame, ownerName: info[kCGWindowOwnerName as String] as? String ?? "",
                              title: info[kCGWindowName as String] as? String ?? "")
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

enum ImageUtil {
    static func composite(_ image: CGImage, over color: NSColor) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage()
    }

    /// Crops a rect given in top-left-origin point coordinates.
    static func crop(_ shot: Screenshot, toPointRect r: CGRect) -> Screenshot? {
        let px = CGRect(x: r.minX * shot.scale, y: r.minY * shot.scale,
                        width: r.width * shot.scale, height: r.height * shot.scale).integral
        guard let img = shot.image.cropping(to: px) else { return nil }
        return Screenshot(image: img, scale: shot.scale)
    }

    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }
}

/// Reads RGBA values from a CGImage (used by the loupe and editor color picker).
final class PixelSampler {
    private let data: [UInt8]
    let width: Int
    let height: Int

    init?(_ image: CGImage) {
        let width = image.width, height = image.height
        self.width = width
        self.height = height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let ok = buffer.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        data = buffer
    }

    /// True when two pixels differ by more than `tolerance` in any channel (0...255).
    func differs(_ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, tolerance: Int) -> Bool {
        let i = (y1 * width + x1) * 4, j = (y2 * width + x2) * 4
        for k in 0..<4 where abs(Int(data[i + k]) - Int(data[j + k])) > tolerance { return true }
        return false
    }

    /// From (x, y), walks outward along one axis until the color changes; returns the half-open pixel span
    /// of same-colored pixels containing (x, y), e.g. the gap between two UI elements.
    func span(x: Int, y: Int, horizontal: Bool, tolerance: Int = 10) -> Range<Int>? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        var lo = horizontal ? x : y
        var hi = lo
        let limit = horizontal ? width : height
        func at(_ v: Int) -> (Int, Int) { horizontal ? (v, y) : (x, v) }
        while lo > 0 {
            let (a, b) = at(lo - 1)
            if differs(a, b, x, y, tolerance: tolerance) { break }
            lo -= 1
        }
        while hi + 1 < limit {
            let (a, b) = at(hi + 1)
            if differs(a, b, x, y, tolerance: tolerance) { break }
            hi += 1
        }
        return lo..<(hi + 1)
    }

    /// Pixel coordinates use a top-left origin.
    func color(x: Int, y: Int) -> NSColor? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        // The bitmap context stores rows bottom-up relative to CG drawing, i.e. row 0 is the image's top row.
        let i = (y * width + x) * 4
        return NSColor(srgbRed: CGFloat(data[i]) / 255, green: CGFloat(data[i + 1]) / 255,
                       blue: CGFloat(data[i + 2]) / 255, alpha: CGFloat(data[i + 3]) / 255)
    }
}
