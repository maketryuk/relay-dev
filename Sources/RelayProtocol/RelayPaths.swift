import Foundation

/// Single source of truth for every on-disk location Relay uses.
public enum RelayPaths {
    public static let bundleIdentifier = "com.maketryuk.relay"

    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Relay", isDirectory: true)
    }

    public static var logsDirectory: URL {
        supportDirectory.appendingPathComponent("Logs", isDirectory: true)
    }

    /// Unix domain socket paths are capped at 104 bytes, so the socket lives in
    /// the sandbox-friendly temporary directory keyed by UID instead of inside
    /// Application Support.
    public static var socketURL: URL {
        URL(fileURLWithPath: "/tmp/relay-\(getuid()).sock")
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
