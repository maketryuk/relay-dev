import Foundation
import Testing

@testable import RelayAppKit

@Suite("Git status parsing")
struct GitProbeTests {
    @Test("A clean branch tracking its upstream")
    func cleanBranch() {
        let output = """
        # branch.oid 8f2a1c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +0 -0
        """
        let status = GitProbe.parse(porcelainV2: output)
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(!status.isDirty)
        #expect(status.changedFiles == 0)
        #expect(status.ahead == 0)
        #expect(status.behind == 0)
    }

    @Test("Modified, added and untracked entries all count as changes")
    func dirtyWorkingTree() {
        let output = """
        # branch.head feature/login
        # branch.upstream origin/feature/login
        # branch.ab +2 -3
        1 .M N... 100644 100644 100644 abc def Sources/App.swift
        1 A. N... 000000 100644 100644 000 111 Sources/New.swift
        ? untracked.txt
        """
        let status = GitProbe.parse(porcelainV2: output)
        #expect(status.branch == "feature/login")
        #expect(status.isDirty)
        #expect(status.changedFiles == 3)
        #expect(status.ahead == 2)
        #expect(status.behind == 3)
    }

    @Test("A branch with no upstream reports no ahead/behind")
    func noUpstream() {
        let output = """
        # branch.oid abc123
        # branch.head local-only
        """
        let status = GitProbe.parse(porcelainV2: output)
        #expect(status.branch == "local-only")
        #expect(status.upstream == nil)
        #expect(status.ahead == 0)
        #expect(status.behind == 0)
    }

    @Test("A detached HEAD is reported verbatim")
    func detachedHead() {
        let status = GitProbe.parse(porcelainV2: "# branch.oid abc\n# branch.head (detached)\n")
        #expect(status.branch == "(detached)")
    }

    @Test("Branch names containing slashes and dots survive")
    func complexBranchName() {
        let status = GitProbe.parse(porcelainV2: "# branch.head release/v1.2.x\n")
        #expect(status.branch == "release/v1.2.x")
    }

    @Test("Empty output degrades gracefully instead of crashing")
    func emptyOutput() {
        let status = GitProbe.parse(porcelainV2: "")
        #expect(status.branch == "HEAD")
        #expect(!status.isDirty)
    }

    @Test("Malformed ahead/behind counters are ignored")
    func malformedAheadBehind() {
        let status = GitProbe.parse(porcelainV2: "# branch.head main\n# branch.ab garbage\n")
        #expect(status.ahead == 0)
        #expect(status.behind == 0)
    }

    @Test("A real repository is read through the git CLI")
    func readsRealRepository() throws {
        let directory = try TemporaryDirectory()
        let path = directory.url.path

        #expect(!GitProbe.isRepository(at: path))
        #expect(GitProbe.status(at: path) == nil)

        try Git.run(["init", "-b", "trunk"], in: path)
        try Git.run(["config", "user.email", "tests@relay.local"], in: path)
        try Git.run(["config", "user.name", "Relay Tests"], in: path)
        #expect(GitProbe.isRepository(at: path))

        try "hello".write(to: directory.url.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        let dirty = try #require(GitProbe.status(at: path))
        #expect(dirty.branch == "trunk")
        #expect(dirty.isDirty)
        #expect(dirty.changedFiles == 1)

        try Git.run(["add", "."], in: path)
        try Git.run(["commit", "-m", "initial"], in: path)
        let clean = try #require(GitProbe.status(at: path))
        #expect(!clean.isDirty)
        #expect(clean.changedFiles == 0)
    }
}

enum Git {
    static func run(_ arguments: [String], in path: String) throws {
        let output = Shell.run("/usr/bin/git", arguments: ["-C", path] + arguments, timeout: 15)
        if output == nil {
            throw GitError.failed(arguments.joined(separator: " "))
        }
    }

    enum GitError: Error { case failed(String) }
}

/// Self-cleaning temporary directory for filesystem-touching tests.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ contents: String, to relativePath: String) throws {
        let destination = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: destination, atomically: true, encoding: .utf8)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
