import Foundation
import Testing

@testable import RelayProtocol

@Suite("On-disk locations")
struct RelayPathsTests {
    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-paths-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Each build keeps its files in a dotted directory of its own")
    func directoryNamesDiffer() {
        // The socket carries the same distinction; these two must never name
        // the same place, or the development build reads the released app's
        // workspace.
        #expect(RelayFlavour.release.supportDirectoryName == ".relay")
        #expect(RelayFlavour.development.supportDirectoryName == ".relay-dev")
    }

    @Test("Everything the app writes is under the one directory")
    func pathsAgree() {
        let root = RelayPaths.supportDirectory
        #expect(RelayPaths.workspaceFileURL.deletingLastPathComponent() == root)
        #expect(RelayPaths.logsDirectory.deletingLastPathComponent() == root)
        #expect(RelayPaths.chatDirectory.deletingLastPathComponent() == root)
        #expect(RelayPaths.worktreesDirectory.deletingLastPathComponent() == root)
        #expect(root.deletingLastPathComponent() == FileManager.default.homeDirectoryForCurrentUser)
    }

    @Test("An install written by an older build is moved to where this one looks")
    func migratesLegacyDirectory() throws {
        let base = temporaryDirectory()
        let legacy = base.appendingPathComponent("Application Support/Relay", isDirectory: true)
        let current = base.appendingPathComponent(".relay", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let workspace = legacy.appendingPathComponent("workspace.json")
        try Data("{}".utf8).write(to: workspace)
        defer { try? FileManager.default.removeItem(at: base) }

        RelayPaths.migrateSupportDirectory(from: legacy, to: current)

        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("workspace.json").path))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("A directory created before the move still gets the files")
    func migratesIntoAnExistingDirectory() throws {
        // The daemon creates it when it opens its log, and `swift test` creates
        // it through the workspace store — so the destination existing says
        // nothing about whether anything is in it. Giving up here left the user
        // with an empty workspace beside a full one.
        let base = temporaryDirectory()
        let legacy = base.appendingPathComponent("Application Support/Relay", isDirectory: true)
        let current = base.appendingPathComponent(".relay", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy.appendingPathComponent("Logs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: legacy.appendingPathComponent("workspace.json"))
        defer { try? FileManager.default.removeItem(at: base) }

        RelayPaths.migrateSupportDirectory(from: legacy, to: current)

        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("workspace.json").path))
        #expect(FileManager.default.fileExists(atPath: current.appendingPathComponent("Logs").path))
        // Nothing left behind to look in.
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
    }

    @Test("A file this build already wrote is never overwritten by an older one")
    func doesNotClobberCurrent() throws {
        // Both the client and the daemon call this, and either can be first.
        // The loser of that race must leave the winner's files alone.
        let base = temporaryDirectory()
        let legacy = base.appendingPathComponent("Application Support/Relay", isDirectory: true)
        let current = base.appendingPathComponent(".relay", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: legacy.appendingPathComponent("workspace.json"))
        try Data("current".utf8).write(to: current.appendingPathComponent("workspace.json"))
        defer { try? FileManager.default.removeItem(at: base) }

        RelayPaths.migrateSupportDirectory(from: legacy, to: current)

        let kept = try String(contentsOf: current.appendingPathComponent("workspace.json"), encoding: .utf8)
        #expect(kept == "current")
        // And the older one stays where it is rather than being deleted with
        // the directory: it is the only copy of what it holds.
        #expect(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("workspace.json").path))
    }

    @Test("Nothing is created for an install that has no older one")
    func nothingToMigrate() {
        let base = temporaryDirectory()
        let legacy = base.appendingPathComponent("Application Support/Relay", isDirectory: true)
        let current = base.appendingPathComponent(".relay", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }

        RelayPaths.migrateSupportDirectory(from: legacy, to: current)

        #expect(!FileManager.default.fileExists(atPath: current.path))
    }
}
