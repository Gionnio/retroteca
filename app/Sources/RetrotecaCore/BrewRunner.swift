// Adapted from Upgrady (MIT, © 2026 Gionnio).
import Foundation

/// Runs brew commands for a GUI app.
public struct BrewRunner: Sendable {
    /// The `brew` executable.
    public let brewURL: URL
    /// A script that asks for the administrator password with a dialog (`sudo -A`).
    public var passwordPromptScript: URL?

    public init(brewURL: URL, passwordPromptScript: URL? = nil) {
        self.brewURL = brewURL
        self.passwordPromptScript = passwordPromptScript
    }

    public struct Output: Sendable {
        public let status: Int32
        public let text: String
        /// Brew stopped making progress and was stopped by the watchdog.
        public var stalled = false
        public var succeeded: Bool { status == 0 && !stalled }

        /// macOS refused to let brew change an app: the "App Management" permission is missing.
        public var lacksAppManagementPermission: Bool { text.contains("Operation not permitted") }
    }

    /// Runs brew and waits for it. `onOutput` receives output as it arrives.
    ///
    /// With a `watchdog`, brew is stopped when it shows no sign of life (no output, no download progress)
    /// for the watchdog's timeout: a download left hanging, for example after the Mac slept, would otherwise
    /// keep the operation running for hours.
    public func run(_ arguments: [String], includeErrors: Bool = true, watchdog: BrewWatchdog? = nil,
                    onOutput: (@Sendable (String) -> Void)? = nil) async -> Output {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = brewURL
            process.arguments = arguments
            process.environment = environment()
            process.standardInput = FileHandle.nullDevice

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = includeErrors ? pipe : FileHandle.nullDevice

            let collected = OutputBuffer()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                watchdog?.touch()
                collected.append(data)
                onOutput?(String(decoding: data, as: UTF8.self))
            }
            process.terminationHandler = { process in
                watchdog?.stop()
                pipe.fileHandleForReading.readabilityHandler = nil
                // After a stall a leftover child (curl) may still hold the pipe open: do not wait for it.
                let rest = watchdog?.fired == true ? Data() : pipe.fileHandleForReading.readDataToEndOfFile()
                if !rest.isEmpty {
                    collected.append(rest)
                    onOutput?(String(decoding: rest, as: UTF8.self))
                }
                var output = Output(status: process.terminationStatus, text: collected.text)
                output.stalled = watchdog?.fired ?? false
                continuation.resume(returning: output)
            }
            do {
                try process.run()
                let pid = process.processIdentifier
                watchdog?.start {
                    // brew runs the download in child processes: stop them too, then brew itself.
                    Self.signalChildren(of: pid, "TERM")
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                        guard process.isRunning else { return }
                        Self.signalChildren(of: pid, "KILL")
                        kill(pid, SIGKILL)
                    }
                }
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: Output(status: -1, text: error.localizedDescription))
            }
        }
    }

    /// Sends a signal to the children of a process (and theirs), with `pkill -P`.
    private static func signalChildren(of pid: Int32, _ signal: String) {
        let children = Process()
        children.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        children.arguments = ["-P", String(pid)]
        let pipe = Pipe()
        children.standardOutput = pipe
        children.standardError = FileHandle.nullDevice
        guard (try? children.run()) != nil else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        children.waitUntilExit()
        for child in String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap({ Int32($0) }) {
            signalChildren(of: child, signal)
            kill(child, signal == "KILL" ? SIGKILL : SIGTERM)
        }
    }

    private func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let bin = brewURL.deletingLastPathComponent().path
        environment["PATH"] = ([bin, "/usr/bin", "/bin", "/usr/sbin", "/sbin"] + [environment["PATH"] ?? ""]).joined(separator: ":")
        environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
        environment["HOMEBREW_NO_ENV_HINTS"] = "1"
        environment["HOMEBREW_NO_COLOR"] = "1"
        environment["NONINTERACTIVE"] = "1"
        if let passwordPromptScript { environment["SUDO_ASKPASS"] = passwordPromptScript.path }
        return environment
    }

    /// The Homebrew installation, Apple Silicon or Intel prefix.
    public static func findBrew() -> URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Writes the password prompt script used by `sudo -A` and returns its location.
    public static func installPasswordPrompt(in directory: URL, message: String) -> URL? {
        let safe = message.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\\", with: "")
        let script = """
        #!/bin/sh
        exec /usr/bin/osascript -e 'display dialog "\(safe)" with title "Retroteca" default answer "" with hidden answer with icon caution' -e 'text returned of result'
        """
        let url = directory.appendingPathComponent("password-prompt.sh")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }
}

/// Stops a brew command that shows no sign of life for `timeout` seconds.
public final class BrewWatchdog: @unchecked Sendable {
    public let timeout: TimeInterval
    private let lock = NSLock()
    private var lastActivity = Date()
    private var timer: DispatchSourceTimer?
    private var didFire = false

    public init(timeout: TimeInterval) {
        self.timeout = timeout
    }

    /// Brew is alive: output arrived or the download grew.
    public func touch() { lock.withLock { lastActivity = Date() } }

    /// Whether the command was stopped for inactivity.
    public var fired: Bool { lock.withLock { didFire } }

    func start(onStall: @escaping @Sendable () -> Void) {
        touch()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        let tick = min(15, max(timeout / 4, 0.5))
        timer.schedule(deadline: .now() + tick, repeating: tick)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let stalled = self.lock.withLock { () -> Bool in
                guard !self.didFire, Date().timeIntervalSince(self.lastActivity) > self.timeout else { return false }
                self.didFire = true
                return true
            }
            if stalled { onStall() }
        }
        lock.withLock { self.timer = timer }
        timer.resume()
    }

    func stop() {
        lock.withLock {
            timer?.cancel()
            timer = nil
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) { lock.withLock { data.append(more) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
