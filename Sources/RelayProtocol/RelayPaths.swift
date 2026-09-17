import Foundation

/// Single source of truth for every on-disk location Relay uses.
///
/// Every path below is keyed by the flavour, so the development build and the
/// released one never meet in a file or on a socket.
public enum RelayPaths {
    public static var bundleIdentifier: String { RelayFlavour.current.bundleIdentifier }

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(RelayFlavour.current.displayName, isDirectory: true)
    }

    public static var logsDirectory: URL {
        supportDirectory.appendingPathComponent("Logs", isDirectory: true)
    }

    /// Unix domain socket paths are capped at 104 bytes, so the socket lives in
    /// the sandbox-friendly temporary directory keyed by UID instead of inside
    /// Application Support.
    public static var socketURL: URL {
        URL(fileURLWithPath: "/tmp/\(RelayFlavour.current.socketName)-\(getuid()).sock")
    }

    public static var workspaceFileURL: URL {
        supportDirectory.appendingPathComponent("workspace.json", isDirectory: false)
    }

    public static var daemonLogURL: URL {
        logsDirectory.appendingPathComponent("daemon.log", isDirectory: false)
    }

    public static func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }
}
