import AppKit

/// One-click install of ffmpeg: `brew install ffmpeg` in the background when Homebrew is present;
/// otherwise a Terminal script that installs Homebrew (needs the admin password) and then ffmpeg.
enum DependencyInstaller {
    enum InstallError: LocalizedError {
        case brewFailed(String)
        case notFoundAfterInstall

        var errorDescription: String? {
            switch self {
            case .brewFailed(let log): "Homebrew couldn't install ffmpeg.\n\n\(log)"
            case .notFoundAfterInstall: "ffmpeg was installed but couldn't be found. Set its path in Settings."
            }
        }
    }

    enum Outcome {
        case installed(URL)
        /// Homebrew was missing; the installer opened in Terminal for the user to finish.
        case openedTerminal
    }

    static var brewPath: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private static var running: Process?
    static var isInstalling: Bool { running != nil }

    /// `onOutput` receives the latest meaningful output line; both callbacks run on the main queue.
    static func installFFmpeg(onOutput: @escaping (String) -> Void, completion: @escaping (Result<Outcome, Error>) -> Void) {
        guard running == nil else { return }
        guard let brew = brewPath else {
            do {
                try openTerminalInstaller()
                completion(.success(.openedTerminal))
            } catch {
                completion(.failure(error))
            }
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: brew)
        p.arguments = ["install", "ffmpeg"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        env["NONINTERACTIVE"] = "1"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe

        var log = ""
        let lock = NSLock()
        pipe.fileHandleForReading.readabilityHandler = { h in
            guard let s = String(data: h.availableData, encoding: .utf8), !s.isEmpty else { return }
            lock.lock(); log += s; if log.count > 20_000 { log = String(log.suffix(10_000)) }; lock.unlock()
            if let line = s.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).last(where: { !$0.isEmpty }) {
                DispatchQueue.main.async { onOutput(line) }
            }
        }
        p.terminationHandler = { proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            lock.lock(); let text = log; lock.unlock()
            DispatchQueue.main.async {
                running = nil
                guard proc.terminationStatus == 0 else {
                    completion(.failure(InstallError.brewFailed(text.split(separator: "\n").suffix(6).joined(separator: "\n"))))
                    return
                }
                if let url = FFmpeg.locate() { completion(.success(.installed(url))) } else { completion(.failure(InstallError.notFoundAfterInstall)) }
            }
        }
        do {
            try p.run()
            running = p
            onOutput("Installing ffmpeg with Homebrew…")
        } catch {
            completion(.failure(error))
        }
    }

    /// Script run in Terminal when Homebrew itself is missing.
    static let terminalScript = """
    #!/bin/bash
    set -e
    echo "Skrinsut: installing Homebrew, then ffmpeg."
    echo "You may be asked for your Mac password."
    echo
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    if [ -x /opt/homebrew/bin/brew ]; then eval "$(/opt/homebrew/bin/brew shellenv)"; fi
    if [ -x /usr/local/bin/brew ]; then eval "$(/usr/local/bin/brew shellenv)"; fi
    brew install ffmpeg
    echo
    echo "Done. You can close this window and return to Skrinsut."
    """

    @discardableResult
    static func writeTerminalScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Install ffmpeg for Skrinsut.command")
        try terminalScript.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    static func openTerminalInstaller() throws {
        let url = try writeTerminalScript()
        let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([url], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
    }
}
