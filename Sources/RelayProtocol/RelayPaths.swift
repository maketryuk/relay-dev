import Foundation

/// Single source of truth for every on-disk location Relay uses.
///
/// Every path below is keyed by the flavour, so the development build and the
/// released one never meet in a file or on a socket.
public enum RelayPaths {
    public static var bundleIdentifier: String { RelayFlavour.current.bundleIdentifier }

    /// `~/.relay`, beside the directories the agents themselves keep.
    ///
    /// Application Support is where a document-based Mac app puts state the
    /// user never opens. Relay's is the opposite: a workspace file worth
    /// reading when something is wrong, a daemon log worth tailing, and a
    /// scratch directory an agent writes files into. All of that is reached
    /// from a terminal, and `~/Library/Application Support/Relay Dev` is a path
    /// nobody types twice.
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(RelayFlavour.current.supportDirectoryName, isDirectory: true)
    }

    /// Where the same files used to live. Read once, to move them.
    public static var legacySupportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(RelayFlavour.current.displayName, isDirectory: true)
    }

    public static var logsDirectory: URL {
        supportDirectory.appendingPathComponent("Logs", isDirectory: true)
    }

    /// The directory sessions that belong to no project run in.
    ///
    /// Created on demand rather than at launch: an install where nobody asks a
    /// question outside a project should have nothing here to find.
    public static var chatDirectory: URL {
        supportDirectory.appendingPathComponent("chat", isDirectory: true)
    }

    /// Where the worktrees Relay creates are checked out, one folder per
    /// repository. Created by git, with the first of them.
    public static var worktreesDirectory: URL {
        supportDirectory.appendingPathComponent("worktrees", isDirectory: true)
    }

    /// The browser pane's profile: cookies, local storage and the cache, so a
    /// development server signed into once stays signed in across launches.
    /// Chromium locks it while it runs, which is one more reason the
    /// development build must not share it.
    public static var browserDirectory: URL {
        supportDirectory.appendingPathComponent("browser", isDirectory: true)
    }

    /// Pictures of elements picked in design mode, kept where an agent handed
    /// the path can read them.
    public static var designDirectory: URL {
        supportDirectory.appendingPathComponent("design", isDirectory: true)
    }

    public static var chromiumLogURL: URL {
        logsDirectory.appendingPathComponent("chromium.log", isDirectory: false)
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

    /// Called once by whichever of the app and the daemon starts first, before
    /// either reads anything. Deliberately not part of `ensureDirectories`:
    /// that runs on every save, and a move is not something to reconsider
    /// hundreds of times a session.
    public static func migrateFromLegacyLocation() {
        migrateSupportDirectory(from: legacySupportDirectory, to: supportDirectory)
    }

    public static func ensureChatDirectory() throws -> URL {
        let directory = chatDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Moves an install written by an older build to where this one looks.
    ///
    /// File by file rather than the directory in one move, because the
    /// destination existing does not mean it holds anything: the daemon creates
    /// it when it opens its log, `swift test` creates it through the workspace
    /// store, and either can happen before the app has migrated a thing. A
    /// whole-directory move gives up in both cases and leaves the user with an
    /// empty workspace beside a full one.
    ///
    /// Anything already at the destination wins and is never overwritten — that
    /// is this build's own file, and the older install is by definition behind
    /// it. Silent about every failure: a move that cannot happen costs the
    /// user their settings, and refusing to start costs them the app.
    public static func migrateSupportDirectory(from legacy: URL, to current: URL) {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: legacy.path) else { return }
        try? manager.createDirectory(at: current, withIntermediateDirectories: true)
        for name in names {
            let destination = current.appendingPathComponent(name)
            guard !manager.fileExists(atPath: destination.path) else { continue }
            try? manager.moveItem(at: legacy.appendingPathComponent(name), to: destination)
        }
        // Only when there is nothing left to lose by it, so the old path stops
        // being somewhere to look.
        if (try? manager.contentsOfDirectory(atPath: legacy.path))?.isEmpty == true {
            try? manager.removeItem(at: legacy)
        }
    }
}
