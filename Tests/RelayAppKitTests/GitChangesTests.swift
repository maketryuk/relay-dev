import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("Git status")
struct GitStatusParserTests {
    /// Records are NUL-terminated; written here as the parser receives them.
    private func porcelain(_ records: [String]) -> String {
        records.map { $0 + "\0" }.joined()
    }

    @Test("A file edited but not staged is only in the unstaged list")
    func worktreeOnly() {
        let copy = GitStatusParser.parse(porcelainV2: porcelain([
            "# branch.head main",
            "1 .M N... 100644 100644 100644 8e7218f 8e7218f CHANGELOG.md",
        ]))
        #expect(copy.unstaged.map(\.path) == ["CHANGELOG.md"])
        #expect(copy.staged.isEmpty)
    }

    @Test("A file edited after being staged is in both lists")
    func stagedAndEditedAgain() {
        // The whole reason git reports two letters: the commit would carry one
        // version and the working tree would keep another.
        let copy = GitStatusParser.parse(porcelainV2: porcelain([
            "1 MM N... 100644 100644 100644 8e7218f 1111111 Sources/App.swift",
        ]))
        #expect(copy.staged.map(\.path) == ["Sources/App.swift"])
        #expect(copy.unstaged.map(\.path) == ["Sources/App.swift"])
    }

    @Test("An untracked file is listed as one, not as a modification")
    func untracked() {
        let copy = GitStatusParser.parse(porcelainV2: porcelain([
            "? Scripts/release.sh",
        ]))
        let change = try! #require(copy.unstaged.first)
        #expect(change.path == "Scripts/release.sh")
        #expect(change.worktree == .untracked)
        #expect(!change.isStaged)
    }

    @Test("A rename keeps where it came from, and adds no phantom file")
    func rename() {
        // The source path is a record of its own, right after the rename. Read
        // as an ordinary record it becomes a second, non-existent change —
        // which is what the extra step in the loop is there to prevent.
        let copy = GitStatusParser.parse(porcelainV2: porcelain([
            "2 R. N... 100644 100644 100644 8e7218f 8e7218f R100 Sources/New.swift",
            "Sources/Old.swift",
        ]))
        #expect(copy.changes.count == 1)
        let change = try! #require(copy.changes.first)
        #expect(change.path == "Sources/New.swift")
        #expect(change.originalPath == "Sources/Old.swift")
        #expect(GitStatusParser.paths(in: change) == "Sources/Old.swift → Sources/New.swift")
    }

    @Test("A path with a space in it survives")
    func spacedPath() {
        let copy = GitStatusParser.parse(porcelainV2: porcelain([
            "1 .M N... 100644 100644 100644 8e7218f 8e7218f docs/design notes.md",
        ]))
        #expect(copy.unstaged.map(\.path) == ["docs/design notes.md"])
    }

    @Test("A conflict is neither staged nor unstaged")
    func conflict() {
        // Offering to stage half a conflict is worse than offering nothing.
        let copy = GitStatusParser.parse(porcelainV2: porcelain([
            "u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 Sources/App.swift",
        ]))
        #expect(copy.conflicted.map(\.path) == ["Sources/App.swift"])
        #expect(copy.unstaged.isEmpty)
        #expect(copy.staged.isEmpty)
    }

    @Test("Branch headers are not files")
    func headersIgnored() {
        let copy = GitStatusParser.parse(porcelainV2: porcelain([
            "# branch.oid bb064b9",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +0 -0",
        ]))
        #expect(copy.isEmpty)
    }
}

