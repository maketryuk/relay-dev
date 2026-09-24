import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

/// What the sidebar is given to draw before git has said which worktrees a
/// project has, and the moment it has.
@Suite("The sidebar while worktrees are read", .serialized)
@MainActor
struct WorktreeSidebarTests {
    @Test("The wait ends with the list already there, so the groups are drawn once")
    func waitEndsWithTheList() async throws {
        let directory = try TemporaryDirectory()
        let base = URL(fileURLWithPath: WorktreeMembership.canonical(directory.url.path))
        let root = base.appendingPathComponent("shop").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Git.run(["init", "-b", "main"], in: root)
        try Git.run(["config", "user.email", "tests@relay.local"], in: root)
        try Git.run(["config", "user.name", "Relay Tests"], in: root)
        try Git.run(["config", "commit.gpgsign", "false"], in: root)
        try "hello\n".write(toFile: root + "/file.txt", atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: root)
        try Git.run(["commit", "-m", "initial"], in: root)
        let linked = base.appendingPathComponent("worktrees/shop/fix-login").path
        try #require(GitWorktreeActions.add(branch: "fix-login", from: "main", at: linked, in: root) == nil)

        let model = AppModel(store: WorkspaceStore(url: base.appendingPathComponent("workspace.json")))
        model.addProject(at: URL(fileURLWithPath: root))
        let project = try #require(model.projects.first?.id)
        try await waitUntil { !model.isReadingWorktrees(in: project) }

        #expect(model.worktrees[project]?.count == 2)
        #expect(model.showsWorktrees(in: project))
    }

    @Test("A folder that is not a repository ends the wait as well")
    func notARepository() async throws {
        let directory = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: directory.url.appendingPathComponent("workspace.json")))
        model.addProject(at: directory.url)
        let project = try #require(model.projects.first?.id)

        try await waitUntil { !model.isReadingWorktrees(in: project) }
        #expect(!model.showsWorktrees(in: project))
    }

    @Test("The chat is never waited for: nothing asks git about it")
    func chatIsNeverRead() {
        let directory = try? TemporaryDirectory()
        let url = (directory?.url ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("workspace.json")
        let model = AppModel(store: WorkspaceStore(url: url))
        #expect(!model.isReadingWorktrees(in: .chat))
    }

    /// Waits for git to have answered rather than for a time to have passed;
    /// the bound only turns a git that never answers into a failure.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 750 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }
}
