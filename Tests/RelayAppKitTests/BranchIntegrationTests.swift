import Foundation
import Testing

@testable import RelayAppKit

@Suite("A removed worktree's branch", .serialized)
struct BranchSettlementTests {
    /// Two commits on a branch Relay started, in two files, the way a piece
    /// of work usually looks.
    private func finishedWork(_ branch: String, in repository: BranchTestRepository) throws -> (GitWorktree, String) {
        let (worktree, folder) = try repository.worktree(branch)
        try repository.commit("hello\nfrom \(branch)\n", to: "file.txt", in: folder, message: "Start \(branch)")
        try repository.commit("notes on \(branch)\n", to: "notes.txt", in: folder, message: "Finish \(branch)")
        return (worktree, folder)
    }

    private func removeFolder(_ worktree: GitWorktree, in repository: BranchTestRepository) throws {
        #expect(GitWorktreeActions.remove(worktree, force: false, in: repository.root) == nil)
    }

    @Test("A branch fast-forwarded into main goes")
    func fastForwarded() throws {
        let repository = try BranchTestRepository()
        let (worktree, _) = try finishedWork("feature", in: repository)
        try Git.run(["merge", "--ff-only", "feature"], in: repository.root)

        try removeFolder(worktree, in: repository)
        #expect(GitWorktreeActions.removeBranch(of: worktree, in: repository.root) == .deleted)
        #expect(!GitWorktreeActions.branchExists("feature", in: repository.root))
    }

    @Test("A branch squashed into main goes")
    func squashed() throws {
        let repository = try BranchTestRepository()
        let (worktree, _) = try finishedWork("feature", in: repository)
        try Git.run(["merge", "--squash", "feature"], in: repository.root)
        try Git.run(["commit", "-m", "Feature (#1)"], in: repository.root)

        try removeFolder(worktree, in: repository)
        #expect(GitWorktreeActions.removeBranch(of: worktree, in: repository.root) == .deleted)
        #expect(!GitWorktreeActions.branchExists("feature", in: repository.root))
        #expect(!GitWorktreeActions.createdBranch("feature", in: repository.root))
    }

    @Test("A branch squashed into main goes after main moved on in other files")
    func squashedThenMovedOn() throws {
        let repository = try BranchTestRepository()
        let (worktree, _) = try finishedWork("feature", in: repository)
        try Git.run(["merge", "--squash", "feature"], in: repository.root)
        try Git.run(["commit", "-m", "Feature (#1)"], in: repository.root)
        try repository.commit("later\n", to: "other.txt", in: repository.root, message: "Something else")

        try removeFolder(worktree, in: repository)
        #expect(GitWorktreeActions.removeBranch(of: worktree, in: repository.root) == .deleted)
    }

    @Test("A branch squashed into main goes after main wrote next to what it changed")
    func squashedThenEditedBeside() throws {
        // Every pull request here adds a line under the changelog's
        // `Unreleased`, straight after the one merged before it. Merging the
        // squashed branch into that main conflicts, though nothing on the
        // branch is missing from it.
        let repository = try BranchTestRepository()
        let changelog = "# Changelog\n\n## Unreleased\n\n- Older\n\n## 0.1\n"
        try repository.commit(changelog, to: "CHANGELOG.md", in: repository.root, message: "Changelog")
        let (worktree, folder) = try repository.worktree("feature")
        try repository.commit(
            changelog.replacingOccurrences(of: "- Older\n", with: "- Older\n- Feature\n"),
            to: "CHANGELOG.md", in: folder, message: "Feature"
        )
        try repository.commit("feature\n", to: "feature.txt", in: folder, message: "More feature")
        try Git.run(["merge", "--squash", "feature"], in: repository.root)
        try Git.run(["commit", "-m", "Feature (#1)"], in: repository.root)
        try repository.commit(
            changelog.replacingOccurrences(of: "- Older\n", with: "- Older\n- Feature\n- Next\n"),
            to: "CHANGELOG.md", in: repository.root, message: "Next (#2)"
        )

        try removeFolder(worktree, in: repository)
        #expect(GitWorktreeActions.removeBranch(of: worktree, in: repository.root) == .deleted)
    }

