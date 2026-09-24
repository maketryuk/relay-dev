import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

private func worktree(_ path: String, isPrunable: Bool = false) -> GitWorktree {
    GitWorktree(path: path, branch: nil, head: nil, isMain: false, isLocked: false, isPrunable: isPrunable)
}

@Suite("What has been said about each worktree")
struct WorktreeNotesTests {
    private let shop = ProjectID(rawValue: "shop")
    private let shopAgain = ProjectID(rawValue: "shop-again")
    private let blog = ProjectID(rawValue: "blog")
    private let fix = "/Users/me/.relay/worktrees/shop/fix-login"
    private let spike = "/Users/me/.relay/worktrees/shop/spike"
    private let noon = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("Saying something is kept for the worktree, and saying it again changes nothing")
    func revisionIsStampedOnlyWhenSomethingChanges() {
        var notes = WorktreeNotes()
        let said = notes.revise(at: fix, listedBy: [shop], on: noon) { $0.status = .inProgress }
        let saidAgain = notes.revise(at: fix, listedBy: [shop], on: noon.addingTimeInterval(60)) { $0.status = .inProgress }
        #expect(said)
        #expect(!saidAgain)

        let note = notes.note(at: fix)
        #expect(note?.status == .inProgress)
        #expect(note?.updatedAt == noon)
    }

    @Test("A status and a comment are one note, and each can go without the other")
    func statusAndCommentAreIndependent() {
        var notes = WorktreeNotes()
        notes.revise(at: fix, listedBy: [shop], on: noon) { $0.status = .inReview }
        notes.revise(at: fix, listedBy: [shop], on: noon) { $0.comment = "fix implemented; running tests" }
        #expect(notes.note(at: fix)?.status == .inReview)
        #expect(notes.note(at: fix)?.comment == "fix implemented; running tests")

        notes.revise(at: fix, listedBy: [shop], on: noon) { $0.status = nil }
        #expect(notes.note(at: fix)?.comment == "fix implemented; running tests")
        notes.revise(at: fix, listedBy: [shop], on: noon) { $0.comment = nil }
        #expect(notes.note(at: fix) == nil)
        #expect(notes.byProject.isEmpty)
    }

    @Test("A worktree no project lists is not noted")
    func unlistedWorktreeIsNotNoted() {
        var notes = WorktreeNotes()
        let said = notes.revise(at: fix, listedBy: [], on: noon) { $0.status = .todo }
        #expect(!said)
        #expect(notes.note(at: fix) == nil)
    }

    @Test("Two projects listing one worktree share its note, and the last word stands")
    func sharedWorktreeShowsTheLatest() {
        var notes = WorktreeNotes([shopAgain: [fix: WorktreeNote(status: .todo, updatedAt: noon)]])
        notes.revise(at: fix, listedBy: [shop], on: noon.addingTimeInterval(60)) { $0.status = .completed }
        #expect(notes.note(at: fix)?.status == .completed)

        // Emptied, it goes from both, or the older copy would show through.
        notes.revise(at: fix, listedBy: [shop], on: noon.addingTimeInterval(120)) { $0.status = nil }
        #expect(notes.note(at: fix) == nil)
        #expect(notes.byProject.isEmpty)
    }

    @Test("A fresh list lets go of the project's worktrees it no longer names, and nobody else's")
    func freshListDropsTheGone() {
        var notes = WorktreeNotes([
            shop: [fix: WorktreeNote(status: .completed, updatedAt: noon), spike: WorktreeNote(comment: "idea", updatedAt: noon)],
            blog: [spike: WorktreeNote(status: .todo, updatedAt: noon)],
        ])

        let dropped = notes.keep(only: [worktree("/Users/me/code/shop"), worktree(fix)], in: shop)
        #expect(dropped)
        #expect(notes.byProject[shop]?[fix]?.status == .completed)
        #expect(notes.byProject[shop]?[spike] == nil)
        #expect(notes.byProject[blog]?[spike]?.status == .todo)

        let droppedAgain = notes.keep(only: [worktree(fix)], in: shop)
        #expect(!droppedAgain)
    }

    @Test("A worktree git still lists keeps its note even with its folder gone")
    func prunableIsStillListed() {
        var notes = WorktreeNotes([shop: [fix: WorktreeNote(comment: "half done", updatedAt: noon)]])
        let dropped = notes.keep(only: [worktree(fix, isPrunable: true)], in: shop)
        #expect(!dropped)
        #expect(notes.note(at: fix)?.comment == "half done")
    }

    @Test("An empty list is a failure to answer, not an answer, and drops nothing")
    func emptyListKeepsEverything() {
        var notes = WorktreeNotes([shop: [fix: WorktreeNote(status: .inProgress, updatedAt: noon)]])
        let dropped = notes.keep(only: [], in: shop)
        #expect(!dropped)
        #expect(notes.note(at: fix)?.status == .inProgress)
    }

