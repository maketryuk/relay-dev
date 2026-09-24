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