    @Test("A branch rebased onto main commit by commit goes")
    func rebased() throws {
        let repository = try BranchTestRepository()
        let (worktree, _) = try finishedWork("feature", in: repository)
        try repository.commit("meanwhile\n", to: "other.txt", in: repository.root, message: "Meanwhile")
        let commits = try #require(repository.output(["rev-list", "--reverse", "main..feature"]))
        try Git.run(["cherry-pick"] + commits.split(separator: "\n").map(String.init), in: repository.root)

        try removeFolder(worktree, in: repository)
        #expect(GitWorktreeActions.removeBranch(of: worktree, in: repository.root) == .deleted)
    }

    @Test("A branch with work main does not have is kept")
    func unmerged() throws {
        let repository = try BranchTestRepository()
        let (worktree, _) = try finishedWork("feature", in: repository)

        try removeFolder(worktree, in: repository)
        #expect(GitWorktreeActions.removeBranch(of: worktree, in: repository.root) == .keptUnmerged)
        #expect(GitWorktreeActions.branchExists("feature", in: repository.root))
        #expect(GitWorktreeActions.createdBranch("feature", in: repository.root))
    }

    @Test("A branch only half of which reached main is kept")
    func partlyIntegrated() throws {
        let repository = try BranchTestRepository()
        let (worktree, _) = try finishedWork("feature", in: repository)
        let commits = try #require(repository.output(["rev-list", "--reverse", "main..feature"]))
        let first = try #require(commits.split(separator: "\n").first)
        try Git.run(["cherry-pick", String(first)], in: repository.root)

        try removeFolder(worktree, in: repository)
        #expect(GitWorktreeActions.removeBranch(of: worktree, in: repository.root) == .keptUnmerged)
        #expect(GitWorktreeActions.branchExists("feature", in: repository.root))
    }

    @Test("Somebody else's branch is left alone, squashed into main or not")
    func notRelays() throws {
        let repository = try BranchTestRepository()
        try Git.run(["branch", "theirs"], in: repository.root)
        let folder = repository.base.appendingPathComponent("worktrees/shop/theirs").path
        #expect(GitWorktreeActions.add(branch: "theirs", from: "main", at: folder, in: repository.root) == nil)
        let worktree = try #require(GitWorktreeActions.list(at: repository.root)?.first { $0.path == folder })
        try repository.commit("theirs\n", to: "theirs.txt", in: folder, message: "Theirs")
        try Git.run(["merge", "--squash", "theirs"], in: repository.root)
        try Git.run(["commit", "-m", "Theirs (#1)"], in: repository.root)

        try removeFolder(worktree, in: repository)
        #expect(GitWorktreeActions.removeBranch(of: worktree, in: repository.root) == .untouched)
        #expect(GitWorktreeActions.branchExists("theirs", in: repository.root))
    }

    @Test("A branch checked out again somewhere else stays, and is not called unmerged")
    func checkedOutElsewhere() throws {
        let repository = try BranchTestRepository()
        let (worktree, _) = try finishedWork("feature", in: repository)
        try Git.run(["merge", "--squash", "feature"], in: repository.root)
        try Git.run(["commit", "-m", "Feature (#1)"], in: repository.root)
        try removeFolder(worktree, in: repository)
        try Git.run(["switch", "feature"], in: repository.root)

        #expect(GitWorktreeActions.removeBranch(of: worktree, in: repository.root) == .untouched)
        #expect(GitWorktreeActions.branchExists("feature", in: repository.root))
        #expect(repository.output(["symbolic-ref", "--short", "HEAD"]) == "feature")
    }

    @Test("A branch merged on the forge goes while the local main is still behind")
    func mergedIntoOriginWhileMainIsBehind() throws {
        let repository = try BranchTestRepository(remote: true)
        let (worktree, _) = try finishedWork("feature", in: repository)
        try Git.run(["push", "origin", "feature:feature"], in: repository.root)
        try repository.onForge { forge in
            try Git.run(["merge", "--no-ff", "-m", "Merge pull request #1", "origin/feature"], in: forge)
        }
        try Git.run(["fetch", "origin"], in: repository.root)

        try removeFolder(worktree, in: repository)
        #expect(GitWorktreeActions.removeBranch(of: worktree, in: repository.root) == .deleted)
        #expect(!GitWorktreeActions.branchExists("feature", in: repository.root))
    }

