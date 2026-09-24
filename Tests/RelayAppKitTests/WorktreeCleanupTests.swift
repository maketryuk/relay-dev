import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("Deciding which worktrees can go")
struct WorktreeCleanupDecisionTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 24 * 60 * 60

    /// A worktree with nothing against it: merged, clean, nothing running,
    /// untouched for a week. Each test spoils it in one way.
    private func candidate(
        path: String = "/w/shop/done",
        branch: String? = "done",
        facts: WorktreeDiskFacts? = nil,
        reading: WorktreeFactsReading? = nil,
        isLocked: Bool = false,
        isPrunable: Bool = false,
        sessions: Int = 0,
        agent: WorktreeAgentActivity = .none,
        sessionActivity: Date? = nil
    ) -> WorktreeCleanupCandidate {
        let read = facts ?? WorktreeDiskFacts(
            uncommittedFiles: 0,
            unpushedCommits: 0,
            integration: .merged,
            base: "origin/main",
            lastActivity: Self.now.addingTimeInterval(-7 * Self.day)
        )
        return WorktreeCleanupCandidate(
            worktree: GitWorktree(
                path: path,
                branch: branch,
                head: "1111111111111111111111111111111111111111",
                isMain: false,
                isLocked: isLocked,
                isPrunable: isPrunable
            ),
            reading: reading ?? .read(read),
            sessions: sessions,
            agent: agent,
            sessionActivity: sessionActivity
        )
    }

    private func facts(
        uncommitted: Int = 0,
        unpushed: Int? = 0,
        stranded: Int = 0,
        integration: BranchIntegration = .merged,
        lastActivity: Date? = Date(timeIntervalSince1970: 1_800_000_000 - 7 * 24 * 60 * 60)
    ) -> WorktreeDiskFacts {
        WorktreeDiskFacts(
            uncommittedFiles: uncommitted,
            unpushedCommits: unpushed,
            strandedCommits: stranded,
            integration: integration,
            base: "origin/main",
            lastActivity: lastActivity
        )
    }

    @Test("A finished worktree nobody is using is suggested")
    func finishedIsSuggested() {
        let done = candidate()
        #expect(WorktreeCleanup.blockers(of: done).isEmpty)
        #expect(WorktreeCleanup.isSuggested(done, now: Self.now))
        #expect(WorktreeCleanup.isSuggested(candidate(facts: facts(integration: .squashMerged)), now: Self.now))
    }

    @Test("Uncommitted files block until losing exactly that many is agreed to")
    func uncommittedNeedsConsent() {
        let dirty = candidate(facts: facts(uncommitted: 3))
        #expect(WorktreeCleanup.blockers(of: dirty) == [.uncommittedChanges(3)])
        #expect(WorktreeCleanup.blockers(of: dirty, discardConsent: 2) == [.uncommittedChanges(3)])
        #expect(WorktreeCleanup.canPick(dirty, discardConsent: 3))
        #expect(WorktreeCleanup.discardsChanges(dirty, discardConsent: 3))
        #expect(!WorktreeCleanup.discardsChanges(dirty, discardConsent: nil))
        // Consent is about files, and a clean worktree has none to lose.
        #expect(!WorktreeCleanup.discardsChanges(candidate(), discardConsent: 3))
        #expect(!WorktreeCleanup.isSuggested(dirty, now: Self.now))
    }

    @Test("A lock, a busy agent and an unreadable worktree each stop it being picked")
    func hardBlockers() {
        #expect(WorktreeCleanup.blockers(of: candidate(isLocked: true)) == [.locked])
        #expect(WorktreeCleanup.blockers(of: candidate(sessions: 1, agent: .working)) == [.agentWorking])
        #expect(WorktreeCleanup.blockers(of: candidate(sessions: 1, agent: .waiting)) == [.agentWaiting])
        #expect(WorktreeCleanup.blockers(of: candidate(reading: .unreadable("fatal: bad"))) == [.unreadable("fatal: bad")])
        #expect(WorktreeCleanup.blockers(of: candidate(reading: .reading)) == [.reading])
        // Consent to discard lifts only the uncommitted files, never the rest.
        let lockedAndDirty = candidate(facts: facts(uncommitted: 1), isLocked: true)
        #expect(WorktreeCleanup.blockers(of: lockedAndDirty, discardConsent: 1) == [.locked])
    }

    @Test("Sessions that are only open are closed, not a reason to keep it — but nothing is picked under them")
    func idleSessions() {
        let open = candidate(sessions: 2, agent: .none)
        #expect(WorktreeCleanup.canPick(open))
        #expect(!WorktreeCleanup.isSuggested(open, now: Self.now))
    }

    @Test("Commits nobody else has are kept on their branch, so they warn rather than block")
    func unpushedWorkWarns() {
        let work = candidate(facts: facts(unpushed: 2, integration: .unmerged))
        #expect(WorktreeCleanup.canPick(work))
        #expect(WorktreeCleanup.unpushedWork(of: work) == 2)
        #expect(!WorktreeCleanup.isSuggested(work, now: Self.now))
        // Merged work has somewhere to live already.
        #expect(WorktreeCleanup.unpushedWork(of: candidate(facts: facts(unpushed: 2, integration: .merged))) == nil)
        // With no remote there is nothing to push to, and nothing to warn about.
        #expect(WorktreeCleanup.unpushedWork(of: candidate(facts: facts(unpushed: nil, integration: .unmerged))) == nil)
    }

    @Test("Commits only a detached HEAD reaches go with the worktree, so they block")
    func strandedCommitsBlock() {
        let detached = candidate(branch: nil, facts: facts(stranded: 1, integration: .unmerged))
        #expect(WorktreeCleanup.blockers(of: detached) == [.strandedCommits(1)])
    }

    @Test("A worktree started a minute ago is merged too, and is not picked for that")
    func recentIsNotSuggested() {
        let fresh = candidate(facts: facts(lastActivity: Self.now.addingTimeInterval(-60)))
        #expect(WorktreeCleanup.canPick(fresh))
        #expect(!WorktreeCleanup.isSuggested(fresh, now: Self.now))
        // Nor is one quiet on disk with an agent printing in it an hour ago.
        let talking = candidate(sessionActivity: Self.now.addingTimeInterval(-3600))
        #expect(!WorktreeCleanup.isSuggested(talking, now: Self.now))
        #expect(!WorktreeCleanup.isSuggested(candidate(facts: facts(lastActivity: nil)), now: Self.now))
    }

    @Test("Last activity is the newer of the disk's and a session's")
    func lastActivity() {
        let disk = Self.now.addingTimeInterval(-7 * Self.day)
        let session = Self.now.addingTimeInterval(-Self.day)
        #expect(candidate(sessionActivity: session).lastActivity == session)
        #expect(candidate(sessionActivity: disk.addingTimeInterval(-1)).lastActivity == disk)
        #expect(candidate(reading: .reading).lastActivity == nil)
    }

    @Test("Filters: merged counts a squash, clean means nothing uncommitted, idle needs evidence")
    func filters() {
        let merged = candidate(path: "/merged")
        let squashed = candidate(path: "/squashed", facts: facts(integration: .squashMerged))
        let unmerged = candidate(path: "/unmerged", facts: facts(integration: .unmerged))
        let unknown = candidate(path: "/unknown", facts: facts(integration: .unknown))
        let dirty = candidate(path: "/dirty", facts: facts(uncommitted: 1))
        let recent = candidate(path: "/recent", facts: facts(lastActivity: Self.now.addingTimeInterval(-2 * Self.day)))
        let unread = candidate(path: "/unread", reading: .reading)
        let all = [merged, squashed, unmerged, unknown, dirty, recent, unread]

        func shown(_ filter: WorktreeCleanupFilter) -> [String] {
            WorktreeCleanup.shown(all, filter: filter, now: Self.now).map(\.id)
        }

        #expect(shown(WorktreeCleanupFilter()) == all.map(\.id))
        #expect(shown(WorktreeCleanupFilter(integrated: true)) == ["/merged", "/squashed", "/dirty", "/recent"])
        #expect(shown(WorktreeCleanupFilter(clean: true)) == ["/merged", "/squashed", "/unmerged", "/unknown", "/recent"])
        #expect(shown(WorktreeCleanupFilter(idle: true, idleDays: 3)).contains("/recent") == false)
        #expect(shown(WorktreeCleanupFilter(idle: true, idleDays: 3)).contains("/unread") == false)
        #expect(shown(WorktreeCleanupFilter(idle: true, idleDays: 1)).contains("/recent"))
        #expect(shown(WorktreeCleanupFilter(integrated: true, clean: true, idle: true, idleDays: 3)) == ["/merged", "/squashed"])
    }

    @Test("Remove takes what is picked, pickable and shown, and nothing else")
    func removable() {
        let done = candidate(path: "/done")
        let dirty = candidate(path: "/dirty", facts: facts(uncommitted: 2))
        let busy = candidate(path: "/busy", sessions: 1, agent: .working)
        // Picked before a filter hid it, and not among what is shown.
        let picked: Set<String> = ["/done", "/dirty", "/busy", "/hidden"]

        let shown = [done, dirty, busy]
        #expect(WorktreeCleanup.removable(shown, selection: picked, discardConsent: [:]).map(\.id) == ["/done"])
        #expect(WorktreeCleanup.removable(shown, selection: picked, discardConsent: ["/dirty": 2]).map(\.id)
            == ["/done", "/dirty"])
        #expect(WorktreeCleanup.removable(shown, selection: [], discardConsent: [:]).isEmpty)
    }

    @Test("The summary counts what went, names the branches kept, and quotes git for the rest")
    func summary() {
        let summary = WorktreeCleanup.summary(of: [
            WorktreeCleanupOutcome(name: "done", branch: "done", failure: nil, branchOutcome: .deleted),
            WorktreeCleanupOutcome(name: "work", branch: "work", failure: nil, branchOutcome: .keptUnmerged),
            WorktreeCleanupOutcome(name: "theirs", branch: "theirs", failure: nil, branchOutcome: .untouched),
            WorktreeCleanupOutcome(name: "stuck", branch: "stuck", failure: "fatal: it is locked"),
        ])
        #expect(summary.attempted == 4)
        #expect(summary.removed == 3)
        #expect(summary.keptBranches == ["work"])
        #expect(summary.failures == [WorktreeCleanupSummary.Failure(name: "stuck", message: "fatal: it is locked")])
    }

    @Test("An agent waiting outranks one working; one starting is working; the rest are nothing")
    func agentActivity() {
        #expect(WorktreeAgentActivity([.working, .waiting]) == .waiting)
        #expect(WorktreeAgentActivity([.idle, .starting]) == .working)
        #expect(WorktreeAgentActivity([.idle, .finished, .error, .offline]) == .none)
        #expect(WorktreeAgentActivity([]) == .none)
    }
}

