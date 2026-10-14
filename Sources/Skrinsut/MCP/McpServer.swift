import Foundation

/// `Skrinsut --mcp`: a stdio MCP server (newline-delimited JSON-RPC 2.0). It holds no screen access
/// of its own: every tool call is forwarded to the running app, which owns the Screen Recording
/// permission, over `McpSocket`.
enum McpServer {
    static let tools: [[String: Any]] = [
        tool("list_windows", "List visible windows (id, app, title, frame) to pick one for capture_window.", [:]),
        tool("capture_screen", "Screenshot an entire display.", [
            "display": ["type": "integer", "description": "Display index, 0 = main display (default 0)"],
            "max_width": maxWidth,
        ]),
        tool("capture_window", "Screenshot one window by id (see list_windows), even if it is covered.", [
            "window_id": ["type": "integer"],
            "max_width": maxWidth,
        ], required: ["window_id"]),
        tool("capture_area", "Ask the user to drag-select an area of the screen, then return that screenshot.", [
            "max_width": maxWidth,
        ]),
        tool("recognize_text", "Recognize text or a QR/barcode. Uses window_id if given, otherwise asks the user to select an area.", [
            "window_id": ["type": "integer"],
        ]),
    ]

    private static let maxWidth: [String: Any] = [
        "type": "integer", "description": "Downscale wider images to this many pixels (default 1600, 0 = full size)",
    ]

    private static func tool(_ name: String, _ description: String, _ props: [String: Any],
                             required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": props, "required": required]]
    }

    static func run() -> Never {
        while let line = readLine() {
            guard let msg = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let method = msg["method"] as? String else { continue }
            guard let id = msg["id"] else { continue } // notifications need no reply
            let params = msg["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                reply(id, result: [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:]],
                    "serverInfo": ["name": "skrinsut", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "dev"],
                ])
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                reply(id, result: call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:]))
            default:
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
            }
        }
        exit(0)
    }

    private static func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let request: [String: Any] = ["tool": name, "arguments": arguments]
        if let result = McpSocket.request(request) { return result }
        // The app isn't running: start it and wait for its socket.
        launchApp()
        for _ in 0..<40 {
            usleep(250_000)
            if let result = McpSocket.request(request) { return result }
        }
        return ["isError": true, "content": [["type": "text", "text": "Couldn't reach the Skrinsut app. Is it installed and running?"]]]
    }

    private static func launchApp() {
        let bundle = Bundle.main.bundleURL
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = bundle.pathExtension == "app" ? ["-g", bundle.path] : ["-g", "-b", "com.skrinsut.app"]
        try? open.run()
        open.waitUntilExit()
    }

    private static func reply(_ id: Any, result: [String: Any]) {
        send(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