    @Test("A branch squashed on the forge goes, though nothing had fetched it yet")
    func squashedOnForgeBeforeAnyFetch() throws {
        let repository = try BranchTestRepository(remote: true)
        let (worktree, _) = try finishedWork("feature", in: repository)
        try Git.run(["push", "origin", "feature:feature"], in: repository.root)
        try repository.onForge { forge in
            try Git.run(["merge", "--squash", "origin/feature"], in: forge)
            try Git.run(["commit", "-m", "Feature (#1)"], in: forge)
        }

        try removeFolder(worktree, in: repository)
        #expect(GitWorktreeActions.removeBranch(of: worktree, in: repository.root) == .deleted)
        #expect(!GitWorktreeActions.branchExists("feature", in: repository.root))
    }
}

extension BranchTestRepository {
    /// Does to `origin`'s `main` what a forge does when a pull request is
    /// merged: in a clone of its own, pushed back when `body` is done.
    func onForge(_ body: (String) throws -> Void) throws {
        let forge = base.appendingPathComponent("forge").path
        if !FileManager.default.fileExists(atPath: forge) {
            try Git.run(["clone", "--origin", "origin", origin, forge], in: base.path)
            try Self.configure(forge)
        }
        try Git.run(["fetch", "origin"], in: forge)
        try Git.run(["reset", "--hard", "origin/main"], in: forge)
        try body(forge)
        try Git.run(["push", "origin", "HEAD:main"], in: forge)
    }
}

@Suite("Measuring a branch against the base", .serialized)
struct BranchIntegrationTests {
    private func integration(_ branch: String, in repository: BranchTestRepository) -> BranchIntegration {
        GitBranchIntegration.integration(of: branch, into: "main", in: repository.root)
    }

    private func work(_ branch: String, in repository: BranchTestRepository) throws -> String {
        let (_, folder) = try repository.worktree(branch)
        try repository.commit("hello\nfrom \(branch)\n", to: "file.txt", in: folder, message: "Start \(branch)")
        try repository.commit("notes on \(branch)\n", to: "notes.txt", in: folder, message: "Finish \(branch)")
        return folder
    }

    @Test("A branch whose commits are all in the base is merged")
    func merged() throws {
        let repository = try BranchTestRepository()
        _ = try work("feature", in: repository)
        try Git.run(["merge", "--no-ff", "-m", "Merge feature", "feature"], in: repository.root)
        #expect(integration("feature", in: repository) == .merged)
    }

    @Test("A branch with nothing on it is merged")
    func empty() throws {
        let repository = try BranchTestRepository()
        _ = try repository.worktree("idea")
        #expect(integration("idea", in: repository) == .merged)
    }

    @Test("A branch squashed into the base is squash-merged")
    func squashed() throws {
        let repository = try BranchTestRepository()
        _ = try work("feature", in: repository)
        try Git.run(["merge", "--squash", "feature"], in: repository.root)
        try Git.run(["commit", "-m", "Feature (#1)"], in: repository.root)
        #expect(integration("feature", in: repository) == .squashMerged)
    }

    @Test("A branch whose commits were picked onto the base one by one is squash-merged")
    func cherryPicked() throws {
        let repository = try BranchTestRepository()
        _ = try work("feature", in: repository)
        try repository.commit("meanwhile\n", to: "other.txt", in: repository.root, message: "Meanwhile")
        let commits = try #require(repository.output(["rev-list", "--reverse", "main..feature"]))
        try Git.run(["cherry-pick"] + commits.split(separator: "\n").map(String.init), in: repository.root)
        #expect(integration("feature", in: repository) == .squashMerged)
    }