@Suite("What the cleanup window remembers")
struct WorktreeCleanupStateTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func candidate(_ path: String, uncommitted: Int = 0, quiet: Bool = true) -> WorktreeCleanupCandidate {
        WorktreeCleanupCandidate(
            worktree: GitWorktree(path: path, branch: path, head: nil, isMain: false, isLocked: false, isPrunable: false),
            reading: .read(WorktreeDiskFacts(
                uncommittedFiles: uncommitted,
                unpushedCommits: 0,
                integration: .merged,
                base: "main",
                lastActivity: now.addingTimeInterval(quiet ? -10 * 24 * 60 * 60 : -60)
            )),
            sessions: 0,
            agent: .none,
            sessionActivity: nil
        )
    }

    @Test("Rows are picked for the person until they pick something themselves")
    func suggestionsStopOnceChosen() {
        var state = WorktreeCleanupState()
        state.suggest(among: [candidate("a"), candidate("b", quiet: false)], now: now)
        #expect(state.selection == ["a"])

        state.toggle("a")
        #expect(state.selection.isEmpty)
        state.suggest(among: [candidate("a"), candidate("c")], now: now)
        #expect(state.selection.isEmpty)
    }

    @Test("Agreeing to discard picks the row; a different count of files withdraws the agreement")
    func consentFollowsTheFiles() {
        var state = WorktreeCleanupState()
        let dirty = candidate("dirty", uncommitted: 2)
        state.consentToDiscard(dirty)
        #expect(state.discardConsent["dirty"] == 2)
        #expect(state.selection == ["dirty"])

        state.record(dirty.reading, for: "dirty")
        #expect(state.discardConsent["dirty"] == 2)
        state.record(candidate("dirty", uncommitted: 3).reading, for: "dirty")
        #expect(state.discardConsent["dirty"] == nil)

        state.consentToDiscard(candidate("dirty", uncommitted: 3))
        state.withdrawConsent(from: "dirty")
        #expect(state.discardConsent["dirty"] == nil)
        #expect(state.selection.isEmpty)
    }

    @Test("A removed row is forgotten; a refused one keeps git's reason")
    func settling() {
        var state = WorktreeCleanupState()
        state.select(["gone", "stuck"])
        state.record(candidate("gone").reading, for: "gone")
        state.settle("gone", with: WorktreeCleanupOutcome(name: "gone", branch: "gone", failure: nil))
        state.settle("stuck", with: WorktreeCleanupOutcome(name: "stuck", branch: "stuck", failure: "fatal: locked"))
        #expect(state.selection == ["stuck"])
        #expect(state.readings["gone"] == nil)
        #expect(state.failures == ["stuck": "fatal: locked"])
    }
}

