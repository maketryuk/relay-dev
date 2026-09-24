import Foundation
import RelayProtocol
import RelayUI
import Testing

@testable import RelayAppKit

@Suite("Removing a worktree without the sidebar", .serialized)
@MainActor
struct WorktreeRemovalTests {
    private func model() throws -> (AppModel, TemporaryDirectory) {
        let store = try TemporaryDirectory()
        return (AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json"))), store)
    }

    @Test("A project Relay does not know is refused, and nothing is touched")
    func unknownProject() async throws {
        let (model, store) = try model()
        let repository = try BranchTestRepository()
        let (worktree, folder) = try repository.worktree("spike")

        let removal = await model.performWorktreeRemoval(
            worktree,
            discardingChanges: false,
            in: ProjectID(rawValue: "nowhere")
        )

        #expect(removal.failure != nil)
        #expect(removal.branch == .untouched)
        #expect(FileManager.default.fileExists(atPath: folder))
        #expect(GitWorktreeActions.branchExists("spike", in: repository.root))
        _ = store
    }

    @Test("The main worktree is refused, and nothing is touched")
    func mainWorktree() async throws {
        let (model, store) = try model()
        let repository = try BranchTestRepository()
        model.addProject(at: URL(fileURLWithPath: repository.root))
        let project = try #require(model.projects.first)
        let main = try #require(GitWorktreeActions.list(at: repository.root)?.first)

        let removal = await model.performWorktreeRemoval(main, discardingChanges: false, in: project.id)

        #expect(removal.failure != nil)
        #expect(FileManager.default.fileExists(atPath: repository.root))
        _ = store
    }

    @Test("The folder goes, and so does a branch of Relay's with nothing on it")
    func removesFolderAndBranch() async throws {
        let (model, store) = try model()
        let repository = try BranchTestRepository()
        model.addProject(at: URL(fileURLWithPath: repository.root))
        let project = try #require(model.projects.first)
        let (worktree, folder) = try repository.worktree("idea")

        let removal = await model.performWorktreeRemoval(worktree, discardingChanges: false, in: project.id)

        #expect(removal == WorktreeRemoval(failure: nil, branch: .deleted))
        #expect(!FileManager.default.fileExists(atPath: folder))
        #expect(!GitWorktreeActions.branchExists("idea", in: repository.root))
        _ = store
    }

    @Test("Uncommitted work refuses the removal and keeps the branch")
    func refusalKeepsEverything() async throws {
        let (model, store) = try model()
        let repository = try BranchTestRepository()
        model.addProject(at: URL(fileURLWithPath: repository.root))
        let project = try #require(model.projects.first)
        let (worktree, folder) = try repository.worktree("draft")
        try "unsaved\n".write(toFile: folder + "/file.txt", atomically: true, encoding: .utf8)

        let removal = await model.performWorktreeRemoval(worktree, discardingChanges: false, in: project.id)

        #expect(removal.failure != nil)
        #expect(removal.branch == .untouched)
        #expect(FileManager.default.fileExists(atPath: folder))
        #expect(GitWorktreeActions.branchExists("draft", in: repository.root))
        _ = store
    }
}

@Suite("Deleting a branch its worktree's removal kept", .serialized)
@MainActor
struct KeptBranchTests {
    /// A project with a worktree whose branch has work on it that is merged
    /// nowhere, so that removing it keeps the branch.
    private func keptWork() throws -> (AppModel, ProjectID, BranchTestRepository, GitWorktree, TemporaryDirectory) {
        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        let repository = try BranchTestRepository()
        model.addProject(at: URL(fileURLWithPath: repository.root))
        let project = try #require(model.projects.first)
        let (worktree, folder) = try repository.worktree("work")
        try repository.commit("work\n", to: "work.txt", in: folder, message: "Work")
        return (model, project.id, repository, worktree, store)
    }

    @Test("A kept branch is reported with the commit it was judged at")
    func reportsHead() async throws {
        let (model, project, repository, worktree, store) = try keptWork()
        let head = try #require(repository.output(["rev-parse", "work"]))

        let removal = await model.performWorktreeRemoval(worktree, discardingChanges: false, in: project)

        #expect(removal == WorktreeRemoval(failure: nil, branch: .keptUnmerged, branchHead: head))
        _ = store
    }