@Suite("Unified diff")
struct DiffParserTests {
    /// Captured from `git diff` on this repository.
    private let sample = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index e7f2b42..e342eed 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -27,6 +27,8 @@ enum RelayCommand {
         case openSSHHosts
         case toggleRightSidebar
    -    case toggleLeftSidebar
    +    case increaseTerminalFontSize
    +    case decreaseTerminalFontSize

         case newShell
    @@ -59,3 +61,4 @@ enum RelayCommand {
         case .openSSHHosts: "SSH Hosts"
    +    case .increaseTerminalFontSize: "Increase Font Size"
    """

    @Test("Both hunks are read, and the preamble is not one of them")
    func hunks() {
        let diff = DiffParser.parse(unified: sample)
        #expect(diff.hunks.count == 2)
        #expect(diff.hunks.first?.header.hasPrefix("@@ -27,6 +27,8 @@") == true)
    }

    @Test("Added and removed lines are counted as git counts them")
    func counts() {
        let diff = DiffParser.parse(unified: sample)
        #expect(diff.insertions == 3)
        #expect(diff.deletions == 1)
    }

    @Test("A line carries the number it has on the side it exists on")
    func numbering() {
        // A deleted line has no number on the new side and an added line has
        // none on the old one; getting that backwards puts the gutter out by
        // one for everything below the first change.
        let diff = DiffParser.parse(unified: sample)
        let lines = try! #require(diff.hunks.first?.lines)
        let removed = try! #require(lines.first { $0.kind == .removed })
        let added = try! #require(lines.first { $0.kind == .added })
        #expect(removed.oldNumber == 29)
        #expect(removed.newNumber == nil)
        #expect(added.newNumber == 29)
        #expect(added.oldNumber == nil)
    }

    @Test("A hunk header states where both sides start")
    func hunkStart() {
        #expect(DiffParser.hunkStart(in: "@@ -12,7 +34,9 @@ func thing()").old == 12)
        #expect(DiffParser.hunkStart(in: "@@ -12,7 +34,9 @@ func thing()").new == 34)
        // A single-line hunk omits the count.
        #expect(DiffParser.hunkStart(in: "@@ -1 +1 @@").old == 1)
    }

    @Test("A missing final newline is a note, not a line of the file")
    func noNewlineMarker() {
        let diff = DiffParser.parse(unified: """
        @@ -1 +1 @@
        -old
        +new
        \\ No newline at end of file
        """)
        let lines = try! #require(diff.hunks.first?.lines)
        #expect(lines.last?.kind == .note)
        #expect(diff.insertions == 1)
    }

    @Test("A binary file says so instead of showing nothing")
    func binary() {
        let diff = DiffParser.parse(unified: """
        diff --git a/icon.png b/icon.png
        index 1111111..2222222 100644
        Binary files a/icon.png and b/icon.png differ
        """)
        #expect(diff.isBinary)
        #expect(!diff.isEmpty)
    }
}

@Suite("Diff sizes")
struct GitNumstatParserTests {
    private func numstat(_ records: [String]) -> String {
        records.map { $0 + "\0" }.joined()
    }

    @Test("Each file's two numbers are read against its path")
    func counts() {
        let counts = GitNumstatParser.parse(numstat: numstat([
            "63\t0\tCHANGELOG.md",
            "42\t10\tCLAUDE.md",
        ]))
        #expect(counts["CHANGELOG.md"]?.insertions == 63)
        #expect(counts["CHANGELOG.md"]?.deletions == 0)
        #expect(counts["CLAUDE.md"]?.deletions == 10)
    }

    @Test("A binary file counts as nothing rather than as a guess")
    func binary() {
        // git writes `-` where a count would be, meaning there are no lines to
        // count. Reading that as a number would invent a size.
        let counts = GitNumstatParser.parse(numstat: numstat(["-\t-\tResources/AppIcon.icns"]))
        #expect(counts["Resources/AppIcon.icns"]?.insertions == 0)
        #expect(counts["Resources/AppIcon.icns"]?.deletions == 0)
    }

    @Test("A path with a space is one field, not two")
    func spacedPath() {
        let counts = GitNumstatParser.parse(numstat: numstat(["1\t2\tdocs/design notes.md"]))
        #expect(counts["docs/design notes.md"]?.insertions == 1)
    }
}

@Suite("Hidden context")
struct DiffGapTests {
    @Test("A hunk knows where it sits and how long it is")
    func hunkRange() {
        let range = DiffParser.hunkRange(in: "@@ -27,6 +27,8 @@ enum RelayCommand {")
        #expect(range.old.start == 27)
        #expect(range.old.count == 6)
        #expect(range.new.start == 27)
        #expect(range.new.count == 8)
    }

    @Test("A one-line hunk has a length of one, not of none")
    func singleLineHunk() {
        // `@@ -1 +1 @@` omits the count, and reading the absence as zero makes
        // every gap below it one line too long.
        let range = DiffParser.hunkRange(in: "@@ -1 +1 @@")
        #expect(range.old.count == 1)
        #expect(range.new.count == 1)
    }

    @Test("The gap between two hunks is what was left out between them")
    func gapBetweenHunks() {
        let diff = DiffParser.parse(unified: """
        @@ -10,3 +10,4 @@
         one
        +two
         three
        @@ -40,2 +41,2 @@
        -four
        +five
        """)
        let first = try! #require(diff.hunks.first)
        let second = try! #require(diff.hunks.last)
        #expect(first.oldStart == 10)
        #expect(first.oldEnd == 13)
        #expect(second.oldStart - first.oldEnd == 27)
    }
}

@Suite("Review comments")
struct ReviewCommentTests {
    @Test("Each note names its own file, in file and line order")
    func transcript() {
        // Repeated on purpose: a block that says only "line 64" belongs to
        // whichever file was named last, and that is how a remark gets applied
        // to the wrong one.
        let text = ReviewCommentTranscript.compose([
            ReviewComment(projectID: ProjectID(rawValue: "p"), path: "b.swift", line: 12, code: "let x = 1", text: "rename this"),
            ReviewComment(projectID: ProjectID(rawValue: "p"), path: "a.swift", line: 90, code: "return nil", text: "why nil?"),
            ReviewComment(projectID: ProjectID(rawValue: "p"), path: "a.swift", line: 4, code: "import Foo", text: "unused"),
        ])
        #expect(text == """
        File: a.swift
        Line: 4
        User comment: "unused"

        File: a.swift
        Line: 90
        User comment: "why nil?"

        File: b.swift
        Line: 12
        User comment: "rename this"
        """)
    }

    @Test("A line that exists only in the old file is named without one")
    func withoutALineNumber() {
        let text = ReviewCommentTranscript.compose([
            ReviewComment(projectID: ProjectID(rawValue: "p"), path: "a.swift", line: nil, code: "old = true", text: "was this needed?"),
        ])
        #expect(text == """
        File: a.swift
        User comment: "was this needed?"
        """)
    }

    @Test("Nothing to say is nothing to send")
    func empty() {
        #expect(ReviewCommentTranscript.compose([]).isEmpty)
    }
}

@Suite("Branches")
struct GitBranchParserTests {
    /// Captured from `git for-each-ref` on this repository.
    private let sample = """
    refs/heads/main\tmain\t*\torigin/main\t
    refs/remotes/origin/HEAD\torigin\t \t\trefs/remotes/origin/main
    refs/remotes/origin/main\torigin/main\t \t\t
    """

    @Test("A remote's default pointer is not a branch")
    func symbolicRefIsSkipped() {
        // `refs/remotes/origin/HEAD` shortens to plain "origin", which read as
        // a local branch of that name and appeared in the list beside main.
        let branches = GitBranchParser.parse(sample)
        #expect(!branches.contains { $0.name == "origin" })
    }

    @Test("A remote branch already checked out is not offered twice")
    func trackedRemoteIsHidden() {
        let branches = GitBranchParser.parse(sample)
        #expect(branches.map(\.name) == ["main"])
        #expect(branches.first?.isCurrent == true)
        #expect(branches.first?.upstream == "origin/main")
    }

    @Test("An untracked remote branch is offered, and by its bare name")
    func remoteBranch() {
        let branches = GitBranchParser.parse("""
        refs/heads/main\tmain\t*\torigin/main\t
        refs/remotes/origin/feature\torigin/feature\t \t\t
        """)
        let remote = try! #require(branches.first { $0.isRemote })
        #expect(remote.name == "origin/feature")
        // `git switch feature` is what creates the local branch that follows it.
        #expect(remote.switchName == "feature")
    }
}
