import AVFoundation
import AppKit
import ScreenCaptureKit

enum RecordingTarget {
    /// Area in display-local points (top-left origin) on the given display.
    case area(CGRect, displayID: CGDirectDisplayID)
    case window(CGWindowID)
    case display(CGDirectDisplayID)
}

enum RecorderError: LocalizedError {
    case noFrames
    case writerFailed(String)

    var errorDescription: String? {
        switch self {
        case .noFrames: "Nothing was recorded."
        case .writerFailed(let msg): "Couldn't write the recording: \(msg)"
        }
    }
}

/// Records a display area, window, or display with ScreenCaptureKit into a high-quality temporary .mov
/// (H.264 via AVAssetWriter, no audio). ffmpeg turns it into the final MP4/GIF afterwards.
final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("skrinsut-recording-\(UUID().uuidString).mov")
    var onError: ((Error) -> Void)?

    private var stream: SCStream?
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private let queue = DispatchQueue(label: "skrinsut.recorder")
    // Touched only on `queue`.
    private var firstPTS: CMTime?
    private var lastSample: CMSampleBuffer?
    /// Pixel size of the recording (known after `start`).
    private(set) var pixelSize: CGSize = .zero

    func start(_ target: RecordingTarget) async throws {
        try Capturer.ensurePermission()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        var size: CGSize
        var scale: CGFloat

        switch target {
        case let .area(rect, displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.displayNotFound }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            config.sourceRect = rect
            size = rect.size
            scale = NSScreen.screens.first { $0.displayID == displayID }?.backingScaleFactor ?? 2
        case let .display(displayID):
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.displayNotFound }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            size = CGSize(width: display.width, height: display.height)
            scale = NSScreen.screens.first { $0.displayID == displayID }?.backingScaleFactor ?? 2
        case let .window(id):
            guard let window = content.windows.first(where: { $0.windowID == id }) else { throw CaptureError.windowNotFound }
            filter = SCContentFilter(desktopIndependentWindow: window)
            config.ignoreShadowsSingleWindow = true
            size = window.frame.size
            scale = CGFloat(filter.pointPixelScale)
        }

        let video = VideoSettings.current
        let fps = Int32(video.fps)
        // H.264 needs even dimensions.
        let width = max(2, Int((size.width * scale).rounded()) & ~1)
        let height = max(2, Int((size.height * scale).rounded()) & ~1)
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: fps)
        config.showsCursor = video.showCursor
        pixelSize = CGSize(width: width, height: height)
        config.queueDepth = 6
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.capturesAudio = false

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                // Generous bitrate: this is an intermediate that ffmpeg re-encodes.
                AVVideoAverageBitRateKey: max(10_000_000, width * height * Int(fps) / 3),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw RecorderError.writerFailed("unsupported video settings") }
        writer.add(input)
        guard writer.startWriting() else { throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown") }
        self.writer = writer
        self.input = input

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    /// Stops capture and finalizes the file. Returns the temp .mov and its duration in seconds.
    func stop() async throws -> (url: URL, duration: Double) {
        if let stream { try? await stream.stopCapture() }
        stream = nil
        guard let writer, let input else { throw RecorderError.noFrames }

        // Hold the last frame until the moment Stop was pressed (ScreenCaptureKit only sends frames on change).
        let end: CMTime? = queue.sync {
            guard let first = firstPTS else { return nil }
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            var endTime = now
            if let last = lastSample, CMTimeCompare(now, last.presentationTimeStamp) > 0,
               let tail = Self.retimed(last, to: now), input.isReadyForMoreMediaData {
                input.append(tail)
            } else if let last = lastSample {
                endTime = last.presentationTimeStamp
            }
            input.markAsFinished()
            return CMTimeCompare(endTime, first) > 0 ? endTime : nil
        }
        guard let end, let first = queue.sync(execute: { firstPTS }) else {
            writer.cancelWriting()
            throw RecorderError.noFrames
        }
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        if writer.status != .completed {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "status \(writer.status.rawValue)")
        }
        return (url, CMTimeGetSeconds(CMTimeSubtract(end, first)))
    }

    // MARK: SCStreamOutput / SCStreamDelegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid, let writer, let input,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if firstPTS == nil {
            writer.startSession(atSourceTime: sample.presentationTimeStamp)
            firstPTS = sample.presentationTimeStamp
        }
        if input.isReadyForMoreMediaData, input.append(sample) {
            lastSample = sample
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onError?(error) }
    }

    private static func retimed(_ sample: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var out: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sample, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &out)
        return out
    }
}
