import Foundation

/// Recording/encoding options (Settings ▸ Video). Stored in UserDefaults under `video-*` keys.
enum VideoKey {
    static let maxResolution = "video-maxResolution"
    static let fps = "video-fps"
    static let codec = "video-codec"
    static let encoder = "video-encoder"
    static let rateControl = "video-rateControl"
    static let quality = "video-quality"         // 0...1
    static let bitrateMbps = "video-bitrateMbps"
    static let speed = "video-speed"
    static let showCursor = "video-showCursor"
    static let gifFPS = "video-gifFPS"
    static let gifColors = "video-gifColors"
    static let gifDither = "video-gifDither"
}

enum MaxResolution: String, CaseIterable, Identifiable {
    case original, p2160, p1440, p1080, p720, p480
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: "Original"
        case .p2160: "2160p (4K)"
        case .p1440: "1440p"
        case .p1080: "1080p"
        case .p720: "720p"
        case .p480: "480p"
        }
    }
    /// Short-side limit in pixels (the long side is limited to 16:9 of it).
    var shortSide: Int? {
        switch self {
        case .original: nil
        case .p2160: 2160
        case .p1440: 1440
        case .p1080: 1080
        case .p720: 720
        case .p480: 480
        }
    }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var title: String { self == .h264 ? "H.264 (most compatible)" : "HEVC / H.265 (smaller files)" }
}

enum VideoEncoder: String, CaseIterable, Identifiable {
    case software, hardware
    var id: String { rawValue }
    var title: String { self == .software ? "Software (best quality)" : "Hardware (fastest)" }
}

enum RateControl: String, CaseIterable, Identifiable {
    case quality, bitrate
    var id: String { rawValue }
    var title: String { self == .quality ? "Constant quality" : "Target bitrate" }
}

enum EncodeSpeed: String, CaseIterable, Identifiable {
    case fast, balanced, small
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: "Fast"
        case .balanced: "Balanced"
        case .small: "Smallest file"
        }
    }
    var x26xPreset: String {
        switch self {
        case .fast: "veryfast"
        case .balanced: "medium"
        case .small: "slow"
        }
    }
}

enum GIFDither: String, CaseIterable, Identifiable {
    case bayer, floyd, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bayer: "Ordered (smaller)"
        case .floyd: "Error diffusion (smoother)"
        case .none: "None"
        }
    }
    var filterValue: String {
        switch self {
        case .bayer: "bayer:bayer_scale=5"
        case .floyd: "floyd_steinberg"
        case .none: "none"
        }
    }
}

struct VideoSettings {
    var maxResolution: MaxResolution = .original
    var fps = 30
    var codec: VideoCodec = .h264
    var encoder: VideoEncoder = .software
    var rateControl: RateControl = .quality
    var quality = 0.75
    var bitrateMbps = 8.0
    var speed: EncodeSpeed = .fast
    var showCursor = true
    var gifFPS = 15
    var gifColors = 256
    var gifDither: GIFDither = .bayer

    static let frameRates = [15, 24, 30, 60]
    static let gifFrameRates = [10, 15, 20, 25]
    static let gifColorCounts = [256, 128, 64, 32]

    static func registerDefaults() {
        let d = VideoSettings()
        UserDefaults.standard.register(defaults: [
            VideoKey.maxResolution: d.maxResolution.rawValue,
            VideoKey.fps: d.fps,
            VideoKey.codec: d.codec.rawValue,
            VideoKey.encoder: d.encoder.rawValue,
            VideoKey.rateControl: d.rateControl.rawValue,
            VideoKey.quality: d.quality,
            VideoKey.bitrateMbps: d.bitrateMbps,
            VideoKey.speed: d.speed.rawValue,
            VideoKey.showCursor: d.showCursor,
            VideoKey.gifFPS: d.gifFPS,
            VideoKey.gifColors: d.gifColors,
            VideoKey.gifDither: d.gifDither.rawValue,
        ])
    }

    static var current: VideoSettings {
        let u = UserDefaults.standard
        var s = VideoSettings()
        s.maxResolution = MaxResolution(rawValue: u.string(forKey: VideoKey.maxResolution) ?? "") ?? s.maxResolution
        s.fps = frameRates.contains(u.integer(forKey: VideoKey.fps)) ? u.integer(forKey: VideoKey.fps) : s.fps
        s.codec = VideoCodec(rawValue: u.string(forKey: VideoKey.codec) ?? "") ?? s.codec
        s.encoder = VideoEncoder(rawValue: u.string(forKey: VideoKey.encoder) ?? "") ?? s.encoder
        s.rateControl = RateControl(rawValue: u.string(forKey: VideoKey.rateControl) ?? "") ?? s.rateControl
        s.quality = min(max(u.double(forKey: VideoKey.quality), 0), 1)
        s.bitrateMbps = min(max(u.double(forKey: VideoKey.bitrateMbps), 0.5), 100)
        s.speed = EncodeSpeed(rawValue: u.string(forKey: VideoKey.speed) ?? "") ?? s.speed
        s.showCursor = u.bool(forKey: VideoKey.showCursor)
        s.gifFPS = gifFrameRates.contains(u.integer(forKey: VideoKey.gifFPS)) ? u.integer(forKey: VideoKey.gifFPS) : s.gifFPS
        s.gifColors = gifColorCounts.contains(u.integer(forKey: VideoKey.gifColors)) ? u.integer(forKey: VideoKey.gifColors) : s.gifColors
        s.gifDither = GIFDither(rawValue: u.string(forKey: VideoKey.gifDither) ?? "") ?? s.gifDither
        return s
    }

    /// x264 CRF for the quality slider: 0 → 34 (small, soft) … 1 → 16 (near-lossless). x265 uses +4 for similar quality.
    var crf: Int { Int((34 - quality * 18).rounded()) + (codec == .hevc ? 4 : 0) }

    var qualityLabel: String {
        switch quality {
        case ..<0.3: "Low"
        case ..<0.6: "Medium"
        case ..<0.85: "High"
        default: "Very high"
        }
    }

    /// Output size after applying the max-resolution cap (orientation-aware, aspect kept, even for H.264).
    func outputSize(for input: CGSize, even: Bool = true) -> CGSize {
        var w = input.width, h = input.height
        if let short = maxResolution.shortSide {
            let s = CGFloat(short), l = (CGFloat(short) * 16 / 9).rounded()
            let (boxW, boxH) = w >= h ? (l, s) : (s, l)
            let f = min(1, boxW / w, boxH / h)
            w *= f; h *= f
        }
        if even { return CGSize(width: max(2, Int(w) & ~1), height: max(2, Int(h) & ~1)) }
        return CGSize(width: max(1, Int(w.rounded())), height: max(1, Int(h.rounded())))
    }

    /// Bitrate used by the hardware encoder in constant-quality mode (bits per pixel per frame from the slider).
    func estimatedBitrate(for size: CGSize) -> Int {
        let bpp = 0.03 + quality * 0.17
        return Int(size.width * size.height * CGFloat(fps) * bpp)
    }
}
