import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("What a relay command is about")
struct ControlTargetsTests {
    private let shop = Project(id: ProjectID(rawValue: "shop"), name: "shop", rootPath: "/Users/me/code/shop")
    private let blog = Project(id: ProjectID(rawValue: "blog"), name: "blog", rootPath: "/Users/me/code/blog")

    private func worktree(_ path: String, branch: String?, isMain: Bool = false) -> GitWorktree {
        GitWorktree(path: path, branch: branch, head: nil, isMain: isMain, isLocked: false, isPrunable: false)
    }

    private var shopWorktrees: [GitWorktree] {
        [
            worktree("/Users/me/code/shop", branch: "main", isMain: true),
            worktree("/Users/me/.relay/worktrees/shop/fix-login", branch: "fix/login"),
            worktree("/Users/me/code/shop/.claude/worktrees/spike", branch: nil),
        ]
    }

    private func project(
        session: ProjectID? = nil,
        in directory: String,
        canonical: @escaping (String) -> String = { $0 }
    ) -> ProjectID? {
        ControlTargets.project(
            sessionProject: session,
            directory: directory,
            projects: [shop, blog],
            worktrees: [shop.id: shopWorktrees],
            canonical: canonical
        )
    }

    @Test("The terminal's own project wins over where its shell has wandered")
    func sessionProjectWins() {
        #expect(project(session: blog.id, in: "/Users/me/code/shop/src") == blog.id)
    }

    @Test("A session in no known project, the chat's say, falls back to the directory")
    func unknownSessionProject() {
        #expect(project(session: ProjectID(rawValue: "relay.chat"), in: "/Users/me/code/shop") == shop.id)
    }

    @Test("A worktree outside the project's folder still belongs to the project")
    func worktreeFolderCounts() {
        #expect(project(in: "/Users/me/.relay/worktrees/shop/fix-login/Sources") == shop.id)
        #expect(project(in: "/Users/me/code/blog/posts") == blog.id)
    }

    @Test("A sibling folder with a longer name is not inside the project")
    func siblingIsNotInside() {
        #expect(project(in: "/Users/me/code/shop-staging") == nil)
        #expect(project(in: "/Users/me") == nil)
    }

    @Test("A project added through a link is found from the spelling getcwd gives")
    func symlinkedProject() {
        let linked = Project(id: ProjectID(rawValue: "linked"), name: "linked", rootPath: "/Users/me/link/app")
        let canonical: (String) -> String = { $0.replacingOccurrences(of: "/Users/me/link/", with: "/Volumes/Work/") }
        let found = ControlTargets.project(
            sessionProject: nil,
            directory: "/Volumes/Work/app/src",
            projects: [linked],
            worktrees: [:],
            canonical: canonical
        )
        #expect(found == linked.id)
    }

    @Test("Without a name, the worktree the command runs in; the deepest, when one is inside another")
    func currentWorktree() throws {
        let inner = try ControlTargets.worktree(nil, from: "/Users/me/code/shop/.claude/worktrees/spike/a", among: shopWorktrees).get()
        #expect(inner.path == "/Users/me/code/shop/.claude/worktrees/spike")
        let outer = try ControlTargets.worktree(nil, from: "/Users/me/code/shop/src", among: shopWorktrees).get()
        #expect(outer.branch == "main")
        #expect(failure(ControlTargets.worktree(nil, from: "/tmp", among: shopWorktrees)) == .notInWorktree)
    }

    @Test("A name is a branch first, then a folder")
    func byName() throws {
        #expect(try ControlTargets.worktree("fix/login", from: "/", among: shopWorktrees).get().branch == "fix/login")
        #expect(try ControlTargets.worktree("fix-login", from: "/", among: shopWorktrees).get().branch == "fix/login")
        #expect(try ControlTargets.worktree("spike", from: "/", among: shopWorktrees).get().branch == nil)
        #expect(failure(ControlTargets.worktree("nope", from: "/", among: shopWorktrees)) == .noSuchWorktree)
    }

