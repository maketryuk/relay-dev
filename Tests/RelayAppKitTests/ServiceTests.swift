import Foundation
import Testing

@testable import RelayAppKit
@testable import RelayProtocol

@Suite("Service definitions")
struct ServiceDefinitionTests {
    @Test("The command is handed to a shell verbatim rather than split on spaces")
    func commandIsNotSplit() {
        // Splitting would destroy quoting, `&&` chains and environment prefixes.
        let service = ServiceDefinition(name: "Dev", command: "PORT=4000 pnpm run dev -- --host")
        #expect(service.argv == ["/bin/sh", "-c", "PORT=4000 pnpm run dev -- --host"])
    }

    @Test("Each definition gets a distinct identity")
    func distinctIdentity() {
        let first = ServiceDefinition(name: "Dev", command: "npm run dev")
        let second = ServiceDefinition(name: "Dev", command: "npm run dev")
        #expect(first.id != second.id)
    }

    @Test("The default service is the flagged one, or the first as a fallback")
    func defaultServiceSelection() {
        var project = Project(name: "Test", rootPath: "/tmp")
        #expect(project.defaultService == nil)

        project.services = [
            ServiceDefinition(name: "API", command: "go run ."),
            ServiceDefinition(name: "Web", command: "pnpm dev", isDefault: true),
        ]
        #expect(project.defaultService?.name == "Web")

        project.services = [ServiceDefinition(name: "Only", command: "make run")]
        #expect(project.defaultService?.name == "Only")
    }

    @Test("Services survive a persistence round trip")
    func servicesPersist() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")

        var project = Project(name: "Test", rootPath: "/tmp")
        project.services = [
            ServiceDefinition(name: "Dev", command: "pnpm dev", isDefault: true, urlOverride: "http://localhost:4321"),
        ]
        WorkspaceStore(url: url).saveNow(WorkspaceState(projects: [project]))

        let loaded = WorkspaceStore(url: url).load().projects[0]
        #expect(loaded.services.count == 1)
        #expect(loaded.services[0].name == "Dev")
        #expect(loaded.services[0].isDefault)
        #expect(loaded.services[0].urlOverride == "http://localhost:4321")
    }

    @Test("A workspace written before services existed still loads")
    func decodesProjectWithoutServices() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        try #"{"projects":[{"id":"X","name":"Old","rootPath":"/tmp"}]}"#
            .write(to: url, atomically: true, encoding: .utf8)
        #expect(WorkspaceStore(url: url).load().projects[0].services.isEmpty)
    }
}

@Suite("Service state derivation")
struct ServiceStateTests {
    private func snapshot(status: RuntimeStatus, exitCode: Int32? = nil) -> SessionSnapshot {
        SessionSnapshot(
            id: .generate(),
            projectID: .generate(),
            kind: .custom,
            name: "Dev",
            workingDirectory: "/tmp",
            command: ["/bin/sh", "-c", "pnpm dev"],
            status: status,
            pid: 100,
            exitCode: exitCode,
            startedAt: Date(),
            lastActivityAt: Date(),
            columns: 120,
            rows: 32,
            role: .service(id: "svc-1")
        )
    }

    @Test("No session at all means stopped")
    func noSessionIsStopped() {
        #expect(ServiceState.derive(from: nil) == .stopped)
    }

    @Test("A live session is starting or running")
    func liveSessionStates() {
        #expect(ServiceState.derive(from: snapshot(status: .starting)) == .starting)
        #expect(ServiceState.derive(from: snapshot(status: .working)) == .running)
        // A dev server that goes quiet between rebuilds is still running.
        #expect(ServiceState.derive(from: snapshot(status: .idle)) == .running)
        #expect(ServiceState.derive(from: snapshot(status: .finished)) == .running)
    }

    @Test("A session reporting an error is a failed service even before it exits")
    func erroredSessionIsFailed() {
        #expect(ServiceState.derive(from: snapshot(status: .error)) == .failed)
    }

    @Test("Exit code decides between stopped and failed")
    func exitCodeDecidesOutcome() {
        #expect(ServiceState.derive(from: snapshot(status: .finished, exitCode: 0)) == .stopped)
        #expect(ServiceState.derive(from: snapshot(status: .error, exitCode: 1)) == .failed)
        #expect(ServiceState.derive(from: snapshot(status: .finished, exitCode: 137)) == .failed)
    }

