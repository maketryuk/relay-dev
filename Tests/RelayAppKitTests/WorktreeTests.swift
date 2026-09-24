import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("Reading git's list of worktrees")
struct GitWorktreeParserTests {
    /// Captured from `git worktree list --porcelain`, one of each kind.
    static let listing = """
    worktree /Users/me/code/shop
    HEAD 1111111111111111111111111111111111111111
    branch refs/heads/main

    worktree /Users/me/.relay/worktrees/shop/fix-login
    HEAD 2222222222222222222222222222222222222222
    branch refs/heads/fix/login

    worktree /Users/me/code/shop/.claude/worktrees/spike
    HEAD 3333333333333333333333333333333333333333
    detached

    worktree /Users/me/.relay/worktrees/shop/pinned
    HEAD 4444444444444444444444444444444444444444
    branch refs/heads/pinned
    locked on a disk that is not always plugged in

    worktree /Users/me/.relay/worktrees/shop/gone
    HEAD 5555555555555555555555555555555555555555
    branch refs/heads/gone
    prunable gitdir file points to non-existent location

    """

    @Test("Every entry is read, the first as the main worktree")
    func readsEveryEntry() {
        let worktrees = GitWorktreeParser.parse(porcelain: Self.listing)
        #expect(worktrees.map(\.path) == [
            "/Users/me/code/shop",
            "/Users/me/.relay/worktrees/shop/fix-login",
            "/Users/me/code/shop/.claude/worktrees/spike",
            "/Users/me/.relay/worktrees/shop/pinned",
            "/Users/me/.relay/worktrees/shop/gone",
        ])
        #expect(worktrees.map(\.isMain) == [true, false, false, false, false])
        #expect(worktrees[0].head == "1111111111111111111111111111111111111111")
    }

    @Test("A branch is named the way it is typed, slashes and all")
    func shortBranchNames() {
        let worktrees = GitWorktreeParser.parse(porcelain: Self.listing)
        #expect(worktrees[0].branch == "main")
        #expect(worktrees[1].branch == "fix/login")
        #expect(worktrees[1].name == "fix/login")
    }

    @Test("A detached worktree has no branch and is called by its folder")
    func detachedHead() {
        let spike = GitWorktreeParser.parse(porcelain: Self.listing)[2]
        #expect(spike.branch == nil)
        #expect(spike.name == "spike")
    }

    @Test("Locked and prunable are read, with or without a reason")
    func lockedAndPrunable() {
        let worktrees = GitWorktreeParser.parse(porcelain: Self.listing)
        #expect(worktrees.map(\.isLocked) == [false, false, false, true, false])
        #expect(worktrees.map(\.isPrunable) == [false, false, false, false, true])
        let both = GitWorktreeParser.parse(porcelain: "worktree /a\nHEAD 1\nbranch refs/heads/x\nlocked\nprunable\n")
        #expect(both[0].isLocked)
        #expect(both[0].isPrunable)
    }

    @Test("A bare repository has nothing to work in, and none of its worktrees is main")
    func bareRepository() {
        let worktrees = GitWorktreeParser.parse(porcelain: """
        worktree /srv/shop.git
        bare

        worktree /srv/shop-main
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/main

        """)
        #expect(worktrees.map(\.path) == ["/srv/shop-main"])
        #expect(!worktrees[0].isMain)
    }

    @Test("Nothing listed is nothing")
    func emptyOutput() {
        #expect(GitWorktreeParser.parse(porcelain: "").isEmpty)
    }
}

@Suite("Which worktree a session is in")
struct WorktreeMembershipTests {
    private let worktrees = GitWorktreeParser.parse(porcelain: GitWorktreeParserTests.listing)

    private func session(in directory: String) -> SessionSnapshot {
        SessionSnapshot(
            id: .generate(),
            projectID: ProjectID(rawValue: "shop"),
            kind: .claude,
            name: "Claude",
            workingDirectory: directory,
            command: ["claude"],
            status: .working,
            pid: 1,
            exitCode: nil,
            startedAt: Date(),
            lastActivityAt: Date(),
            columns: 80,
            rows: 24
        )
    }

    @Test("The deepest worktree wins, because one can sit inside another")
    func deepestWins() {
        let owner = WorktreeMembership.worktree(
            containing: "/Users/me/code/shop/.claude/worktrees/spike/Sources",
            among: worktrees
        )
        #expect(owner?.name == "spike")
        #expect(WorktreeMembership.worktree(containing: "/Users/me/code/shop/Sources", among: worktrees)?.isMain == true)
    }

    @Test("A sibling folder with the same beginning is not inside")
    func siblingIsNotInside() {
        #expect(WorktreeMembership.worktree(containing: "/Users/me/code/shop-staging", among: worktrees) == nil)
    }

