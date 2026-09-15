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
