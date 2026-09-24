import Foundation

/// What becomes of a worktree's branch once its folder is gone.
///
/// Never call from the main thread.
extension GitWorktreeActions {
    /// What became of a removed worktree's branch, and the commit it was
    /// judged at.
    struct BranchSettlement: Equatable, Sendable {
        var outcome: BranchOutcome
        /// Where the branch pointed when it was judged, which is what a later
        /// deletion is held to; nil when there was no branch of Relay's.
        var head: String?
    }

    /// Settles the branch of a worktree that has just been removed.
    ///
    /// Git's `-d` goes first: it deletes a branch whose commits are all in
    /// HEAD or in its upstream, which is the rule people already know. When
    /// it refuses, the branch is measured against the remote's default
    /// branch — where a pull request lands, squashed, rebased or merged,
    /// whether or not the local `main` has been pulled since — fetched once
    /// if that is what it takes, and deleted when git proves nothing on it
    /// would be lost.
    ///
    /// Only a branch Relay created is ever deleted. One somebody else made is
    /// theirs, merged or not.
    static func settleBranch(of worktree: GitWorktree, in root: String) -> BranchSettlement {
        guard let branch = worktree.branch, createdBranch(branch, in: root),
              let head = GitBranchIntegration.commit("refs/heads/\(branch)", in: root)
        else { return BranchSettlement(outcome: .untouched, head: nil) }
        if deleteBranchIfMerged(branch, in: root) {
            return BranchSettlement(outcome: .deleted, head: head)
        }
        let kept = BranchSettlement(outcome: .keptUnmerged, head: head)
        // `-d` refuses a branch another worktree has checked out as well, and
        // that one is in use rather than unmerged.
        if list(at: root)?.contains(where: { $0.branch == branch }) == true {
            return BranchSettlement(outcome: .untouched, head: head)
        }
        guard let base = GitBranchIntegration.defaultBase(in: root) else { return kept }

        var integration = GitBranchIntegration.integration(of: head, into: base, in: root)
        if !integration.isIntegrated, GitBranchIntegration.refresh(base, in: root) {
            integration = GitBranchIntegration.integration(of: head, into: base, in: root)
        }
        guard integration.isIntegrated else { return kept }

        switch deleteBranch(branch, at: head, in: root) {
        case .deleted: return BranchSettlement(outcome: .deleted, head: head)
        case .checkedOut: return BranchSettlement(outcome: .untouched, head: head)
        case .moved, .failed: return kept
        }
    }

    /// What removing a worktree is going to do to its branch, worked out while
    /// the worktree is still there, so that the question asked first can say
    /// so rather than a toast after.
    struct BranchForecast: Equatable, Sendable {
        enum Fate: Equatable, Sendable {
            /// Relay made it and its work is already in the base: it goes too.
            case goes
            /// Relay made it, and this many of its commits have changes the
            /// base does not: it stays.
            case staysUnmerged(commits: Int)
            /// Somebody else made it, so it is theirs, merged or not.
            case staysNotRelays
            /// No branch: a detached `HEAD`, with this many commits no branch,
            /// tag or remote reaches, which go with the folder.
            case detached(strandedCommits: Int)
        }

        var fate: Fate
        var branch: String?
        /// Where the branch pointed when it was judged, which is what deleting
        /// it is held to.
        var head: String?
        /// What it was measured against; nil when there was nothing to
        /// measure it against, or no need.
        var base: String?
    }

    /// Judges a worktree's branch before the worktree is removed.
    ///
    /// The same rule `settleBranch` applies afterwards, asked in a form that
    /// works while the branch is still checked out: `-d` refuses a checked-out
    /// branch, so what it would have accepted — every commit already in the
    /// main checkout's `HEAD` — is asked of git directly.
    static func forecastBranch(of worktree: GitWorktree, in root: String) -> BranchForecast {
        guard let branch = worktree.branch else {
            let stranded = worktree.isPrunable ? 0 : countCommits(
                ["HEAD", "--not", "--branches", "--tags", "--remotes"],
                at: worktree.path
            ) ?? 0
            return BranchForecast(fate: .detached(strandedCommits: stranded))
        }
        guard createdBranch(branch, in: root) else {
            return BranchForecast(fate: .staysNotRelays, branch: branch)
        }
        guard let head = GitBranchIntegration.commit("refs/heads/\(branch)", in: root) else {
            return BranchForecast(fate: .staysUnmerged(commits: 0), branch: branch)
        }
        if GitActions.run(["merge-base", "--is-ancestor", head, "HEAD"], at: root) == nil {
            return BranchForecast(fate: .goes, branch: branch, head: head)
        }
        guard let base = GitBranchIntegration.defaultBase(in: root) else {
            let commits = unmergedCommits(of: head, against: "HEAD", in: root)
            return BranchForecast(fate: .staysUnmerged(commits: commits), branch: branch, head: head)
        }
        var integration = GitBranchIntegration.integration(of: head, into: base, in: root)
        if !integration.isIntegrated, GitBranchIntegration.refresh(base, in: root) {
            integration = GitBranchIntegration.integration(of: head, into: base, in: root)
        }
        let fate: BranchForecast.Fate = integration.isIntegrated
            ? .goes
            : .staysUnmerged(commits: unmergedCommits(of: head, against: base, in: root))
        return BranchForecast(fate: fate, branch: branch, head: head, base: base)
    }