    @Test("A removed project takes its notes with it")
    func forgettingAProject() {
        var notes = WorktreeNotes([shop: [fix: WorktreeNote(status: .todo, updatedAt: noon)]])
        let forgot = notes.forget(shop)
        let forgotAgain = notes.forget(shop)
        #expect(forgot)
        #expect(!forgotAgain)
        #expect(notes.note(at: fix) == nil)
    }

    @Test("What the file holds becomes the same notes again")
    func persistedRoundTrip() {
        let notes = WorktreeNotes([
            shop: [fix: WorktreeNote(status: .inReview, comment: "PR open", updatedAt: noon)],
            blog: [spike: WorktreeNote(status: .todo, updatedAt: noon)],
        ])
        #expect(notes.persisted["shop"]?[fix]?.comment == "PR open")
        #expect(WorktreeNotes(persisted: notes.persisted) == notes)
    }

    @Test("A comment is kept trimmed, and one of nothing but space is no comment", arguments: [
        ("  fix implemented; running tests\n", "fix implemented; running tests"),
        ("   ", nil),
        ("\n\t", nil),
        ("", nil),
    ] as [(String, String?)])
    func typedComment(typed: String, kept: String?) {
        #expect(WorktreeNotes.comment(from: typed) == kept)
    }
}

@Suite("Worktree notes in the workspace file")
struct WorktreeNotesPersistenceTests {
    private let fix = "/Users/me/.relay/worktrees/shop/fix-login"

    @Test("Notes survive a save and a load")
    func roundTrip() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        // Whole seconds: the file keeps dates to the second.
        let note = WorktreeNote(status: .inProgress, comment: "fix implemented", updatedAt: Date(timeIntervalSince1970: 1_790_000_000))

        WorkspaceStore(url: url).saveNow(WorkspaceState(worktreeNotes: ["shop": [fix: note]]))