    @Test("The toast that says a branch was kept deletes it")
    func deletesFromToast() async throws {
        let (model, project, repository, worktree, store) = try keptWork()

        model.removeWorktree(worktree, discardingChanges: false, in: project)
        for _ in 0 ..< 500 where model.toasts.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        let kept = try #require(model.toasts.first)
        #expect(kept.duration == nil)
        let action = try #require(kept.action)
        #expect(action.title == relayLocalized("Delete Branch"))

        action.handler()
        for _ in 0 ..< 500 where GitWorktreeActions.branchExists("work", in: repository.root) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!GitWorktreeActions.branchExists("work", in: repository.root))
        #expect(!GitWorktreeActions.createdBranch("work", in: repository.root))
        _ = store
    }

    @Test("A kept branch that moved since is not deleted")
    func movedBranchStays() async throws {
        let (model, project, repository, worktree, store) = try keptWork()
        let removal = await model.performWorktreeRemoval(worktree, discardingChanges: false, in: project)
        let judged = try #require(removal.branchHead)

        let (reopened, folder) = try repository.reopen("work")
        try repository.commit("more\n", to: "work.txt", in: folder, message: "More work")
        #expect(GitWorktreeActions.remove(reopened, force: false, in: repository.root) == nil)

        #expect(await model.performKeptBranchDeletion("work", at: judged, in: project) == .moved)
        #expect(repository.output(["log", "-1", "--format=%s", "work"]) == "More work")
        _ = store
    }
}

/// A repository on disk to make worktrees and merges in.
///
/// Everything git would otherwise take from the machine is set here — who
/// commits, whether commits are signed, how a merge may go — so a developer's
/// global configuration cannot change what a test sees, and a runner without
/// one is not missing anything.
struct BranchTestRepository {
    let directory: TemporaryDirectory
    /// The temporary directory, spelled the way git reports paths back.
    let base: URL
    /// The main checkout, on `main`.
    let root: String

    /// A repository of its own, or a clone of a bare `origin` when `remote`
    /// is set — which is what gives it an `origin/HEAD`.
    init(remote: Bool = false) throws {
        directory = try TemporaryDirectory()
        base = URL(fileURLWithPath: WorktreeMembership.canonical(directory.url.path))
        root = base.appendingPathComponent("shop").path
        let first = remote ? base.appendingPathComponent("seed").path : root
        try FileManager.default.createDirectory(atPath: first, withIntermediateDirectories: true)
        try Git.run(["init", "-b", "main"], in: first)
        try Self.configure(first)
        try "hello\n".write(toFile: first + "/file.txt", atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: first)
        try Git.run(["commit", "-m", "initial"], in: first)
        guard remote else { return }
        try Git.run(["clone", "--bare", first, origin], in: base.path)
        try Git.run(["clone", "--origin", "origin", origin, root], in: base.path)
        try Self.configure(root)
    }

    /// The bare repository standing in for the forge.
    var origin: String { base.appendingPathComponent("origin.git").path }

    static func configure(_ path: String) throws {
        try Git.run(["config", "user.email", "tests@relay.local"], in: path)
        try Git.run(["config", "user.name", "Relay Tests"], in: path)
        try Git.run(["config", "commit.gpgsign", "false"], in: path)
        try Git.run(["config", "merge.ff", "true"], in: path)
    }

    /// A worktree on a new branch Relay started from `main`, and its folder.
    func worktree(_ branch: String) throws -> (GitWorktree, String) {
        let folder = base.appendingPathComponent("worktrees/shop/\(branch)").path
        guard GitWorktreeActions.add(branch: branch, from: "main", at: folder, in: root) == nil else {
            throw Git.GitError.failed("worktree add \(branch)")
        }
        let listed = try #require(GitWorktreeActions.list(at: root)?.first { $0.path == folder })
        return (listed, folder)
    }

    /// A worktree on a branch that exists already, and its folder.
    func reopen(_ branch: String) throws -> (GitWorktree, String) {
        let folder = base.appendingPathComponent("worktrees/shop/\(branch)-again").path
        guard GitWorktreeActions.add(branch: branch, from: nil, at: folder, in: root) == nil else {
            throw Git.GitError.failed("worktree add \(branch)")
        }
        let listed = try #require(GitWorktreeActions.list(at: root)?.first { $0.path == folder })
        return (listed, folder)
    }

    /// Writes a file and commits it where `path` is checked out.
    func commit(_ contents: String, to file: String, in path: String, message: String) throws {
        let url = URL(fileURLWithPath: path).appendingPathComponent(file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try Git.run(["add", "--", file], in: path)
        try Git.run(["commit", "-m", message], in: path)
    }

    /// What git printed, without its last newline.
    func output(_ arguments: [String], in path: String? = nil) -> String? {
        Shell.run("/usr/bin/git", arguments: ["-C", path ?? root] + arguments, timeout: 15)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