    @Test("Sessions are grouped under their worktree, the project's own checkout first")
    func grouping() {
        let home = session(in: "/Users/me/code/shop")
        let fix = session(in: "/Users/me/.relay/worktrees/shop/fix-login")
        let groups = WorktreeMembership.groups(of: [fix, home], among: worktrees, home: "/Users/me/code/shop")

        // The prunable one is gone from disk and has nothing to show.
        #expect(groups.map(\.worktree.name) == ["main", "fix/login", "spike", "pinned"])
        #expect(groups[0].sessions == [home])
        #expect(groups[1].sessions == [fix])
        // A worktree with nothing running in it is still somewhere to start.
        #expect(groups[2].sessions.isEmpty)
    }

    @Test("A session in no worktree stays in the sidebar, with the project's own checkout")
    func strayJoinsHome() {
        let stray = session(in: "/Users/me/Downloads")
        let lost = session(in: "/Users/me/.relay/worktrees/shop/gone")
        let groups = WorktreeMembership.groups(of: [stray, lost], among: worktrees, home: "/Users/me/code/shop")
        #expect(groups[0].sessions == [stray, lost])
    }

    @Test("A project reached through a symlink still finds its sessions")
    func symlinkedHome() throws {
        // Git reports where a worktree really is; the project was added by a
        // path that goes through a link, and its sessions started there.
        let directory = try TemporaryDirectory()
        let real = directory.url.appendingPathComponent("real/shop")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = directory.url.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: directory.url.appendingPathComponent("real")
        )
        let reported = GitWorktree(
            path: WorktreeMembership.canonical(real.path),
            branch: "main",
            head: nil,
            isMain: true,
            isLocked: false,
            isPrunable: false
        )
        let linked = link.appendingPathComponent("shop").path
        let started = session(in: linked)

        let groups = WorktreeMembership.groups(of: [started], among: [reported], home: linked)
        #expect(groups.map(\.worktree) == [reported])
        #expect(groups.first?.sessions == [started])
    }

    @Test("A project added from a linked worktree lists that one first")
    func linkedWorktreeAsHome() {
        let groups = WorktreeMembership.groups(
            of: [],
            among: worktrees,
            home: "/Users/me/.relay/worktrees/shop/fix-login"
        )
        #expect(groups.first?.worktree.name == "fix/login")
        #expect(groups.dropFirst().first?.worktree.isMain == true)
    }
}

@Suite("Naming a worktree")
struct WorktreeNamingTests {
    @Test("What was typed becomes a branch git accepts", arguments: [
        ("Fix login redirect", "Fix-login-redirect"),
        ("  feature/new   thing ", "feature/new-thing"),
        ("a..b", "a.b"),
        ("a//b", "a/b"),
        ("x~y^z:w?*[\\", "xyzw"),
        ("-leading", "leading"),
        ("trailing.", "trailing"),
        ("/slashes/", "slashes"),
        ("topic.lock", "topic"),
        ("a@{b", "a@b"),
        ("исправить кнопку", "исправить-кнопку"),
        ("@", ""),
        ("   ", ""),
    ])
    func branchNames(typed: String, expected: String) {
        #expect(WorktreeNaming.branchName(from: typed) == expected)
    }

    @Test("A worktree goes under its repository, one folder even for a slashed branch")
    func directory() {
        let base = URL(fileURLWithPath: "/Users/me/.relay/worktrees")
        let path = WorktreeNaming.directory(for: "fix/login", repository: "shop", in: base) { _ in false }
        #expect(path == "/Users/me/.relay/worktrees/shop/fix-login")
    }

    @Test("A folder that is taken gets a number")
    func takenFolder() {
        let base = URL(fileURLWithPath: "/w")
        let taken: Set<String> = ["/w/shop/fix", "/w/shop/fix-2"]
        let path = WorktreeNaming.directory(for: "fix", repository: "shop", in: base) { taken.contains($0) }
        #expect(path == "/w/shop/fix-3")
    }

    @Test("Relay keeps its worktrees in a folder of its own")
    func worktreesDirectory() {
        #expect(RelayPaths.worktreesDirectory.deletingLastPathComponent() == RelayPaths.supportDirectory)
        #expect(RelayPaths.worktreesDirectory.lastPathComponent == "worktrees")
    }
}

@Suite("Worktrees through the git CLI", .serialized)
struct GitWorktreeActionsTests {
    /// A repository with one commit on `main`, in a directory spelled the way
    /// git will report it back — through `/private`, which
    /// `resolvingSymlinksInPath` strips off again.
    private func repository(in directory: TemporaryDirectory) throws -> (root: String, base: URL) {
        let base = URL(fileURLWithPath: WorktreeMembership.canonical(directory.url.path))
        let root = base.appendingPathComponent("shop").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Git.run(["init", "-b", "main"], in: root)
        try Git.run(["config", "user.email", "tests@relay.local"], in: root)
        try Git.run(["config", "user.name", "Relay Tests"], in: root)
        try "hello\n".write(toFile: root + "/file.txt", atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: root)
        try Git.run(["commit", "-m", "initial"], in: root)
        return (root, base)
    }

