import Foundation

enum RecordFormat: String, CaseIterable, Identifiable {
    case mp4, gif
    var id: String { rawValue }
    var title: String { self == .mp4 ? "MP4" : "GIF" }
    var fileExtension: String { rawValue }
}

enum FFmpegError: LocalizedError {
    case notFound
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notFound: "ffmpeg was not found. Install it from Settings ▸ Recording, or set its path there."
        case .failed(let log): "ffmpeg failed to encode the recording.\n\n\(log)"
        }
    }
}

/// Finds and runs the user's installed ffmpeg (Homebrew or system) to encode recordings.
enum FFmpeg {
    static let knownPaths = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"]

    /// The Settings override if valid, then well-known locations, then the login shell's PATH
    /// (apps opened from Finder don't inherit the shell PATH).
    static func locate() -> URL? {
        let fm = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: SettingKey.ffmpegPath), !custom.isEmpty,
           fm.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        if let p = knownPaths.first(where: fm.isExecutableFile(atPath:)) { return URL(fileURLWithPath: p) }
        let found = runSync("/bin/zsh", ["-lc", "command -v ffmpeg"]).trimmingCharacters(in: .whitespacesAndNewlines)
        return !found.isEmpty && fm.isExecutableFile(atPath: found) ? URL(fileURLWithPath: found) : nil
    }

    private static var encoderCache: [String: Bool] = [:]

    static func hasEncoder(_ name: String, ffmpeg: URL) -> Bool {
        let key = ffmpeg.path + "|" + name
        if let cached = encoderCache[key] { return cached }
        let ok = runSync(ffmpeg.path, ["-hide_banner", "-encoders"]).contains(" \(name) ")
        encoderCache[key] = ok
        return ok
    }

    static func arguments(input: URL, output: URL, format: RecordFormat, size: CGSize,
                          settings v: VideoSettings, ffmpeg: URL) -> [String] {
        var args = ["-hide_banner", "-y", "-nostats", "-progress", "pipe:1", "-i", input.path]
        switch format {
        case .mp4:
            let out = v.outputSize(for: size)
            let scale = out == size ? "scale=trunc(iw/2)*2:trunc(ih/2)*2" : "scale=\(Int(out.width)):\(Int(out.height)):flags=lanczos"
            args += ["-vf", scale, "-fps_mode", "cfr", "-r", String(v.fps)]
            args += videoCodecArguments(v, size: out, ffmpeg: ffmpeg)
            args += ["-pix_fmt", "yuv420p", "-movflags", "+faststart", "-an"]
        case .gif:
            let out = v.outputSize(for: size, even: false)
            let filter = "fps=\(v.gifFPS),scale=\(Int(out.width)):-1:flags=lanczos,split[a][b];" +
                "[a]palettegen=max_colors=\(v.gifColors):stats_mode=diff[p];[b][p]paletteuse=dither=\(v.gifDither.filterValue)"
            args += ["-vf", filter, "-loop", "0"]
        }
        return args + [output.path]
    }

    /// Codec/rate-control flags. Software → libx264/libx265 (CRF or bitrate with a VBV cap);
    /// hardware → VideoToolbox (bitrate; constant-quality maps the slider to an estimated bitrate).
    /// Falls back to the other encoder family when one isn't built into this ffmpeg.
    static func videoCodecArguments(_ v: VideoSettings, size: CGSize, ffmpeg: URL) -> [String] {
        let software = v.codec == .h264 ? "libx264" : "libx265"
        let hardware = v.codec == .h264 ? "h264_videotoolbox" : "hevc_videotoolbox"
        let useSoftware = v.encoder == .software ? hasEncoder(software, ffmpeg: ffmpeg) : !hasEncoder(hardware, ffmpeg: ffmpeg)
        var args: [String] = []
        let bitrate = v.rateControl == .bitrate ? Int(v.bitrateMbps * 1_000_000) : v.estimatedBitrate(for: size)
        if useSoftware {
            args += ["-c:v", software, "-preset", v.speed.x26xPreset]
            if v.rateControl == .quality {
                args += ["-crf", String(v.crf)]
            } else {
                args += ["-b:v", String(bitrate), "-maxrate", String(bitrate * 3 / 2), "-bufsize", String(bitrate * 2)]
            }
            if v.codec == .hevc { args += ["-x265-params", "log-level=error"] }
        } else {
            args += ["-c:v", hardware, "-b:v", String(bitrate)]
            if v.speed == .fast { args += ["-prio_speed", "1"] }
        }
        if v.codec == .hevc { args += ["-tag:v", "hvc1"] } // plays in QuickTime/Finder
        return args
    }

    /// Encodes `input` to `output`. Progress (0…1) and completion are delivered on the main queue.
    /// Returns the running process so callers can cancel it.
    @discardableResult
    static func encode(input: URL, output: URL, format: RecordFormat, duration: Double, size: CGSize,
                       settings: VideoSettings = .current,
                       progress: @escaping (Double) -> Void,
                       completion: @escaping (Result<URL, Error>) -> Void) -> Process? {
        guard let ffmpeg = locate() else {
            completion(.failure(FFmpegError.notFound))
            return nil
        }
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = arguments(input: input, output: output, format: format, size: size, settings: settings, ffmpeg: ffmpeg)
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        var errorLog = Data()
        let logLock = NSLock()
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            logLock.lock(); errorLog.append(d); if errorLog.count > 16_384 { errorLog = errorLog.suffix(8_192) }; logLock.unlock()
        }
        var pending = ""
        out.fileHandleForReading.readabilityHandler = { h in
            guard let chunk = String(data: h.availableData, encoding: .utf8), !chunk.isEmpty else { return }
            pending += chunk
            let lines = pending.components(separatedBy: "\n")
            pending = lines.last ?? ""
            for line in lines.dropLast() {
                if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst("out_time_us=".count)), duration > 0 {
                    let f = min(max(us / 1_000_000 / duration, 0), 1)
                    DispatchQueue.main.async { progress(f) }
                } else if line == "progress=end" {
                    DispatchQueue.main.async { progress(1) }
                }
            }
        }
        process.terminationHandler = { p in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            logLock.lock(); let log = String(data: errorLog, encoding: .utf8) ?? ""; logLock.unlock()
            let ok = p.terminationReason == .exit && p.terminationStatus == 0
            DispatchQueue.main.async {
                if ok {
                    completion(.success(output))
                } else {
                    let tail = log.split(separator: "\n").suffix(6).joined(separator: "\n")
                    completion(.failure(FFmpegError.failed(tail)))
                }
            }
        }
        do {
            try process.run()
        } catch {
            completion(.failure(error))
            return nil
        }
        return process
    }

    /// Runs a short command and returns stdout (empty on failure).
    static func runSync(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
