import Foundation
import Testing

@testable import RelayAppKit
@testable import RelayProtocol

@Suite("Workspace persistence")
struct WorkspaceStoreTests {
    @Test("A missing file yields empty state rather than failing")
    func missingFileIsEmptyState() throws {
        let directory = try TemporaryDirectory()
        let store = WorkspaceStore(url: directory.url.appendingPathComponent("absent.json"))
        let state = store.load()
        #expect(state.projects.isEmpty)
        #expect(state.lastActiveProjectID == nil)
    }

    @Test("State survives a save and load round trip")
    func roundTrip() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        let store = WorkspaceStore(url: url)

        var project = Project(name: "Storefront", rootPath: "/Users/test/storefront")
        project.defaultAgent = .codex
        project.defaultServiceCommand = "pnpm run dev"
        project.preferredEditor = "cursor"

        let saved = WorkspaceState(
            projects: [project],
            lastActiveProjectID: project.id.rawValue,
            lastActiveSessionByProject: [project.id.rawValue: "session-7"],
            sidebarWidth: 310,
            collapsedSections: ["docker"]
        )
        store.saveNow(saved)

        let loaded = WorkspaceStore(url: url).load()
        #expect(loaded.projects.count == 1)
        #expect(loaded.projects[0].id == project.id)
        #expect(loaded.projects[0].name == "Storefront")
        #expect(loaded.projects[0].defaultAgent == .codex)
        #expect(loaded.projects[0].defaultServiceCommand == "pnpm run dev")
        #expect(loaded.lastActiveProjectID == project.id.rawValue)
        #expect(loaded.lastActiveSessionByProject[project.id.rawValue] == "session-7")
        #expect(loaded.sidebarWidth == 310)
        #expect(loaded.collapsedSections == ["docker"])
    }

    @Test("A corrupt file is quarantined and startup still succeeds")
    func corruptFileIsQuarantined() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        try "{ not valid json at all".write(to: url, atomically: true, encoding: .utf8)

        let state = WorkspaceStore(url: url).load()
        #expect(state.projects.isEmpty)
        // The original is kept for forensics rather than silently destroyed.
        #expect(FileManager.default.fileExists(atPath: url.appendingPathExtension("corrupt").path))
    }

    @Test("Saving twice leaves no temporary file behind")
    func atomicWriteLeavesNoTemporaries() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        let store = WorkspaceStore(url: url)
        store.saveNow(WorkspaceState())
        store.saveNow(WorkspaceState(projects: [Project(name: "A", rootPath: "/tmp")]))

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.url.path)
        #expect(contents.contains("workspace.json"))
        #expect(!contents.contains { $0.hasSuffix(".tmp") })
    }

    @Test("Debounced saves eventually reach disk")
    func scheduledSaveIsFlushed() async throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        let store = WorkspaceStore(url: url)

        // Rapid UI changes must collapse into a single write.
        for index in 0 ..< 5 {
            store.scheduleSave(WorkspaceState(projects: [Project(name: "P\(index)", rootPath: "/tmp")]))
        }
        try await Task.sleep(for: .milliseconds(900))

        let loaded = WorkspaceStore(url: url).load()
        #expect(loaded.projects.map(\.name) == ["P4"])
    }
}

@Suite("Project model")
struct ProjectTests {
    @Test("The first session of a kind has no number")
    func firstSessionIsUnnumbered() {
        #expect(SessionNaming.nextName(for: .claude, existing: []) == "Claude")
        #expect(SessionNaming.nextName(for: .shell, existing: ["Claude"]) == "Terminal")
    }

    @Test("Numbering starts at two and skips names already in use")
    func numbersFollowExistingSessions() {
        #expect(SessionNaming.nextName(for: .claude, existing: ["Claude"]) == "Claude 2")
        #expect(SessionNaming.nextName(for: .claude, existing: ["Claude", "Claude 2"]) == "Claude 3")
    }

    @Test("Closing a session frees its name again")
    func namesAreReused() {
        // The old counter-based scheme produced "Claude 4" for a lone session
        // after three restarts, which is exactly what this prevents.
        #expect(SessionNaming.nextName(for: .claude, existing: []) == "Claude")
        #expect(SessionNaming.nextName(for: .claude, existing: ["Claude 2"]) == "Claude")
        #expect(SessionNaming.nextName(for: .claude, existing: ["Claude", "Claude 3"]) == "Claude 2")
    }

    @Test("Counters are independent across kinds")
    func kindsDoNotShareNumbering() {
        let existing = ["Claude", "Claude 2", "Terminal"]
        #expect(SessionNaming.nextName(for: .claude, existing: existing) == "Claude 3")
        #expect(SessionNaming.nextName(for: .shell, existing: existing) == "Terminal 2")
        #expect(SessionNaming.nextName(for: .codex, existing: existing) == "Codex")
    }

    @Test("A renamed session still occupies its name")
    func respectsRenamedSessions() {
        #expect(SessionNaming.nextName(for: .claude, existing: ["refactor auth", "Claude"]) == "Claude 2")
    }

    @Test("SSH sessions are numbered by host alias")
    func sshNaming() {
        #expect(SessionNaming.nextName(base: "staging", existing: []) == "staging")
        #expect(SessionNaming.nextName(base: "staging", existing: ["staging"]) == "staging 2")
    }

    @Test("Paths under home are abbreviated with a tilde")
    func displayPathAbbreviatesHome() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let project = Project(name: "Test", rootPath: "\(home)/Documents/code/app")
        #expect(project.displayPath == "~/Documents/code/app")
    }

    @Test("Paths outside home are shown in full")
    func displayPathOutsideHome() {
        let project = Project(name: "Test", rootPath: "/opt/services/api")
        #expect(project.displayPath == "/opt/services/api")
    }
}
