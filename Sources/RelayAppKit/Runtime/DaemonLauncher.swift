import Foundation
import RelayProtocol

/// Finds and starts the session daemon.
enum DaemonLauncher {
    enum LaunchError: Error, LocalizedError {
        case executableNotFound

        var errorDescription: String? {
            "relay-daemon executable not found. Build it with `swift build --product relay-daemon`."
        }
    }

    /// Search order puts the bundled helper first so a shipped .app never picks
    /// up a stale binary from a developer's build directory.
    static func locateDaemon() -> URL? {
        if let override = ProcessInfo.processInfo.environment["RELAY_DAEMON_PATH"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "relay-daemon"),
           FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let neighbour = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("relay-daemon")
        if FileManager.default.isExecutableFile(atPath: neighbour.path) {
            return neighbour
        }
        return nil
    }

    static func isDaemonRunning() -> Bool {
        SocketProbe.isAlive(path: RelayPaths.socketURL.path)
    }

    /// Starts the daemon and waits for it to claim the socket.
    @discardableResult
    static func startIfNeeded(timeout: TimeInterval = 5) throws -> Bool {
        if isDaemonRunning() { return false }
        guard let executable = locateDaemon() else { throw LaunchError.executableNotFound }

        let process = Process()
        process.executableURL = executable
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isDaemonRunning() { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return isDaemonRunning()
    }
}

/// Connect-and-drop probe: the only reliable way to distinguish a live daemon
/// from a socket file left behind by a crash.
enum SocketProbe {
    static func isAlive(path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                connect(probe, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}