    @Test("Only live states count as active")
    func activeStates() {
        #expect(ServiceState.running.isActive)
        #expect(ServiceState.starting.isActive)
        #expect(ServiceState.stopping.isActive)
        #expect(!ServiceState.stopped.isActive)
        #expect(!ServiceState.failed.isActive)
    }

    @Test("Service states colour the same way as everything else")
    func statusMapping() {
        #expect(ServiceState.stopped.runtimeStatus == .offline)
        #expect(ServiceState.starting.runtimeStatus == .starting)
        #expect(ServiceState.running.runtimeStatus == .working)
        #expect(ServiceState.failed.runtimeStatus == .error)
    }
}

@Suite("Session roles")
struct SessionRoleTests {
    @Test("An interactive session carries no service identity")
    func interactiveRole() {
        #expect(SessionRole.interactive.serviceID == nil)
        #expect(!SessionRole.interactive.isService)
    }

    @Test("A service session names the definition it belongs to")
    func serviceRole() {
        let role = SessionRole.service(id: "svc-42")
        #expect(role.serviceID == "svc-42")
        #expect(role.isService)
    }

    @Test("Roles survive the wire so a restarted GUI can rebuild the mapping")
    func roleRoundTrip() throws {
        let encoder = MessageFraming.makeEncoder()
        let decoder = MessageFraming.makeDecoder()
        for role in [SessionRole.interactive, .service(id: "svc-1")] {
            let data = try encoder.encode(role)
            #expect(try decoder.decode(SessionRole.self, from: data) == role)
        }
    }

    @Test("A spec from a peer that predates roles decodes as interactive")
    func legacySpecDecodesAsInteractive() throws {
        let legacy = """
        {"projectID":"p","kind":"shell","name":"Shell","workingDirectory":"/tmp","command":[],
         "environment":{},"columns":80,"rows":24}
        """
        let spec = try MessageFraming.makeDecoder().decode(SessionSpec.self, from: Data(legacy.utf8))
        #expect(spec.role == .interactive)
    }
}

@Suite("Port grouping")
struct PortGroupingTests {
    private let projectID = ProjectID(rawValue: "mine")

    private func port(
        _ number: Int,
        process: String = "node",
        owner: ProjectID? = nil,
        ownerName: String? = nil
    ) -> ListeningPort {
        ListeningPort(
            port: number,
            address: "*",
            pid: Int32(number),
            processName: process,
            ownerSessionID: owner == nil ? nil : .generate(),
            ownerName: ownerName,
            ownerProjectID: owner
        )
    }

    @Test("Filtering matches port number, process name and owner")
    func filtering() {
        let all = [
            port(3000, process: "node", owner: projectID, ownerName: "Dev"),
            port(5432, process: "postgres"),
            port(6379, process: "redis-server"),
        ]
        #expect(PortFiltering.matches(all[0], query: "3000"))
        #expect(PortFiltering.matches(all[1], query: "postgres"))
        #expect(PortFiltering.matches(all[0], query: "dev"))
        #expect(!PortFiltering.matches(all[2], query: "postgres"))
        // An empty query keeps everything.
        #expect(all.allSatisfy { PortFiltering.matches($0, query: "") })
    }

    @Test("Matching is case-insensitive")
    func caseInsensitiveFilter() {
        #expect(PortFiltering.matches(port(5432, process: "Postgres"), query: "POSTGRES"))
    }
}

@Suite("Session history")
struct SessionHistoryTests {
    private let projectID = ProjectID(rawValue: "p1")

    private func entry(id: String, ended: Date = Date(), exitCode: Int32? = 0) -> SessionHistoryEntry {
        var snapshot = SessionSnapshot(
            id: SessionID(rawValue: id),
            projectID: projectID,
            kind: .claude,
            name: "Claude",
            workingDirectory: "/tmp",
            command: ["claude"],
            status: .finished,
            pid: 1,
            exitCode: exitCode,
            startedAt: ended.addingTimeInterval(-90),
            lastActivityAt: ended,
            columns: 80,
            rows: 24
        )
        snapshot.title = "refactoring"
        return SessionHistoryEntry(from: snapshot, endedAt: ended)
    }