    @Test("A squash is still found after the base changed the same lines again")
    func squashedThenRewritten() throws {
        let repository = try BranchTestRepository()
        _ = try work("feature", in: repository)
        try Git.run(["merge", "--squash", "feature"], in: repository.root)
        try Git.run(["commit", "-m", "Feature (#1)"], in: repository.root)
        try repository.commit(
            "hello\nfrom feature, reworded\n", to: "file.txt", in: repository.root, message: "Reword"
        )
        #expect(repository.output(["merge-tree", "--write-tree", "main", "feature"]) == nil, "the merge conflicts")
        #expect(integration("feature", in: repository) == .squashMerged)
    }

    @Test("A detached worktree's commit is measured by its hash")
    func detachedCommit() throws {
        let repository = try BranchTestRepository()
        let folder = repository.base.appendingPathComponent("worktrees/shop/spike").path
        try Git.run(["worktree", "add", "--detach", folder, "main"], in: repository.root)
        try repository.commit("spike\n", to: "spike.txt", in: folder, message: "Spike")
        let head = try #require(repository.output(["rev-parse", "HEAD"], in: folder))
        #expect(integration(head, in: repository) == .unmerged)

        try Git.run(["merge", "--squash", head], in: repository.root)
        try Git.run(["commit", "-m", "Spike (#1)"], in: repository.root)
        #expect(integration(head, in: repository) == .squashMerged)
        #expect(integration(String(head.prefix(12)), in: repository) == .squashMerged)
    }

    @Test("A branch with work of its own is unmerged")
    func unmerged() throws {
        let repository = try BranchTestRepository()
        _ = try work("feature", in: repository)
        #expect(integration("feature", in: repository) == .unmerged)
    }

    @Test("A branch squashed in and then given one more commit is unmerged")
    func movedOnAfterSquash() throws {
        let repository = try BranchTestRepository()
        let folder = try work("feature", in: repository)
        try Git.run(["merge", "--squash", "feature"], in: repository.root)
        try Git.run(["commit", "-m", "Feature (#1)"], in: repository.root)
        try repository.commit("one more thing\n", to: "notes.txt", in: folder, message: "Afterthought")
        #expect(integration("feature", in: repository) == .unmerged)
    }

    @Test("A branch half of which is in the base is unmerged")
    func partlyIntegrated() throws {
        let repository = try BranchTestRepository()
        _ = try work("feature", in: repository)
        try repository.commit("meanwhile\n", to: "other.txt", in: repository.root, message: "Meanwhile")
        let commits = try #require(repository.output(["rev-list", "--reverse", "main..feature"]))
        let first = try #require(commits.split(separator: "\n").first)
        try Git.run(["cherry-pick", String(first)], in: repository.root)
        #expect(integration("feature", in: repository) == .unmerged)
    }

    @Test("A base or a branch that does not exist gives no answer")
    func nothingToMeasure() throws {
        let repository = try BranchTestRepository()
        _ = try work("feature", in: repository)
        let nowhere = GitBranchIntegration.integration(of: "feature", into: "refs/heads/nowhere", in: repository.root)
        #expect(nowhere == .unknown)
        #expect(integration("nowhere", in: repository) == .unknown)
    }
}

@Suite("What finished work is measured against", .serialized)
struct DefaultBaseTests {
    @Test("The remote's default branch, as the clone was told it")
    func remoteHead() throws {
        let repository = try BranchTestRepository(remote: true)
        #expect(GitBranchIntegration.defaultBase(in: repository.root) == "origin/main")
    }

    @Test("Whatever the remote's default branch is called")
    func remoteHeadElsewhere() throws {
        let repository = try BranchTestRepository(remote: true)
        try Git.run(["push", "origin", "main:develop"], in: repository.root)
        try Git.run(["remote", "set-head", "origin", "develop"], in: repository.root)
        #expect(GitBranchIntegration.defaultBase(in: repository.root) == "origin/develop")
    }

