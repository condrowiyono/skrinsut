import AppKit

/// Listens on `McpSocket` inside the running app and answers tool calls from `Skrinsut --mcp`.
/// Replies are MCP `CallToolResult` objects, passed through unchanged by the stdio server.
/// Every call is refused unless Settings ▸ Deep Links ▸ "Allow AI assistants (MCP)" is on.
final class McpBridge {
    static let shared = McpBridge()
    private var listener: Int32 = -1

    func start() {
        let path = McpSocket.path
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, McpSocket.withAddress({ bind(fd, $0, $1) }) == 0, listen(fd, 8) == 0 else {
            NSLog("Skrinsut MCP: could not listen on \(path)")
            if fd >= 0 { close(fd) }
            return
        }
        chmod(path, 0o600) // only this user can connect
        listener = fd
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { continue }
                DispatchQueue.global().async { self.serve(client) }
            }
        }
    }

    private func serve(_ client: Int32) {
        let request = (try? JSONSerialization.jsonObject(with: McpSocket.readToEnd(client))) as? [String: Any] ?? [:]
        let tool = request["tool"] as? String ?? ""
        let args = request["arguments"] as? [String: Any] ?? [:]
        Task { @MainActor in
            let result = await self.call(tool, args)
            if let data = try? JSONSerialization.data(withJSONObject: result) { McpSocket.writeAll(client, data) }
            close(client)
        }
    }

    // MARK: Tools

    @MainActor
    private func call(_ tool: String, _ args: [String: Any]) async -> [String: Any] {
        guard Settings.allowMcp else {
            Toast.notice("AI assistant access is off", detail: "Something tried to use \(tool). Turn it on in Settings ▸ Deep Links.")
            return error("Skrinsut's AI assistant access is off. Ask the user to turn on Settings ▸ Deep Links ▸ Allow AI assistants (MCP).")
        }
        do {
            try Capturer.ensurePermission()
            switch tool {
            case "list_windows":
                let windows = Capturer.visibleWindows().map { w -> [String: Any] in
                    ["id": w.windowID, "app": w.ownerName, "title": w.title,
                     "frame": ["x": w.frame.minX, "y": w.frame.minY, "width": w.frame.width, "height": w.frame.height]]
                }
                let json = try JSONSerialization.data(withJSONObject: windows, options: [.prettyPrinted, .sortedKeys])
                return text(String(decoding: json, as: UTF8.self))
            case "capture_screen":
                let snaps = try await Capturer.snapshotAllDisplays()
                let i = args["display"] as? Int ?? 0
                guard snaps.indices.contains(i) else { return error("No display \(i); there are \(snaps.count).") }
                return image(snaps[i].image, args, tool)
            case "capture_window":
                guard let id = args["window_id"] as? Int else { return error("window_id is required.") }
                return image(try await Capturer.captureWindow(id: CGWindowID(id)).image, args, tool)
            case "capture_area":
                guard let shot = try await pickArea() else { return error("The user cancelled the selection.") }
                return image(shot.image, args, tool)
            case "recognize_text":
                let shot: Screenshot?
                if let id = args["window_id"] as? Int {
                    shot = try await Capturer.captureWindow(id: CGWindowID(id))
                } else {
                    shot = try await pickArea()
                }
                guard let shot else { return error("The user cancelled the selection.") }
                let result = await withCheckedContinuation { cont in OCR.recognize(shot.image) { cont.resume(returning: $0) } }
                notify(tool)
                return text(result?.text ?? "(no text found)")
            default:
                return error("Unknown tool: \(tool)")
            }
        } catch {
            return self.error(error.localizedDescription)
        }
    }

    /// Runs the area selector; Space switches it to window mode, as with the hotkey.
    @MainActor
    private func pickArea() async throws -> Screenshot? {
        let snaps = try await Capturer.snapshotAllDisplays()
        let outcome = await withCheckedContinuation { cont in
            RegionSelector.run(snapshots: snaps, mode: .area) { cont.resume(returning: $0) }
        }
        switch outcome {
        case .cancelled: return nil
        case let .area(shot, _, _): return shot
        case let .window(id): return try await Capturer.captureWindow(id: id)
        }
    }

    // MARK: Results

    private func image(_ cg: CGImage, _ args: [String: Any], _ tool: String) -> [String: Any] {
        var cg = cg
        let maxWidth = args["max_width"] as? Int ?? 1600
        if maxWidth > 0, cg.width > maxWidth {
            let h = Int((Double(cg.height) * Double(maxWidth) / Double(cg.width)).rounded())
            cg = ImageUtil.resized(cg, width: maxWidth, height: h) ?? cg
        }
        guard let png = Exporter.pngData(cg) else { return error("Could not encode the image.") }
        notify(tool)
        return ["content": [["type": "image", "mimeType": "image/png", "data": png.base64EncodedString()]]]
    }

    /// Always visible, so captures by an assistant never happen silently.
    private func notify(_ tool: String) {
        Toast.notice("Shared with AI assistant", detail: tool.replacingOccurrences(of: "_", with: " "))
    }

    private func text(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]]] }
    private func error(_ s: String) -> [String: Any] { ["isError": true, "content": [["type": "text", "text": s]]] }
}
