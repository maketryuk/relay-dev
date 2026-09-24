import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

/// What the removal question says will happen to a branch, judged while its
/// worktree is still there, and removal doing that and nothing else.
@Suite("Saying what removing a worktree does to its branch", .serialized)
struct BranchForecastTests {
    private func work(_ branch: String, in repository: BranchTestRepository) throws -> (GitWorktree, String) {
        let (worktree, folder) = try repository.worktree(branch)
        try repository.commit("hello\nfrom \(branch)\n", to: "file.txt", in: folder, message: "Start \(branch)")
        try repository.commit("notes on \(branch)\n", to: "notes.txt", in: folder, message: "Finish \(branch)")
        return (worktree, folder)
    }

    @Test("A branch with nothing on it goes, though it is still checked out")
    func nothingOnIt() throws {
        let repository = try BranchTestRepository()
        let (worktree, _) = try repository.worktree("idea")
        #expect(GitWorktreeActions.forecastBranch(of: worktree, in: repository.root).fate == .goes)
    }

    @Test("A branch squashed on the forge goes, found by fetching the base")
    func squashedOnForge() throws {
        let repository = try BranchTestRepository(remote: true)
        let (worktree, _) = try work("feature", in: repository)
        try Git.run(["push", "origin", "feature:feature"], in: repository.root)
        try repository.onForge { forge in
            try Git.run(["merge", "--squash", "origin/feature"], in: forge)
            try Git.run(["commit", "-m", "Feature (#1)"], in: forge)
        }

        let forecast = GitWorktreeActions.forecastBranch(of: worktree, in: repository.root)
        #expect(forecast.fate == .goes)
        #expect(forecast.base == "origin/main")
    }

    @Test("A branch of which the forge took one commit stays, and says how many are left")
    func partlyPicked() throws {
        let repository = try BranchTestRepository(remote: true)
        let (worktree, _) = try work("feature", in: repository)
        try Git.run(["push", "origin", "feature:feature"], in: repository.root)
        try repository.onForge { forge in
            try Git.run(["cherry-pick", "origin/feature~1"], in: forge)
        }

        let forecast = GitWorktreeActions.forecastBranch(of: worktree, in: repository.root)
        #expect(forecast.fate == .staysUnmerged(commits: 1))
        #expect(forecast.base == "origin/main")
    }

    @Test("A branch with work nowhere else stays")
    func unmerged() throws {
        let repository = try BranchTestRepository()
        let (worktree, _) = try work("spike", in: repository)
        #expect(GitWorktreeActions.forecastBranch(of: worktree, in: repository.root).fate == .staysUnmerged(commits: 2))
    }

    @Test("Somebody else's branch stays, merged or not")
    func notRelays() throws {
        let repository = try BranchTestRepository()
        let folder = repository.base.appendingPathComponent("worktrees/shop/theirs").path
        try Git.run(["worktree", "add", "-b", "theirs", folder, "main"], in: repository.root)
        let worktree = try #require(GitWorktreeActions.list(at: repository.root)?.first { $0.path == folder })
        #expect(GitWorktreeActions.forecastBranch(of: worktree, in: repository.root).fate == .staysNotRelays)
    }

    @Test("A detached HEAD says how many commits nothing else holds")
    func detached() throws {
        let repository = try BranchTestRepository()
        let folder = repository.base.appendingPathComponent("worktrees/shop/spike").path
        try Git.run(["worktree", "add", "--detach", folder, "main"], in: repository.root)
        try repository.commit("spike\n", to: "spike.txt", in: folder, message: "Spike")
        let worktree = try #require(GitWorktreeActions.list(at: repository.root)?.first { $0.path == folder })
        #expect(
            GitWorktreeActions.forecastBranch(of: worktree, in: repository.root).fate
                == .detached(strandedCommits: 1)
        )
    }

    @Test("Removal deletes a branch it said would go")
    func goesAsForecast() throws {
        let repository = try BranchTestRepository()
        let (worktree, _) = try repository.worktree("idea")
        let forecast = GitWorktreeActions.forecastBranch(of: worktree, in: repository.root)
        #expect(GitWorktreeActions.remove(worktree, force: false, in: repository.root) == nil)

        #expect(GitWorktreeActions.settleBranch(following: forecast, in: repository.root).outcome == .deleted)
        #expect(!GitWorktreeActions.branchExists("idea", in: repository.root))
    }

    @Test("A branch committed to after the question keeps it, though it was to go")
    func movedSinceTheQuestion() throws {
        let repository = try BranchTestRepository()
        let (worktree, folder) = try repository.worktree("idea")
        let forecast = GitWorktreeActions.forecastBranch(of: worktree, in: repository.root)
        try repository.commit("late\n", to: "late.txt", in: folder, message: "A commit after the question")
        #expect(GitWorktreeActions.remove(worktree, force: false, in: repository.root) == nil)

        #expect(GitWorktreeActions.settleBranch(following: forecast, in: repository.root).outcome == .keptUnmerged)
        #expect(GitWorktreeActions.branchExists("idea", in: repository.root))
    }

    @Test("A branch it said would stay stays, and is not judged again")
    func staysAsForecast() throws {
        let repository = try BranchTestRepository()
        let (worktree, _) = try work("spike", in: repository)
        let forecast = GitWorktreeActions.forecastBranch(of: worktree, in: repository.root)
        #expect(GitWorktreeActions.remove(worktree, force: false, in: repository.root) == nil)

        let settled = GitWorktreeActions.settleBranch(following: forecast, in: repository.root)
        #expect(settled.outcome == .keptUnmerged)
        #expect(settled.head == forecast.head)
        #expect(GitWorktreeActions.branchExists("spike", in: repository.root))
    }
}

@Suite("Asking before removing a worktree", .serialized)
@MainActor
struct WorktreeRemovalRequestTests {
    @Test("The question waits for the branch to be judged, and removal keeps what it said it would")
    func questionCarriesTheForecast() async throws {
        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        let repository = try BranchTestRepository()
        model.addProject(at: URL(fileURLWithPath: repository.root))
        let project = try #require(model.projects.first)
        let (_, folder) = try repository.worktree("spike")
        try repository.commit("spike\n", to: "spike.txt", in: folder, message: "Spike")
        model.refreshGit(for: project.id)
        try await waitUntil { model.worktrees[project.id]?.contains { $0.path == folder } == true }
        let worktree = try #require(model.worktrees[project.id]?.first { $0.path == folder })

        model.requestWorktreeRemoval(worktree, in: project.id)
        #expect(model.worktreePendingRemoval == nil)
        try await waitUntil { model.worktreePendingRemoval != nil }
        let request = try #require(model.worktreePendingRemoval)
        #expect(request.forecast.fate == .staysUnmerged(commits: 1))
        #expect(model.worktreeRemovalsBeingChecked.isEmpty)

        let removal = await model.performWorktreeRemoval(
            worktree,
            discardingChanges: false,
            in: project.id,
            following: request.forecast
        )
        #expect(removal.branch == .keptUnmerged)
        #expect(!FileManager.default.fileExists(atPath: folder))
        #expect(GitWorktreeActions.branchExists("spike", in: repository.root))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 750 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }
}