    /// Does to a removed worktree's branch what `forecastBranch` said would be
    /// done. A branch that was to go goes only while it points where it did
    /// when it was judged; one that was to stay is not judged again, since
    /// the person agreed to the removal on the understanding that it stays.
    static func settleBranch(following forecast: BranchForecast, in root: String) -> BranchSettlement {
        switch forecast.fate {
        case .goes:
            guard let branch = forecast.branch, let head = forecast.head else {
                return BranchSettlement(outcome: .untouched, head: nil)
            }
            switch deleteBranch(branch, at: head, in: root) {
            case .deleted: return BranchSettlement(outcome: .deleted, head: head)
            case .checkedOut: return BranchSettlement(outcome: .untouched, head: head)
            case .moved, .failed: return BranchSettlement(outcome: .keptUnmerged, head: head)
            }
        case .staysUnmerged:
            return BranchSettlement(outcome: .keptUnmerged, head: forecast.head)
        case .staysNotRelays, .detached:
            return BranchSettlement(outcome: .untouched, head: nil)
        }
    }

    /// Commits whose changes `base` does not have, by `git cherry`, so that
    /// one a pull request picked counts as merged although its hash is not
    /// in the base.
    static func unmergedCommits(of head: String, against base: String, in root: String) -> Int {
        guard let output = Shell.run(
            GitWorkingCopyReader.executable,
            arguments: ["-C", root, "cherry", base, head],
            timeout: 15
        ) else {
            return countCommits(["\(base)..\(head)"], at: root) ?? 0
        }
        return output.split(separator: "\n").filter { $0.hasPrefix("+") }.count
    }

    private static func countCommits(_ revisions: [String], at place: String) -> Int? {
        Shell.run(
            GitWorkingCopyReader.executable,
            arguments: ["-C", place, "rev-list", "--count"] + revisions,
            timeout: 15
        ).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Why a branch was not deleted, or that it was.
    enum BranchDeletion: Equatable, Sendable {
        case deleted
        /// It no longer points where it did when it was judged: something
        /// was committed to it since, or it was moved, and nobody has looked.
        case moved
        /// A worktree has it checked out, which deleting it would leave on a
        /// branch that is not there.
        case checkedOut(path: String)
        /// Git refused, in its own words.
        case failed(String)
    }

    /// Deletes `branch` only while it still points at `head`.
    ///
    /// `update-ref -d` with the old value is git's compare-and-delete: the ref
    /// goes only if it is still `head`, so a commit made after the branch was
    /// judged — by an agent, or in a terminal — keeps it. What `branch -D`
    /// does besides is done here too: the branch's section of the config
    /// goes, Relay's mark with it.
    ///
    /// `update-ref` knows nothing of worktrees. A branch checked out in one
    /// is looked for before, and again after in case one was checked out in
    /// between, when the branch is put back where it was.
    static func deleteBranch(_ branch: String, at head: String, in root: String) -> BranchDeletion {
        let reference = "refs/heads/\(branch)"
        guard let worktrees = list(at: root) else { return .failed("git worktree list failed") }
        if let holder = worktrees.first(where: { $0.branch == branch }) {
            return .checkedOut(path: holder.path)
        }
        if let refusal = GitActions.run(["update-ref", "-d", reference, head], at: root) {
            if let now = GitBranchIntegration.commit(reference, in: root) {
                return now == head ? .failed(refusal) : .moved
            }
            // Deleted by something else already; its config is all that is
            // left of it.
        } else if let holder = list(at: root)?.first(where: { $0.branch == branch }) {
            _ = GitActions.run(["update-ref", reference, head, ""], at: root)
            return .checkedOut(path: holder.path)
        }
        _ = GitActions.run(["config", "--local", "--remove-section", "branch.\(branch)"], at: root)
        return .deleted
    }
}