    @Test("A folder name two worktrees share is refused rather than guessed")
    func ambiguousFolder() {
        let twins = [
            worktree("/Users/me/.relay/worktrees/shop/api", branch: "api-v1"),
            worktree("/Users/me/.relay/worktrees/other/api", branch: "api-v2"),
        ]
        #expect(failure(ControlTargets.worktree("api", from: "/", among: twins)) == .ambiguousWorktree)
    }

    @Test("A path has to be a worktree's own folder, however it is written")
    func byPath() throws {
        let fromInside = "/Users/me/.relay/worktrees/shop/fix-login"
        #expect(try ControlTargets.worktree(".", from: fromInside, among: shopWorktrees).get().path == fromInside)
        #expect(try ControlTargets.worktree("../fix-login/", from: fromInside, among: shopWorktrees).get().path == fromInside)
        #expect(try ControlTargets.worktree("/Users/me/code/shop", from: "/", among: shopWorktrees).get().isMain)
        // Inside a worktree is not the worktree: `rm ./src` must not remove the checkout src is in.
        #expect(failure(ControlTargets.worktree("./src", from: fromInside, among: shopWorktrees)) == .noSuchWorktree)
    }

    @Test("--agent finds a preset by name in any case, or by the agent it runs")
    func presets() {
        let presets = SessionPresets.defaultSet + [
            SessionPreset(name: "Claude · ask first", kind: .claude),
            SessionPreset(name: "Empty", kind: .custom, customCommand: ""),
        ]
        #expect(ControlTargets.preset(named: "claude", in: presets)?.id == "preset.claude")
        #expect(ControlTargets.preset(named: "CODEX", in: presets)?.id == "preset.codex")
        #expect(ControlTargets.preset(named: "claude · ask first", in: presets)?.arguments == [])
        #expect(ControlTargets.preset(named: "terminal", in: presets)?.kind == .shell)
        #expect(ControlTargets.preset(named: "gemini", in: presets)?.kind == .gemini)
        #expect(ControlTargets.preset(named: "empty", in: presets) == nil)
        #expect(ControlTargets.preset(named: "vim", in: presets) == nil)

        let renamed = [SessionPreset(id: "mine", name: "My Claude", kind: .claude)]
        #expect(ControlTargets.preset(named: "claude", in: renamed)?.id == "mine")
    }

    private func failure(_ result: Result<GitWorktree, ControlFailure>) -> ControlFailure.Code? {
        if case let .failure(failure) = result { return failure.code }
        return nil
    }
}

/// The model answering requests about a real repository, with no daemon and no
/// window: what `relay worktree …` does, short of the socket.
@Suite("Answering relay commands", .serialized)
@MainActor
struct ControlHandlerTests {
    private struct Fixture {
        let model: AppModel
        let project: Project
        let root: String
        let base: URL
        let directories: [TemporaryDirectory]
    }

    private func fixture() throws -> Fixture {
        let directory = try TemporaryDirectory()
        let base = URL(fileURLWithPath: WorktreeMembership.canonical(directory.url.path))
        let root = base.appendingPathComponent("shop").path
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try Git.run(["init", "-b", "main"], in: root)
        try Git.run(["config", "user.email", "tests@relay.local"], in: root)
        try Git.run(["config", "user.name", "Relay Tests"], in: root)
        try "hello\n".write(toFile: root + "/file.txt", atomically: true, encoding: .utf8)
        try Git.run(["add", "."], in: root)
        try Git.run(["commit", "-m", "initial"], in: root)

        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        model.addProject(at: URL(fileURLWithPath: root))
        let project = try #require(model.projects.first)
        return Fixture(model: model, project: project, root: root, base: base, directories: [directory, store])
    }

    /// A worktree made the way someone would in a terminal, which Relay has
    /// not been told about.
    private func addWorktree(_ branch: String, to fixture: Fixture) throws -> String {
        let path = fixture.base.appendingPathComponent("worktrees/\(branch)").path
        try Git.run(["worktree", "add", "-b", branch, path], in: fixture.root)
        return path
    }

    private func ask(_ command: ControlCommand, from directory: String, of fixture: Fixture) async -> ControlResponse {
        await fixture.model.handleControl(ControlRequest(directory: directory, command: command))
    }