        #expect(WorkspaceStore(url: url).load().worktreeNotes["shop"]?[fix] == note)
    }

    @Test("A workspace written before notes existed opens unchanged")
    func olderFileWithoutNotes() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        try #"""
        {"version":1,
         "projects":[{"id":"p","name":"Storefront","rootPath":"/tmp"}],
         "collapsedSections":["worktree:/tmp"]}
        """#.write(to: url, atomically: true, encoding: .utf8)

        let loaded = WorkspaceStore(url: url).load()
        #expect(loaded.worktreeNotes.isEmpty)
        #expect(loaded.projects.map(\.name) == ["Storefront"])
        #expect(loaded.collapsedSections == ["worktree:/tmp"])
    }

    @Test("A note this build cannot read costs that note, not the others or the workspace")
    func unreadableNoteIsDroppedAlone() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        try #"""
        {"version":1,
         "projects":[{"id":"p","name":"Storefront","rootPath":"/tmp"}],
         "worktreeNotes":{"p":{
           "/tmp/a":{"status":"in-review","updatedAt":"2026-09-24T12:00:00Z"},
           "/tmp/b":{"status":"blocked","comment":"waiting on design","updatedAt":"2026-09-24T12:00:00Z"},
           "/tmp/c":{"comment":42}}}}
        """#.write(to: url, atomically: true, encoding: .utf8)

        let loaded = WorkspaceStore(url: url).load()
        #expect(loaded.projects.map(\.name) == ["Storefront"])
        #expect(loaded.worktreeNotes["p"]?["/tmp/a"]?.status == .inReview)
        #expect(loaded.worktreeNotes["p"]?["/tmp/b"]?.status == nil)
        #expect(loaded.worktreeNotes["p"]?["/tmp/b"]?.comment == "waiting on design")
        #expect(loaded.worktreeNotes["p"]?["/tmp/c"] == nil)
    }
}

/// The model against a real repository: the notes follow what `git worktree
/// list` says, so that is what they are tested against.
@Suite("Worktree notes in the app", .serialized)
@MainActor
struct WorktreeNotesModelTests {
    private struct Fixture {
        let model: AppModel
        let project: ProjectID
        let store: URL
        let root: String
        let linked: String
    }

    /// A repository with a second worktree, added as a project and listed.
    private func fixture(in directory: TemporaryDirectory) async throws -> Fixture {
        let base = URL(fileURLWithPath: WorktreeMembership.canonical(directory.url.path))
        let root = base.appendingPathComponent("shop").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Git.run(["init", "-b", "main"], in: root)
        try Git.run(["config", "user.email", "tests@relay.local"], in: root)
        try Git.run(["config", "user.name", "Relay Tests"], in: root)
        try "hello\n".write(toFile: root + "/file.txt", atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: root)
        try Git.run(["commit", "-m", "initial"], in: root)
        let linked = base.appendingPathComponent("worktrees/shop/fix-login").path
        try #require(GitWorktreeActions.add(branch: "fix-login", from: "main", at: linked, in: root) == nil)

        let store = base.appendingPathComponent("workspace.json")
        let model = AppModel(store: WorkspaceStore(url: store))
        model.addProject(at: URL(fileURLWithPath: root))
        let project = try #require(model.projects.first?.id)
        try await waitUntil { model.worktrees[project]?.count == 2 && model.gitStatuses[project] != nil }
        return Fixture(model: model, project: project, store: store, root: root, linked: linked)
    }

    /// Waits for git to have answered rather than for a time to have passed;
    /// the bound is only there so that a git that never answers fails the test
    /// instead of hanging it.
    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0 ..< 750 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try #require(condition())
    }

    @Test("A status and a comment are kept for the worktree and written to the workspace")
    func setAndPersisted() async throws {
        let directory = try TemporaryDirectory()
        let fixture = try await fixture(in: directory)
        let model = fixture.model

        model.setWorktreeStatus(.inProgress, at: fixture.linked)
        model.setWorktreeComment("  fix implemented; running tests\n", at: fixture.linked)

        #expect(model.worktreeNote(at: fixture.linked)?.status == .inProgress)
        #expect(model.worktreeNote(at: fixture.linked)?.comment == "fix implemented; running tests")
        #expect(model.worktreeNote(at: fixture.root) == nil)

        model.persistImmediately()
        let saved = WorkspaceStore(url: fixture.store).load().worktreeNotes[fixture.project.rawValue]?[fixture.linked]
        #expect(saved?.status == .inProgress)
        #expect(saved?.comment == "fix implemented; running tests")
    }

    @Test("A blank comment clears it, and a note with nothing left goes altogether")
    func clearing() async throws {
        let directory = try TemporaryDirectory()
        let fixture = try await fixture(in: directory)
        let model = fixture.model
        model.setWorktreeStatus(.inReview, at: fixture.linked)
        model.setWorktreeComment("PR open", at: fixture.linked)

        model.setWorktreeComment("   ", at: fixture.linked)
        #expect(model.worktreeNote(at: fixture.linked)?.comment == nil)
        #expect(model.worktreeNote(at: fixture.linked)?.status == .inReview)

        model.setWorktreeStatus(nil, at: fixture.linked)
        #expect(model.worktreeNote(at: fixture.linked) == nil)
        model.persistImmediately()
        #expect(WorkspaceStore(url: fixture.store).load().worktreeNotes.isEmpty)
    }

    @Test("A path git does not list for any project is not noted")
    func unlistedPath() async throws {
        let directory = try TemporaryDirectory()
        let fixture = try await fixture(in: directory)
        let nowhere = fixture.root + "-elsewhere"

        #expect(fixture.model.canNoteWorktree(at: fixture.linked))
        #expect(!fixture.model.canNoteWorktree(at: nowhere))
        fixture.model.setWorktreeStatus(.todo, at: nowhere)
        #expect(fixture.model.worktreeNote(at: nowhere) == nil)
    }

    @Test("A worktree git stops listing takes its note with it, and the others keep theirs")
    func droppedWhenGone() async throws {
        let directory = try TemporaryDirectory()
        let fixture = try await fixture(in: directory)
        let model = fixture.model
        model.setWorktreeStatus(.completed, at: fixture.linked)
        model.setWorktreeComment("main is green", at: fixture.root)
        let linked = try #require(model.worktrees[fixture.project]?.first { $0.path == fixture.linked })

        #expect(GitWorktreeActions.remove(linked, force: true, in: fixture.root) == nil)
        model.refreshGit(for: fixture.project)
        try await waitUntil { model.worktrees[fixture.project]?.count == 1 }

        #expect(model.worktreeNote(at: fixture.linked) == nil)
        #expect(model.worktreeNote(at: fixture.root)?.comment == "main is green")
    }

    @Test("A list that could not be read leaves every note where it was")
    func keptWhenGitCannotAnswer() async throws {
        let directory = try TemporaryDirectory()
        let fixture = try await fixture(in: directory)
        let model = fixture.model
        model.setWorktreeStatus(.inProgress, at: fixture.linked)

        // With the repository gone from where the project says it is, git has
        // no list to give; that is not a list with nothing in it.
        try FileManager.default.moveItem(atPath: fixture.root, toPath: fixture.root + "-moved")
        // The status is dropped in the same turn a list would have been
        // adopted, so once it has gone the list has been given its chance.
        // Asked again while waiting, as the sidebar's timer would: adding a
        // project refreshes it twice, and the second can land after the move
        // with a status it read before it.
        var polls = 0
        try await waitUntil {
            if polls % 25 == 0 { model.refreshGit(for: fixture.project) }
            polls += 1
            return model.gitStatuses[fixture.project] == nil
        }

        #expect(model.worktreeNote(at: fixture.linked)?.status == .inProgress)
    }

    @Test("Removing a project removes what was said about its worktrees")
    func removedWithTheProject() async throws {
        let directory = try TemporaryDirectory()
        let fixture = try await fixture(in: directory)
        let model = fixture.model
        model.setWorktreeStatus(.todo, at: fixture.linked)

        model.removeProject(fixture.project)
        #expect(model.worktreeNote(at: fixture.linked) == nil)
        model.persistImmediately()
        #expect(WorkspaceStore(url: fixture.store).load().worktreeNotes.isEmpty)
    }
}