    @Test("A finished run keeps what it was and how it ended")
    func capturesTheRun() {
        let record = entry(id: "s1", exitCode: 3)
        #expect(record.name == "refactoring")
        #expect(record.kind == .claude)
        #expect(record.command == ["claude"])
        #expect(!record.succeeded)
        #expect(record.duration == 90)
    }

    @Test("Newest runs come first")
    func newestFirst() {
        var history: [SessionHistoryEntry] = []
        history = SessionHistory.appending(entry(id: "old"), to: history)
        history = SessionHistory.appending(entry(id: "new"), to: history)
        #expect(history.map(\.id) == ["new", "old"])
    }

    @Test("A run reported twice is recorded once")
    func deduplicatesByIdentity() {
        // A session can end with an exit event and then be forgotten, which
        // would otherwise leave two identical rows.
        var history = SessionHistory.appending(entry(id: "s1"), to: [])
        history = SessionHistory.appending(entry(id: "s1"), to: history)
        #expect(history.count == 1)
    }

    @Test("History is capped so the workspace file cannot grow without end")
    func respectsTheLimit() {
        var history: [SessionHistoryEntry] = []
        for index in 0 ..< (SessionHistory.limit + 40) {
            history = SessionHistory.appending(entry(id: "s\(index)"), to: history)
        }
        #expect(history.count == SessionHistory.limit)
        // The oldest entries are the ones dropped.
        #expect(history.first?.id == "s\(SessionHistory.limit + 39)")
    }

    @Test("Entries are filtered by project")
    func filtersByProject() {
        var other = entry(id: "s2")
        other.projectID = ProjectID(rawValue: "p2")
        let history = [entry(id: "s1"), other]
        #expect(SessionHistory.entries(in: history, for: projectID).map(\.id) == ["s1"])
    }

    @Test("Durations read as a person would say them")
    func formatsDuration() {
        let now = Date()
        var short = entry(id: "a", ended: now)
        short.startedAt = now.addingTimeInterval(-45)
        #expect(short.durationText == "45s")

        var medium = entry(id: "b", ended: now)
        medium.startedAt = now.addingTimeInterval(-125)
        #expect(medium.durationText == "2m 5s")

        var long = entry(id: "c", ended: now)
        long.startedAt = now.addingTimeInterval(-7_500)
        #expect(long.durationText == "2h 5m")
    }

    @Test("History survives persistence and is absent from older files")
    func persists() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        WorkspaceStore(url: url).saveNow(WorkspaceState(sessionHistory: [entry(id: "s1")]))

        let loaded = WorkspaceStore(url: url).load()
        #expect(loaded.sessionHistory.count == 1)
        #expect(loaded.sessionHistory[0].name == "refactoring")

        try #"{"projects":[]}"#.write(to: url, atomically: true, encoding: .utf8)
        let legacy = WorkspaceStore(url: url).load()
        #expect(legacy.sessionHistory.isEmpty)
        #expect(legacy.isRightSidebarVisible)
    }
}

@Suite("Right sidebar tabs")
struct RightSidebarTabTests {
    @Test("Every tab has a title and an icon")
    func metadata() {
        for tab in RightSidebarTab.allCases {
            #expect(!tab.title.isEmpty)
            #expect(!tab.symbolName.isEmpty)
        }
    }

    @Test("Planned tabs are shown but disabled rather than hidden")
    func plannedTabsAreDisabled() {
        // Hiding them would misrepresent where the app is going; half-working
        // ones would be worse.
        #expect(RightSidebarTab.services.isAvailable)
        #expect(RightSidebarTab.docker.isAvailable)
        #expect(RightSidebarTab.history.isAvailable)
        #expect(!RightSidebarTab.git.isAvailable)
        #expect(!RightSidebarTab.files.isAvailable)
        #expect(!RightSidebarTab.git.comingSoonDescription.isEmpty)
        #expect(!RightSidebarTab.files.comingSoonDescription.isEmpty)
    }

    @Test("Tabs round-trip through their stored identifier")
    func codable() {
        for tab in RightSidebarTab.allCases {
            #expect(RightSidebarTab(rawValue: tab.rawValue) == tab)
        }
        #expect(RightSidebarTab(rawValue: "removed-tab") == nil)
    }
}