@Suite("Reading a worktree's facts from git", .serialized)
struct WorktreeFactsReaderTests {
    /// A repository with one commit on `main`, set up so nothing about the
    /// machine running the tests can change what git does in it.
    private func repository(in directory: TemporaryDirectory) throws -> (root: String, base: URL) {
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
        return (root, base)
    }

    private func worktree(_ branch: String, in root: String, base: URL) throws -> GitWorktree {
        let target = base.appendingPathComponent("worktrees/\(branch)").path
        #expect(GitWorktreeActions.add(branch: branch, from: "main", at: target, in: root) == nil)
        return try #require(GitWorktreeActions.list(at: root)?.first { $0.path == target })
    }

    private func read(_ worktree: GitWorktree, in root: String) throws -> WorktreeDiskFacts {
        let reading = WorktreeFactsReader.facts(of: worktree, in: WorktreeFactsReader.repository(at: root))
        guard case let .read(facts) = reading else {
            Issue.record("not read: \(reading)")
            throw Git.GitError.failed("read")
        }
        return facts
    }

    @Test("A worktree with nothing done in it is merged, clean, and recently made")
    func freshWorktree() throws {
        let directory = try TemporaryDirectory()
        let (root, base) = try repository(in: directory)
        let started = Date().addingTimeInterval(-60)
        let idea = try worktree("idea", in: root, base: base)

        let facts = try read(idea, in: root)
        #expect(facts.uncommittedFiles == 0)
        #expect(facts.unpushedCommits == nil)
        #expect(facts.strandedCommits == 0)
        #expect(facts.base == "main")
        #expect(facts.integration == .merged)
        // The reflog says when it was made, whatever the date of the commit.
        #expect((facts.lastActivity ?? .distantPast) > started)
    }