    @Test("A new branch is started in a folder of its own and listed after the main one")
    func createsAndLists() throws {
        let directory = try TemporaryDirectory()
        let (root, base) = try repository(in: directory)
        let target = base.appendingPathComponent("worktrees/shop/fix-login").path

        #expect(GitWorktreeActions.add(branch: "fix-login", from: "main", at: target, in: root) == nil)

        let listed = try #require(GitWorktreeActions.list(at: root))
        #expect(listed.map(\.path) == [root, target])
        #expect(listed.map(\.branch) == ["main", "fix-login"])
        #expect(listed[0].isMain)
        #expect(GitWorktreeActions.createdBranch("fix-login", in: root))
        #expect(FileManager.default.fileExists(atPath: target + "/file.txt"))
    }

    @Test("A name git refuses is refused before anything is made")
    func invalidName() throws {
        let directory = try TemporaryDirectory()
        let (root, base) = try repository(in: directory)
        let target = base.appendingPathComponent("worktrees/shop/bad").path

        #expect(GitWorktreeActions.add(branch: "bad..name", from: nil, at: target, in: root) != nil)
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test("Uncommitted work stops a removal unless it is to be thrown away")
    func removalRespectsChanges() throws {
        let directory = try TemporaryDirectory()
        let (root, base) = try repository(in: directory)
        let target = base.appendingPathComponent("worktrees/shop/spike").path
        #expect(GitWorktreeActions.add(branch: "spike", from: nil, at: target, in: root) == nil)
        let worktree = try #require(GitWorktreeActions.list(at: root)?.last)

        try "edited\n".write(toFile: target + "/file.txt", atomically: true, encoding: .utf8)
        #expect(GitWorktreeActions.remove(worktree, force: false, in: root) != nil)
        #expect(FileManager.default.fileExists(atPath: target))

        #expect(GitWorktreeActions.remove(worktree, force: true, in: root) == nil)
        #expect(!FileManager.default.fileExists(atPath: target))
        #expect(GitWorktreeActions.list(at: root)?.count == 1)
    }

    @Test("A branch Relay made with nothing on it goes with its worktree")
    func emptyBranchIsDeleted() throws {
        let directory = try TemporaryDirectory()
        let (root, base) = try repository(in: directory)
        let target = base.appendingPathComponent("worktrees/shop/idea").path
        #expect(GitWorktreeActions.add(branch: "idea", from: nil, at: target, in: root) == nil)
        let worktree = try #require(GitWorktreeActions.list(at: root)?.last)

        #expect(GitWorktreeActions.remove(worktree, force: false, in: root) == nil)
        #expect(GitWorktreeActions.removeBranch(of: worktree, in: root) == .deleted)
        #expect(!GitWorktreeActions.branchExists("idea", in: root))
    }

    @Test("A branch with work merged nowhere is kept")
    func unmergedBranchIsKept() throws {
        let directory = try TemporaryDirectory()
        let (root, base) = try repository(in: directory)
        let target = base.appendingPathComponent("worktrees/shop/work").path
        #expect(GitWorktreeActions.add(branch: "work", from: nil, at: target, in: root) == nil)
        try "work\n".write(toFile: target + "/file.txt", atomically: true, encoding: .utf8)
        try Git.run(["commit", "-am", "work"], in: target)
        let worktree = try #require(GitWorktreeActions.list(at: root)?.last)

        #expect(GitWorktreeActions.remove(worktree, force: false, in: root) == nil)
        #expect(GitWorktreeActions.removeBranch(of: worktree, in: root) == .keptUnmerged)
        #expect(GitWorktreeActions.branchExists("work", in: root))
    }

    @Test("An existing branch is opened rather than started, and never deleted by Relay")
    func existingBranchIsLeftAlone() throws {
        let directory = try TemporaryDirectory()
        let (root, base) = try repository(in: directory)
        try Git.run(["branch", "someone-elses"], in: root)
        let target = base.appendingPathComponent("worktrees/shop/someone-elses").path

        #expect(GitWorktreeActions.add(branch: "someone-elses", from: "main", at: target, in: root) == nil)
        #expect(!GitWorktreeActions.createdBranch("someone-elses", in: root))
        let worktree = try #require(GitWorktreeActions.list(at: root)?.last)
        #expect(worktree.branch == "someone-elses")

        #expect(GitWorktreeActions.remove(worktree, force: false, in: root) == nil)
        // Merged — it points at `main` — and still not Relay's to delete.
        #expect(GitWorktreeActions.removeBranch(of: worktree, in: root) == .untouched)
        #expect(GitWorktreeActions.branchExists("someone-elses", in: root))
    }
}
