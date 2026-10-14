import Foundation

/// The Unix socket between `Skrinsut --mcp` and the running app. One request per connection:
/// the client writes a JSON object and closes its write side; the app answers with one JSON object.
enum McpSocket {
    static var path: String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Skrinsut", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mcp.sock").path
    }

    static func address() -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            let bytes = Array(path.utf8.prefix(buf.count - 1))
            buf.copyBytes(from: bytes)
            buf[bytes.count] = 0
        }
        return addr
    }

    static func withAddress<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var addr = address()
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    static func readToEnd(_ fd: Int32) -> Data {
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    /// Client side: sends one request and waits for the reply. Nil when the app isn't listening.
    static func request(_ body: [String: Any]) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        guard withAddress({ connect(fd, $0, $1) }) == 0,
              let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
        writeAll(fd, payload)
        shutdown(fd, SHUT_WR)
        return (try? JSONSerialization.jsonObject(with: readToEnd(fd))) as? [String: Any]
    }
}