    @Test("The remote's main when nothing says which branch is its default")
    func remoteWithoutHead() throws {
        let repository = try BranchTestRepository()
        let bare = repository.base.appendingPathComponent("origin.git").path
        try Git.run(["clone", "--bare", repository.root, bare], in: repository.base.path)
        try Git.run(["remote", "add", "origin", bare], in: repository.root)
        try Git.run(["fetch", "origin"], in: repository.root)
        try Git.run(["remote", "set-head", "origin", "--delete"], in: repository.root)
        #expect(GitBranchIntegration.defaultBase(in: repository.root) == "origin/main")
    }

    @Test("The local main when there is no remote")
    func localMain() throws {
        let repository = try BranchTestRepository()
        #expect(GitBranchIntegration.defaultBase(in: repository.root) == "main")
    }

    @Test("Nothing when there is neither")
    func none() throws {
        let repository = try BranchTestRepository()
        try Git.run(["branch", "-m", "main", "trunk"], in: repository.root)
        #expect(GitBranchIntegration.defaultBase(in: repository.root) == nil)
    }
}

@Suite("Deleting a branch only as it was judged", .serialized)
struct GuardedBranchDeletionTests {
    @Test("A branch that moved after it was judged is not deleted")
    func moved() throws {
        let repository = try BranchTestRepository()
        let (worktree, folder) = try repository.worktree("work")
        try repository.commit("judged\n", to: "file.txt", in: folder, message: "Judged")
        let judged = try #require(repository.output(["rev-parse", "work"]))
        try repository.commit("later\n", to: "file.txt", in: folder, message: "Committed after the check")
        #expect(GitWorktreeActions.remove(worktree, force: false, in: repository.root) == nil)

        #expect(GitWorktreeActions.deleteBranch("work", at: judged, in: repository.root) == .moved)
        #expect(repository.output(["log", "-1", "--format=%s", "work"]) == "Committed after the check")
        #expect(GitWorktreeActions.createdBranch("work", in: repository.root))
    }

    @Test("A branch a worktree has checked out is not deleted")
    func checkedOut() throws {
        let repository = try BranchTestRepository()
        let (_, folder) = try repository.worktree("busy")
        let head = try #require(repository.output(["rev-parse", "busy"]))

        #expect(GitWorktreeActions.deleteBranch("busy", at: head, in: repository.root) == .checkedOut(path: folder))
        #expect(GitWorktreeActions.branchExists("busy", in: repository.root))
    }

    @Test("A deleted branch takes its config with it, Relay's mark included")
    func configGoes() throws {
        let repository = try BranchTestRepository()
        let (worktree, folder) = try repository.worktree("idea")
        try repository.commit("idea\n", to: "idea.txt", in: folder, message: "Idea")
        let head = try #require(repository.output(["rev-parse", "idea"]))
        #expect(GitWorktreeActions.remove(worktree, force: false, in: repository.root) == nil)

        #expect(GitWorktreeActions.deleteBranch("idea", at: head, in: repository.root) == .deleted)
        #expect(!GitWorktreeActions.branchExists("idea", in: repository.root))
        #expect(repository.output(["config", "--local", "--get-regexp", "^branch\\.idea\\."]) == nil)
    }
}

@Suite("Reading which files each commit changed")
struct ChangedFilesParserTests {
    @Test("Each commit's files, the first one after the newline under its hash")
    func parsesLog() {
        // Captured from `git log -z --name-only --format=%x01%H`.
        let log = "\u{01}6a8a6ed290f9549dc96dfd2debd40478605d1c12\0\nCHANGELOG.md\0"
            + "\u{01}1056b4ba637376b6095229967d0254ab96d8a165\0\nCHANGELOG.md\0docs/read me.md\0f2.txt\0"
        let parsed = GitBranchIntegration.changedFiles(log: log)
        #expect(parsed.map(\.commit) == [
            "6a8a6ed290f9549dc96dfd2debd40478605d1c12",
            "1056b4ba637376b6095229967d0254ab96d8a165",
        ])
        #expect(parsed.map(\.files) == [["CHANGELOG.md"], ["CHANGELOG.md", "docs/read me.md", "f2.txt"]])
    }

    @Test("Nothing read from nothing")
    func empty() {
        #expect(GitBranchIntegration.changedFiles(log: "").isEmpty)
    }
}
