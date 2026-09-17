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
        let hunk = try? #require(file.hunks.first)
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

    @Test("Answering a conflict leaves the rest of the file alone")
    func resolvesOneSide() {
        let file = GitConflictFile.parse(twoWay)
        let ours = file.resolved(with: [0: .ours])
        #expect(ours == """
        context above
        ours line
        context below
        """)
        #expect(file.resolved(with: [0: .theirs]) == """
        context above
        theirs line
        context below
        """)
        #expect(file.resolved(with: [0: .both]) == """
        context above
        ours line
        theirs line
        context below
        """)
    }

    @Test("A conflict nobody has answered keeps its markers")
    func unansweredConflictsSurvive() {
        // Half a resolution must stay something git refuses to commit, rather
        // than quietly becoming one side.
        let file = GitConflictFile.parse(twoWay)
        #expect(file.resolved(with: [:]) == twoWay)
    }

    @Test("Several conflicts are answered one at a time")
    func severalHunks() {
        let file = GitConflictFile.parse("""
        <<<<<<< HEAD
        a-ours
        =======
        a-theirs
        >>>>>>> other
        middle
        <<<<<<< HEAD
        b-ours
        =======
        b-theirs
        >>>>>>> other
        """)
        #expect(file.hunks.count == 2)
        #expect(file.resolved(with: [0: .theirs, 1: .ours]) == """
        a-theirs
        middle
        b-ours
        """)
    }

    @Test("A file with no markers is not a conflict")
    func plainFile() {
        let file = GitConflictFile.parse("one\ntwo\n")
        #expect(!file.hasConflicts)
        #expect(file.resolved(with: [:]) == "one\ntwo\n")
    }

    @Test("An unterminated block is left as the text it is")
    func unterminatedBlock() {
        // A file that is half a conflict is more likely to be a file about
        // conflict markers — this suite's own fixtures, for instance — than a
        // broken merge, and rewriting it would be worse than showing it.
        let text = "<<<<<<< HEAD\nours\n"
        let file = GitConflictFile.parse(text)
        #expect(!file.hasConflicts)
        #expect(file.resolved(with: [:]) == text)
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