    @Test("Changed and untracked files are counted, and the newest of them is the last activity")
    func uncommittedFiles() throws {
        let directory = try TemporaryDirectory()
        let (root, base) = try repository(in: directory)
        let spike = try worktree("spike", in: root, base: base)
        try "edited\n".write(toFile: spike.path + "/file.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: spike.path + "/notes.txt", atomically: true, encoding: .utf8)
        let later = Date().addingTimeInterval(3600).rounded
        try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: spike.path + "/notes.txt")

        let facts = try read(spike, in: root)
        #expect(facts.uncommittedFiles == 2)
        #expect(facts.lastActivity == later)
    }

    @Test("Looking does not rewrite the index, so it cannot pass for activity")
    func readingLeavesTheIndexAlone() throws {
        let directory = try TemporaryDirectory()
        let (root, base) = try repository(in: directory)
        let spike = try worktree("spike", in: root, base: base)
        // Same contents, new date: a plain `git status` refreshes the index
        // entry for it, and writes the index to do so.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(3600)],
            ofItemAtPath: spike.path + "/file.txt"
        )
        let index = try #require(Shell.run(
            "/usr/bin/git",
            arguments: ["-C", spike.path, "rev-parse", "--path-format=absolute", "--git-path", "index"]
        )?.trimmingCharacters(in: .whitespacesAndNewlines))
        let before = try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date

        _ = try read(spike, in: root)
        let after = try FileManager.default.attributesOfItem(atPath: index)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test("Commits of its own are unmerged, and unpushed until they are pushed")
    func unpushedCommits() throws {
        let directory = try TemporaryDirectory()
        let (root, base) = try repository(in: directory)
        let remote = base.appendingPathComponent("remote.git").path
        try Git.run(["init", "--bare", "-b", "main", remote], in: base.path)
        try Git.run(["remote", "add", "origin", remote], in: root)
        try Git.run(["push", "-q", "origin", "main"], in: root)
        let work = try worktree("work", in: root, base: base)
        try "work\n".write(toFile: work.path + "/file.txt", atomically: true, encoding: .utf8)
        try Git.run(["commit", "-qam", "work"], in: work.path)

        let unpushed = try read(work, in: root)
        #expect(unpushed.unpushedCommits == 1)
        #expect(unpushed.integration == .unmerged)
        #expect(unpushed.uncommittedFiles == 0)

        try Git.run(["push", "-q", "origin", "work"], in: work.path)
        #expect(try read(work, in: root).unpushedCommits == 0)
    }

    @Test("A commit only a detached HEAD reaches is counted as stranded")
    func detachedCommits() throws {
        let directory = try TemporaryDirectory()
        let (root, base) = try repository(in: directory)
        let target = base.appendingPathComponent("worktrees/detached").path
        try Git.run(["worktree", "add", "--detach", target], in: root)
        let detached = try #require(GitWorktreeActions.list(at: root)?.first { $0.path == target })
        #expect(detached.branch == nil)
        #expect(try read(detached, in: root).strandedCommits == 0)

        try "lost\n".write(toFile: target + "/file.txt", atomically: true, encoding: .utf8)
        try Git.run(["commit", "-qam", "lost"], in: target)
        #expect(try read(detached, in: root).strandedCommits == 1)
    }

    @Test("A worktree whose folder is gone is still read, from the repository")
    func prunable() throws {
        let directory = try TemporaryDirectory()
        let (root, base) = try repository(in: directory)
        let gone = try worktree("gone", in: root, base: base)
        try FileManager.default.removeItem(atPath: gone.path)
        let listed = try #require(GitWorktreeActions.list(at: root)?.first { $0.path == gone.path })
        #expect(listed.isPrunable)

        let facts = try read(listed, in: root)
        #expect(facts.uncommittedFiles == 0)
        #expect(facts.integration == .merged)
        #expect(facts.lastActivity != nil)
    }

    @Test("A worktree git cannot read says so in git's words")
    func unreadable() throws {
        let directory = try TemporaryDirectory()
        let (root, base) = try repository(in: directory)
        let broken = try worktree("broken", in: root, base: base)
        try "gitdir: /nowhere\n".write(toFile: broken.path + "/.git", atomically: true, encoding: .utf8)

        let reading = WorktreeFactsReader.facts(of: broken, in: WorktreeFactsReader.repository(at: root))
        guard case let .unreadable(message) = reading else {
            Issue.record("read anyway: \(reading)")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test("A repository with a remote is one there is somewhere to push to")
    func remotes() throws {
        let directory = try TemporaryDirectory()
        let (root, _) = try repository(in: directory)
        #expect(!WorktreeFactsReader.repository(at: root).hasRemote)
        try Git.run(["remote", "add", "origin", "https://example.invalid/shop.git"], in: root)
        #expect(WorktreeFactsReader.repository(at: root).hasRemote)
    }

    @Test("A reflog entry gives when HEAD moved, and the commit it moved to")
    func reflogEntry() {
        let head = WorktreeFactsReader.parseReflogEntry("HEAD@{1790277874} 1790277443 abc123\n")
        #expect(head == WorktreeFactsReader.Head(
            hash: "abc123",
            committed: Date(timeIntervalSince1970: 1_790_277_443),
            moved: Date(timeIntervalSince1970: 1_790_277_874)
        ))
        #expect(WorktreeFactsReader.parseReflogEntry("") == nil)
        #expect(WorktreeFactsReader.parseReflogEntry("HEAD@{2 days ago} 1790277443 abc123") == nil)
    }
}

private extension Date {
    /// File dates keep whole seconds on some volumes; comparing against one
    /// that was never rounded would be testing the file system.
    var rounded: Date { Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down)) }
}
