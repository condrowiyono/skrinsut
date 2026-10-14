import AppKit

/// UserDefaults keys.
enum SettingKey {
    static let afterGrabShow = "setting-afterGrabShowEditor"    // Bool: open the editor after a capture
    static let afterGrabCopy = "setting-afterGrabCopy"
    static let afterGrabSave = "setting-afterGrabSave"
    static let defaultFolder = "setting-defaultFolder"
    static let saveFormat = "setting-saveFormat"
    static let downscaleOnSave = "setting-downscaleOnSave"
    static let windowBackground = "setting-windowShadow"         // WindowBackground raw value
    static let windowSolidColor = "setting-windowSolidColor"     // hex string
    static let copyOnEsc = "setting-copyOnEsc"
    static let saveOnEsc = "setting-saveOnEsc"
    static let alwaysOnTop = "setting-alwaysOnTop"
    static let ocrRemoveBreaks = "setting-ocrRemoveBreaks"
    static let allowDeeplinks = "setting-allowDeeplinks"
    static let allowMcp = "setting-allowMcp"                    // Bool: AI assistants may capture via MCP
    static let thumbnailClosing = "setting-thumbnailClosing"     // ThumbnailClosing raw value
    static let notificationType = "setting-notificationType"     // "custom" | "none"
    static let captureCursor = "setting-captureCursor"
    static let showMenubarIcon = "setting-showMenubarIcon"
    static let snapping = "setting-snappingMode"                // Bool: snap objects to edges/objects
    static let recordFormat = "setting-recordFormat"            // RecordFormat raw value
    static let ffmpegPath = "setting-ffmpegPath"                // optional override for the ffmpeg binary
}

enum WindowBackground: String, CaseIterable, Identifiable {
    case wallpaper, transparent, trimmed, solid
    var id: String { rawValue }
    var title: String {
        switch self {
        case .wallpaper: "Wallpaper"
        case .transparent: "Transparent (with shadow)"
        case .trimmed: "Trim shadow"
        case .solid: "Solid color"
        }
    }
}

enum SaveFormat: String, CaseIterable, Identifiable {
    case png, jpeg, auto
    var id: String { rawValue }
    var title: String {
        switch self {
        case .png: "PNG"
        case .jpeg: "JPEG"
        case .auto: "Auto (PNG/JPEG)"
        }
    }
}

enum ThumbnailClosing: String, CaseIterable, Identifiable {
    case automatic, manual
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatically (click outside)"
        case .manual: "Manually (close button)"
        }
    }
}

enum Settings {
    private static var d: UserDefaults { .standard }

    static func registerDefaults() {
        let pictures = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first?.path ?? NSHomeDirectory()
        d.register(defaults: [
            SettingKey.afterGrabShow: true,
            SettingKey.afterGrabCopy: false,
            SettingKey.afterGrabSave: false,
            SettingKey.defaultFolder: pictures,
            SettingKey.saveFormat: SaveFormat.png.rawValue,
            SettingKey.downscaleOnSave: false,
            SettingKey.windowBackground: WindowBackground.transparent.rawValue,
            SettingKey.windowSolidColor: "#C4C6C8",
            SettingKey.copyOnEsc: false,
            SettingKey.saveOnEsc: false,
            SettingKey.alwaysOnTop: false,
            SettingKey.ocrRemoveBreaks: false,
            SettingKey.allowDeeplinks: false,
            SettingKey.allowMcp: false,
            SettingKey.thumbnailClosing: ThumbnailClosing.automatic.rawValue,
            SettingKey.notificationType: "custom",
            SettingKey.captureCursor: false,
            SettingKey.showMenubarIcon: true,
            SettingKey.snapping: true,
            SettingKey.recordFormat: RecordFormat.mp4.rawValue,
        ])
    }

    static var afterCaptureShow: Bool { d.bool(forKey: SettingKey.afterGrabShow) }
    static var afterCaptureCopy: Bool { d.bool(forKey: SettingKey.afterGrabCopy) }
    static var afterCaptureSave: Bool { d.bool(forKey: SettingKey.afterGrabSave) }
    static var saveFolder: URL {
        URL(fileURLWithPath: d.string(forKey: SettingKey.defaultFolder) ?? NSHomeDirectory(), isDirectory: true)
    }
    static var saveFormat: SaveFormat { SaveFormat(rawValue: d.string(forKey: SettingKey.saveFormat) ?? "") ?? .png }
    static var downscaleOnSave: Bool { d.bool(forKey: SettingKey.downscaleOnSave) }
    static var windowBackground: WindowBackground {
        WindowBackground(rawValue: d.string(forKey: SettingKey.windowBackground) ?? "") ?? .transparent
    }
    static var windowSolidColor: NSColor { NSColor(hex: d.string(forKey: SettingKey.windowSolidColor) ?? "") ?? .lightGray }
    static var copyOnEsc: Bool { d.bool(forKey: SettingKey.copyOnEsc) }
    static var saveOnEsc: Bool { d.bool(forKey: SettingKey.saveOnEsc) }
    static var alwaysOnTop: Bool { d.bool(forKey: SettingKey.alwaysOnTop) }
    static var ocrRemoveBreaks: Bool { d.bool(forKey: SettingKey.ocrRemoveBreaks) }
    static var allowDeeplinks: Bool { d.bool(forKey: SettingKey.allowDeeplinks) }
    static var allowMcp: Bool { d.bool(forKey: SettingKey.allowMcp) }
    static var thumbnailClosing: ThumbnailClosing {
        ThumbnailClosing(rawValue: d.string(forKey: SettingKey.thumbnailClosing) ?? "") ?? .automatic
    }
    static var showToasts: Bool { d.string(forKey: SettingKey.notificationType) != "none" }
    static var captureCursor: Bool { d.bool(forKey: SettingKey.captureCursor) }
    static var recordFormat: RecordFormat {
        RecordFormat(rawValue: d.string(forKey: SettingKey.recordFormat) ?? "") ?? .mp4
    }
    static var snapping: Bool {
        get { d.bool(forKey: SettingKey.snapping) }
        set { d.set(newValue, forKey: SettingKey.snapping) }
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                  green: CGFloat((v >> 8) & 0xFF) / 255,
                  blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        return String(format: "#%02X%02X%02X",
                      Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    }
}
