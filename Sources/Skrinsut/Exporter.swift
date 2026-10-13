import AppKit
import UniformTypeIdentifiers

/// Copy / save / save-as for finished screenshots.
enum Exporter {
    static func pngData(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    static func jpegData(_ image: CGImage, quality: CGFloat = 0.9) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    static func copy(_ shot: Screenshot) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let image = NSImage(cgImage: shot.image, size: shot.pointSize)
        pb.writeObjects([image])
        if let png = pngData(shot.image) { pb.setData(png, forType: .png) }
        Toast.show("Copied to clipboard")
    }

    static func copyText(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Returns file data and extension honoring the save-format and downscale preferences.
    static func encoded(_ shot: Screenshot) -> (Data, String)? {
        var image = shot.image
        if Settings.downscaleOnSave, shot.scale > 1,
           let small = ImageUtil.resized(image, width: Int(shot.pointSize.width), height: Int(shot.pointSize.height)) {
            image = small
        }
        switch Settings.saveFormat {
        case .png: return pngData(image).map { ($0, "png") }
        case .jpeg: return jpegData(image).map { ($0, "jpg") }
        case .auto:
            // Screenshots of UI compress best as PNG; switch to JPEG when PNG gets large (photos, gradients).
            guard let png = pngData(image) else { return nil }
            if png.count > 3_000_000, image.alphaInfo == .none || image.alphaInfo == .noneSkipLast || image.alphaInfo == .noneSkipFirst,
               let jpg = jpegData(image), jpg.count < png.count / 2 {
                return (jpg, "jpg")
            }
            return (png, "png")
        }
    }

    static func defaultFileName(ext: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Skrinsut \(f.string(from: Date())).\(ext)"
    }

    @discardableResult
    static func save(_ shot: Screenshot) -> URL? {
        guard let (data, ext) = encoded(shot) else { return nil }
        let folder = Settings.saveFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(defaultFileName(ext: ext))
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent(defaultFileName(ext: ext).replacingOccurrences(of: ".\(ext)", with: " \(n).\(ext)"))
            n += 1
        }
        do {
            try data.write(to: url)
            Toast.show("Saved to \(folder.lastPathComponent)")
            return url
        } catch {
            Toast.show("Save failed: \(error.localizedDescription)")
            return nil
        }
    }

    static func saveAs(_ shot: Screenshot, from window: NSWindow?) {
        guard let (data, ext) = encoded(shot) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ext == "png" ? .png : .jpeg]
        panel.nameFieldStringValue = defaultFileName(ext: ext)
        panel.directoryURL = Settings.saveFolder
        let handler: (NSApplication.ModalResponse) -> Void = { resp in
            guard resp == .OK, let url = panel.url else { return }
            do { try data.write(to: url) } catch { NSAlert(error: error).runModal() }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: handler) } else { handler(panel.runModal()) }
    }

    /// Writes a temporary PNG for drag-out.
    static func temporaryFile(_ shot: Screenshot) -> URL? {
        guard let png = pngData(shot.image) else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(defaultFileName(ext: "png"))
        do { try png.write(to: url); return url } catch { return nil }
    }
}