    @Test("list names every worktree, marks the one asked from, and finds one made a moment ago")
    func list() async throws {
        let fixture = try fixture()
        let spike = try addWorktree("spike", to: fixture)

        let response = await ask(.worktreeList, from: spike + "/", of: fixture)
        #expect(response.ok, "\(String(describing: response.error))")
        // As the project spells its folder, which is not always as git does.
        #expect(response.project?.path == fixture.project.rootPath)
        #expect(response.worktrees?.map(\.branch) == ["main", "spike"])
        #expect(response.worktrees?.map(\.isCurrent) == [false, true])
        #expect(response.worktrees?.first?.isProjectFolder == true)
        // The sidebar was given the same list.
        #expect(fixture.model.showsWorktrees(in: fixture.project.id))
    }

    @Test("current is the worktree the directory is in, and nothing outside a project")
    func current() async throws {
        let fixture = try fixture()
        let response = await ask(.worktreeCurrent, from: fixture.root, of: fixture)
        #expect(response.worktree?.branch == "main")

        let outside = await ask(.worktreeCurrent, from: "/", of: fixture)
        #expect(outside.error?.code == .notInProject)
    }

    @Test("set reaches the model's notes and answers with what they now say")
    func set() async throws {
        let fixture = try fixture()
        let spike = try addWorktree("spike", to: fixture)

        let response = await ask(
            .worktreeSet(target: "spike", status: .inReview, clearsStatus: false, comment: "ready"),
            from: fixture.root,
            of: fixture
        )
        #expect(response.ok, "\(String(describing: response.error))")
        #expect(response.worktree?.path == spike)
        #expect(response.worktree?.note == fixture.model.worktreeNote(at: spike))

        let nothing = await ask(.worktreeSet(target: nil, status: nil, clearsStatus: false, comment: nil), from: spike, of: fixture)
        #expect(nothing.error?.code == .invalidArgument)
    }

    @Test("rm refuses the project's own folder, and uncommitted work without --force")
    func removalRefusals() async throws {
        let fixture = try fixture()
        let spike = try addWorktree("spike", to: fixture)

        let home = await ask(.worktreeRemove(target: nil, force: true), from: fixture.root, of: fixture)
        #expect(home.error?.code == .refused)
        #expect(FileManager.default.fileExists(atPath: fixture.root))

        try "edited\n".write(toFile: spike + "/file.txt", atomically: true, encoding: .utf8)
        let dirty = await ask(.worktreeRemove(target: "spike", force: false), from: fixture.root, of: fixture)
        #expect(dirty.error?.code == .uncommittedChanges)
        #expect(dirty.error?.message.contains("--force") == true)
        #expect(FileManager.default.fileExists(atPath: spike))
    }

    @Test("rm removes a worktree, says what became of its branch, and the sidebar lets it go")
    func removal() async throws {
        let fixture = try fixture()
        let spike = try addWorktree("spike", to: fixture)
        try "edited\n".write(toFile: spike + "/file.txt", atomically: true, encoding: .utf8)

        let response = await ask(.worktreeRemove(target: spike, force: true), from: fixture.root, of: fixture)
        #expect(response.ok, "\(String(describing: response.error))")
        #expect(response.worktree?.path == spike)
        // Made in a terminal, so not Relay's to delete.
        #expect(response.branch == .untouched)
        #expect(!FileManager.default.fileExists(atPath: spike))
        #expect(!fixture.model.showsWorktrees(in: fixture.project.id))
    }

    @Test("create refuses an agent there is no preset for before making anything")
    func unknownPreset() async throws {
        let fixture = try fixture()
        let response = await ask(
            .worktreeCreate(name: "never-made", base: nil, agent: "vim", prompt: nil),
            from: fixture.root,
            of: fixture
        )
        #expect(response.error?.code == .noSuchPreset)
        #expect(!GitWorktreeActions.branchExists("never-made", in: fixture.root))
    }

    @Test("create refuses a branch already checked out, as New Worktree does")
    func alreadyOpen() async throws {
        let fixture = try fixture()
        _ = try addWorktree("spike", to: fixture)
        let response = await ask(.worktreeCreate(name: "spike", base: nil, agent: nil, prompt: nil), from: fixture.root, of: fixture)
        #expect(response.error?.code == .alreadyOpen)
    }
}
