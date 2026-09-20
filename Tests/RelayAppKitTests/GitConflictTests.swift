import Foundation
import Testing

@testable import RelayAppKit

@Suite("Reading a conflicted file")
struct GitConflictTests {
    private let twoWay = """
    context above
    <<<<<<< HEAD
    ours line
    =======
    theirs line
    >>>>>>> 7b8932e (two)
    context below
    """

    @Test("A conflict is read as the two sides and what they are called")
    func parsesTwoWay() {
        let file = GitConflictFile.parse(twoWay)
        #expect(file.hunks.count == 1)
        let hunk = file.hunks.first
        #expect(hunk?.ours == ["ours line"])
        #expect(hunk?.theirs == ["theirs line"])
        // git's own labels, not "yours" and "theirs": which side is which
        // reverses between a merge and a rebase.
        #expect(hunk?.ourLabel == "HEAD")
        #expect(hunk?.theirLabel == "7b8932e (two)")
        #expect(hunk?.base == nil)
    }

    @Test("The common ancestor is kept when the file carries one")
    func parsesDiff3() {
        let file = GitConflictFile.parse("""
        <<<<<<< HEAD
        mine
        ||||||| 5c3a49d
        original
        =======
        theirs
        >>>>>>> other
        """)
        #expect(file.hunks.first?.base == ["original"])
    }

    @Test("A file with no markers is not a conflict")
    func plainFile() {
        let file = GitConflictFile.parse("one\ntwo\n")
        #expect(!file.hasConflicts)
        // And comes through the panel untouched.
        #expect(MergeDocument.opened(file).text == "one\ntwo\n")
    }

    @Test("An unterminated block is left as the text it is")
    func unterminatedBlock() {
        // A file that is half a conflict is more likely to be a file about
        // conflict markers — this suite's own fixtures, for instance — than a
        // broken merge, and rewriting it would be worse than showing it.
        let text = "<<<<<<< HEAD\nours\n"
        let file = GitConflictFile.parse(text)
        #expect(!file.hasConflicts)
        #expect(MergeDocument.opened(file).text == text)
    }
}

@Suite("What the repository is in the middle of")
struct GitMergeStateTests {
    private func state(_ present: String...) -> GitMergeState {
        let existing = Set(present.map { "/repo/.git/\($0)" })
        return GitMergeStateReader.classify(gitDirectory: "/repo/.git") { existing.contains($0) }
    }

    @Test("Each operation is recognised by what it leaves behind")
    func recognisesOperations() {
        #expect(state("rebase-merge").operation == .rebase)
        #expect(state("rebase-apply").operation == .rebase)
        #expect(state("MERGE_HEAD").operation == .merge)
        #expect(state("CHERRY_PICK_HEAD").operation == .cherryPick)
        #expect(state("REVERT_HEAD").operation == .revert)
        #expect(state().operation == nil)
    }

    @Test("A stopped rebase is a rebase, whatever else it left lying about")
    func rebaseWins() {
        // A rebase that stops on a conflict leaves `MERGE_MSG` too, and
        // answering "merge" there would offer to commit where `--continue` is
        // what finishes it.
        #expect(state("rebase-merge", "MERGE_HEAD").operation == .rebase)
    }

    @Test("A worktree's git directory is the one its .git file points at")
    func worktreeGitDirectory() {
        #expect(GitMergeStateReader.pointedDirectory(
            inGitFile: "gitdir: /repo/.git/worktrees/spike\n",
            relativeTo: "/elsewhere"
        ) == "/repo/.git/worktrees/spike")
        // Relative, as git writes it for a worktree inside the repository.
        #expect(GitMergeStateReader.pointedDirectory(
            inGitFile: "gitdir: ../.git/worktrees/spike",
            relativeTo: "/repo/spike"
        ) == "/repo/spike/../.git/worktrees/spike")
        #expect(GitMergeStateReader.pointedDirectory(inGitFile: "nonsense", relativeTo: "/repo") == nil)
    }
}

@Suite("Naming the two sides")
@MainActor
struct GitMergeNamingTests {
    @Test("A rebase is not described as yours and theirs")
    func rebaseSaysWhatItIs() {
        // Rebasing replays your commits onto someone else's, so git's `ours`
        // is the upstream and git's `theirs` is your own work. A header that
        // said "mine" would be wrong here, which is the common case.
        #expect(GitMergeNaming.ours(operation: .rebase, label: "HEAD") == "Already rebased")
        #expect(GitMergeNaming.theirs(operation: .rebase, label: "85a186c (my edit)")
            == "Being rebased: 85a186c (my edit)")
    }

    @Test("A merge names what is coming in")
    func mergeNamesTheIncoming() {
        #expect(GitMergeNaming.ours(operation: .merge, label: "HEAD") == "Current branch")
        #expect(GitMergeNaming.theirs(operation: .merge, label: "origin/master") == "Merging in: origin/master")
    }

    @Test("With no operation and no label there is still something to show")
    func fallsBackToASide() {
        #expect(GitMergeNaming.ours(operation: nil, label: "") == "ours")
        #expect(GitMergeNaming.theirs(operation: nil, label: "  ") == "theirs")
        #expect(GitMergeNaming.ours(operation: nil, label: "HEAD") == "HEAD")
    }
}
