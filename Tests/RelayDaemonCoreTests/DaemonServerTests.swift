import Foundation
import Testing

@testable import RelayDaemonCore
@testable import RelayProtocol

/// End-to-end coverage of the daemon over a real Unix socket with real PTYs.
/// Nothing here is mocked: these are the tests that prove the product's central
/// promise — sessions outlive their client.
@Suite("Daemon server", .serialized)
final class DaemonServerTests {
    private let harness: DaemonHarness
    private let client: TestClient

    init() throws {
        harness = try DaemonHarness()
        client = try harness.makeClient()
    }

    deinit {
        client.close()
        harness.shutdown()
    }

    // MARK: - Helpers

    private func makeSpec(
        kind: SessionKind = .shell,
        command: [String] = [],
        directory: String = "/tmp"
    ) -> SessionSpec {
        SessionSpec(
            projectID: ProjectID(rawValue: "test-project"),
            kind: kind,
            name: "Test Session",
            workingDirectory: directory,
            command: command
        )
    }

    private func createSession(_ spec: SessionSpec, on target: TestClient? = nil) throws -> SessionSnapshot {
        let connection = target ?? client
        let requestID = try connection.send(.createSession(spec))
        let messages = try connection.wait(timeout: 30) {
            $0.reply(to: requestID) != nil || $0.failure(to: requestID) != nil
        }
        guard case let .session(snapshot)? = messages.reply(to: requestID) else {
            throw TestFailure.message("createSession failed: \(String(describing: messages.failure(to: requestID)))")
        }
        return snapshot
    }

    private enum TestFailure: Error { case message(String) }

    // MARK: - Handshake

    @Test("A matching protocol version is accepted")
    func handshakeSucceeds() throws {
        let requestID = try client.send(.ping)
        let messages = try client.wait { $0.reply(to: requestID) != nil }
        guard case let .pong(version, protocolVersion, buildIdentity, uptime)? = messages.reply(to: requestID) else {
            Issue.record("Expected a pong")
            return
        }
        #expect(version == DaemonServer.version)
        #expect(protocolVersion == RelayProtocolVersion.current)
        #expect(uptime >= 0)
        // The GUI compares this against the daemon it ships with, so a stale
        // daemon left over from an earlier build can be spotted and retired.
        #expect(!buildIdentity.isEmpty)
        #expect(buildIdentity != "unknown")
    }

    @Test("A mismatched protocol version is rejected with both versions named")
    func handshakeRejectsWrongVersion() throws {
        let requestID = try client.send(.handshake(protocolVersion: 999, clientName: "old client"))
        let messages = try client.wait { $0.failure(to: requestID) != nil }
        let failure = messages.failure(to: requestID)
        #expect(failure?.code == "protocol_mismatch")
        #expect(failure?.message.contains("999") == true)
    }

    // MARK: - Session lifecycle

    @Test("Creating a session announces it to every client")
    func createSessionBroadcasts() throws {
        let snapshot = try createSession(makeSpec())
        #expect(snapshot.projectID.rawValue == "test-project")
        #expect(snapshot.pid != nil)

        let messages = try client.wait {
            $0.events.contains { if case .sessionCreated = $0 { true } else { false } }
        }
        let created = messages.events.compactMap { event -> SessionSnapshot? in
            if case let .sessionCreated(created) = event { created } else { nil }
        }
        #expect(created.contains { $0.id == snapshot.id })
    }

    @Test("Listing returns every live session in creation order")
    func listSessions() throws {
        let first = try createSession(makeSpec())
        let second = try createSession(makeSpec())

        let requestID = try client.send(.listSessions)
        let messages = try client.wait { $0.reply(to: requestID) != nil }
        guard case let .sessions(list)? = messages.reply(to: requestID) else {
            Issue.record("Expected a session list")
            return
        }
        #expect(list.map(\.id) == [first.id, second.id])
    }

    @Test("A command's output reaches an attached client")
    func outputReachesAttachedClient() throws {
        let session = try createSession(makeSpec(kind: .custom, command: ["echo", "DAEMON_MARKER"]))
        try client.send(.attach(session.id, replayScrollback: true))

        let messages = try client.wait {
            String(decoding: $0.output(for: session.id), as: UTF8.self).contains("DAEMON_MARKER")
        }
        #expect(String(decoding: messages.output(for: session.id), as: UTF8.self).contains("DAEMON_MARKER"))
    }

    @Test("Input typed by the user reaches the process")
    func inputReachesProcess() throws {
        let session = try createSession(makeSpec())
        try client.send(.attach(session.id, replayScrollback: true))
        try client.send(.input(session.id, Data("echo INPUT_ROUNDTRIP\n".utf8)))

        let messages = try client.wait {
            String(decoding: $0.output(for: session.id), as: UTF8.self).contains("INPUT_ROUNDTRIP")
        }
        #expect(String(decoding: messages.output(for: session.id), as: UTF8.self).contains("INPUT_ROUNDTRIP"))
    }

    @Test("A paste the process was not ready for arrives, in order, once it reads")
    func deferredInputArrives() throws {
        // More than the terminal holds while nothing reads it: the rest has
        // to wait for the process rather than be dropped.
        let session = try createSession(makeSpec(kind: .custom, command: ["/bin/sh", "-c", "sleep 1; cat"]))
        try client.send(.attach(session.id, replayScrollback: false))
        let lines = (1 ... 2_000).map { String(format: "line-%04d", $0) }
        try client.send(.input(session.id, Data((lines.joined(separator: "\n") + "\n").utf8)))

        let messages = try client.wait(timeout: 30) {
            String(decoding: $0.output(for: session.id), as: UTF8.self).contains("line-2000")
        }
        let printed = String(decoding: messages.output(for: session.id), as: UTF8.self)
        let positions = ["line-0001", "line-1000", "line-2000"].compactMap { printed.range(of: $0)?.lowerBound }
        #expect(positions.count == 3)
        #expect(positions == positions.sorted())
    }

    @Test("Renaming updates the snapshot and notifies clients")
    func renameSession() throws {
        let session = try createSession(makeSpec())
        let requestID = try client.send(.rename(session.id, name: "Renamed Session"))
        let messages = try client.wait { $0.reply(to: requestID) != nil }
        guard case let .session(renamed)? = messages.reply(to: requestID) else {
            Issue.record("Expected the renamed session")
            return
        }
        #expect(renamed.name == "Renamed Session")
    }

    @Test("Operating on an unknown session is a clean error, not a crash")
    func unknownSessionIsRejected() throws {
        let ghost = SessionID(rawValue: "does-not-exist")
        let requestID = try client.send(.input(ghost, Data("x".utf8)))
        let messages = try client.wait { $0.failure(to: requestID) != nil }
        #expect(messages.failure(to: requestID)?.code == "unknown_session")
    }

    @Test("Forgetting a session removes it from the registry")
    func forgetSession() throws {
        let session = try createSession(makeSpec())
        try client.send(.terminate(session.id))
        let requestID = try client.send(.forget(session.id))
        try client.wait { $0.reply(to: requestID) != nil }

        let listID = try client.send(.listSessions)
        let messages = try client.wait { $0.reply(to: listID) != nil }
        guard case let .sessions(list)? = messages.reply(to: listID) else {
            Issue.record("Expected a session list")
            return
        }
        #expect(!list.contains { $0.id == session.id })
        #expect(messages.events.contains { if case .sessionRemoved = $0 { true } else { false } })
    }

    // MARK: - Status derivation

    @Test("A freshly started shell settles into idle, never finished")
    func freshSessionBecomesIdle() throws {
        // A .zshrc banner is not work the user asked for.
        let session = try createSession(makeSpec())
        let messages = try client.wait(timeout: 30) {
            $0.snapshots(for: session.id).contains { $0.status == .idle }
        }
        let statuses = messages.snapshots(for: session.id).map(\.status)
        #expect(statuses.contains(.idle))
        #expect(!statuses.contains(.finished))
    }

    @Test("Running a command moves the session through working to finished")
    func commandProducesWorkingThenFinished() throws {
        let session = try createSession(makeSpec())
        try client.send(.attach(session.id, replayScrollback: false))
        // Let the startup banner settle so the transition is unambiguous.
        try client.wait(timeout: 30) { $0.snapshots(for: session.id).contains { $0.status == .idle } }

        try client.send(.input(session.id, Data("for i in 1 2 3 4 5 6 7 8; do echo line-$i-padding-padding; done\n".utf8)))
        let messages = try client.wait(timeout: 30) {
            $0.snapshots(for: session.id).contains { $0.status == .finished }
        }
        let statuses = messages.snapshots(for: session.id).map(\.status)
        #expect(statuses.contains(.working))
        #expect(statuses.last == .finished)
    }

    @Test("A question from the process is reported as waiting for the user")
    func promptProducesWaiting() throws {
        let session = try createSession(makeSpec())
        try client.send(.attach(session.id, replayScrollback: false))
        try client.wait(timeout: 30) { $0.snapshots(for: session.id).contains { $0.status == .idle } }

        // A realistic prompt: the question is printed and the process then
        // blocks. A shell that printed a question and immediately returned to
        // its prompt would have overwritten the question on screen, and Relay
        // should not claim the user is blocked in that case.
        try client.send(.input(session.id, Data("printf 'Overwrite file? (y/n) '; read answer\n".utf8)))
        let messages = try client.wait(timeout: 30) {
            $0.snapshots(for: session.id).contains { $0.status == .waiting }
        }
        #expect(messages.snapshots(for: session.id).contains { $0.status == .waiting })

        // Answering unblocks it.
        try client.send(.input(session.id, Data("y\n".utf8)))
        let resumed = try client.wait(timeout: 30) {
            $0.snapshots(for: session.id).suffix(3).contains { $0.status != .waiting }
        }
        #expect(resumed.snapshots(for: session.id).last?.status != .waiting)
    }

    @Test("A user-requested terminate is reported as finished, not as an error")
    func terminateIsNotAnError() throws {
        let session = try createSession(makeSpec())
        try client.wait(timeout: 30) { $0.snapshots(for: session.id).contains { $0.status == .idle } }
        try client.send(.terminate(session.id))

        let messages = try client.wait(timeout: 30) {
            $0.snapshots(for: session.id).contains { $0.exitCode != nil }
        }
        let final = messages.snapshots(for: session.id).last { $0.exitCode != nil }
        #expect(final?.status == .finished)
    }

    @Test("A command that fails on its own is reported as an error")
    func failureIsReportedAsError() throws {
        let session = try createSession(makeSpec(kind: .custom, command: ["sh", "-c", "exit 3"]))
        let messages = try client.wait(timeout: 30) {
            $0.snapshots(for: session.id).contains { $0.exitCode != nil }
        }
        let final = messages.snapshots(for: session.id).last { $0.exitCode != nil }
        #expect(final?.status == .error)
        #expect(final?.exitCode == 3)
    }

    @Test("A service-role session keeps its tag through the daemon and a reconnect")
    func serviceRoleSurvivesRoundTrip() throws {
        var spec = makeSpec(kind: .custom, command: ["sleep", "20"])
        spec.role = .service(id: "svc-dev")
        let session = try createSession(spec)
        #expect(session.role == .service(id: "svc-dev"))

        // A relaunched GUI must be able to map the running process back to the
        // service row in the sidebar.
        let reconnected = try harness.makeClient()
        defer { reconnected.close() }
        let listID = try reconnected.send(.listSessions)
        let messages = try reconnected.wait(timeout: 30) { $0.reply(to: listID) != nil }
        guard case let .sessions(list)? = messages.reply(to: listID) else {
            Issue.record("Expected a session list")
            return
        }
        #expect(list.first { $0.id == session.id }?.role.serviceID == "svc-dev")

        try client.send(.terminate(session.id))
    }

    // MARK: - Ports

    @Test("A port bound deep in a session's process tree is discovered")
    func discoversListeningPort() throws {
        // The listener is a grandchild of the process Relay spawned, which is
        // exactly the shape `npm run dev` produces.
        let port = Int.random(in: 42_000 ... 45_000)
        let script = """
        import socket, time
        server = socket.socket()
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", \(port)))
        server.listen(1)
        time.sleep(60)
        """
        let session = try createSession(makeSpec(kind: .custom, command: ["python3", "-c", script]))

        var discovered: [ListeningPort] = []
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let requestID = try client.send(.listPorts(session.projectID))
            let messages = try client.wait(timeout: 30) { $0.reply(to: requestID) != nil }
            if case let .ports(found)? = messages.reply(to: requestID), found.contains(where: { $0.port == port }) {
                discovered = found
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        let match = discovered.first { $0.port == port }
        #expect(match != nil)
        #expect(match?.ownerSessionID == session.id)
        #expect(match?.ownerName == "Test Session")
        #expect(match?.ownerProjectID == session.projectID)
        #expect(match?.isManagedByRelay == true)
        #expect(match?.isLocallyReachable == true)

        // Anything Relay did not start must not be claimed. Asserting that such
        // a port *exists* would be testing the machine rather than the code —
        // a clean CI runner has nothing else listening.
        #expect(discovered.allSatisfy { $0.isManagedByRelay == ($0.ownerSessionID != nil) })

        try client.send(.terminate(session.id))
    }

    @Test("A project with no processes still sees the machine's ports, owned by nobody")
    func unattributedPortsForEmptyProject() throws {
        let requestID = try client.send(.listPorts(ProjectID(rawValue: "project-with-nothing")))
        let messages = try client.wait(timeout: 30) { $0.reply(to: requestID) != nil }
        guard case let .ports(found)? = messages.reply(to: requestID) else {
            Issue.record("Expected a port list")
            return
        }
        // Nothing this project started, so nothing may be attributed to it — but
        // whatever else is listening on the machine is still reported.
        #expect(found.allSatisfy { $0.ownerProjectID?.rawValue != "project-with-nothing" })
        #expect(found.allSatisfy { !$0.isManagedByRelay })
    }

    @Test("A title the program announces becomes the session's name")
    func reportedTitleReachesTheSnapshot() throws {
        // Agents name their own session by setting the terminal title; the
        // daemon has to carry that through to the UI.
        let session = try createSession(makeSpec(
            kind: .custom,
            command: ["sh", "-c", "printf '\\033]0;refactoring the parser\\007'; sleep 5"]
        ))

        let messages = try client.wait(timeout: 30) {
            $0.snapshots(for: session.id).contains { $0.title == "refactoring the parser" }
        }
        let latest = try #require(messages.snapshots(for: session.id).last { $0.title != nil })
        #expect(latest.displayName == "refactoring the parser")
        #expect(!latest.isNameUserDefined)

        // Renaming by hand wins from then on.
        let renameID = try client.send(.rename(session.id, name: "my name"))
        let renamed = try client.wait(timeout: 30) { $0.reply(to: renameID) != nil }
        guard case let .session(snapshot)? = renamed.reply(to: renameID) else {
            Issue.record("Expected the renamed session")
            return
        }
        #expect(snapshot.isNameUserDefined)
        #expect(snapshot.displayName == "my name")

        try client.send(.terminate(session.id))
    }

    @Test("A process can be stopped from the ports list")
    func terminateProcessByPID() throws {
        let session = try createSession(makeSpec(kind: .custom, command: ["sh", "-c", "exec sleep 60"]))
        let pid = try #require(session.pid)
        #expect(kill(pid, 0) == 0)

        let requestID = try client.send(.terminateProcess(pid: pid, force: false))
        let messages = try client.wait(timeout: 30) { $0.reply(to: requestID) != nil }
        guard case let .commandOutput(status, _)? = messages.reply(to: requestID) else {
            Issue.record("Expected a command result")
            return
        }
        #expect(status == 0)

        try client.wait(timeout: 30) {
            $0.snapshots(for: session.id).contains { $0.exitCode != nil }
        }
    }

    @Test("Stopping a process that is not there is reported, not ignored")
    func terminateMissingProcess() throws {
        let requestID = try client.send(.terminateProcess(pid: 999_999, force: false))
        let messages = try client.wait(timeout: 30) { $0.reply(to: requestID) != nil }
        guard case let .commandOutput(status, output)? = messages.reply(to: requestID) else {
            Issue.record("Expected a command result")
            return
        }
        #expect(status != 0)
        #expect(output.contains("999999"))
    }

    @Test("Signalling init is refused")
    func refusesToSignalInit() throws {
        // A mistyped pid should not be able to ask the daemon to shoot the
        // system in the foot.
        for pid in [Int32(0), 1, -1] {
            let requestID = try client.send(.terminateProcess(pid: pid, force: true))
            let messages = try client.wait(timeout: 30) { $0.reply(to: requestID) != nil }
            guard case let .commandOutput(status, _)? = messages.reply(to: requestID) else {
                Issue.record("Expected a command result")
                return
            }
            #expect(status != 0)
        }
    }

    // MARK: - Upgrade path

    @Test("A daemon that rejected the handshake can still be asked to stop")
    func shutdownWorksAfterProtocolMismatch() throws {
        // This is the whole upgrade path: a newer client meets an older daemon,
        // the handshake is refused, and the only way forward is to retire it.
        // If a rejected handshake also closed the door on `shutdownDaemon`, the
        // client would reconnect to the same stale daemon for ever.
        let rejected = try client.send(.handshake(protocolVersion: 1, clientName: "old"))
        try client.wait(timeout: 30) { $0.failure(to: rejected) != nil }

        let requestID = try client.send(.shutdownDaemon)
        try client.wait(timeout: 30) { $0.reply(to: requestID) != nil }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !harness.server.didRequestExit {
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(harness.server.didRequestExit)
    }

    @Test("Shutting the daemon down stops its sessions and asks the process to exit")
    func shutdownRequestStopsEverything() throws {
        // This is how a newly built GUI retires a daemon left over from the
        // previous build when the protocol version no longer matches.
        let session = try createSession(makeSpec(kind: .custom, command: ["sleep", "60"]))
        let pid = try #require(session.pid)
        #expect(kill(pid, 0) == 0)

        let requestID = try client.send(.shutdownDaemon)
        try client.wait(timeout: 30) { $0.reply(to: requestID) != nil }

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !harness.server.didRequestExit {
            Thread.sleep(forTimeInterval: 0.1)
        }
        #expect(harness.server.didRequestExit)

        // The supervised process must not be left orphaned. Given a moment,
        // because reaping happens away from the daemon's queue — waiting for it
        // there held every other session's output up for as long as it took.
        // A zombie still answers `kill(pid, 0)`, so the wait is for it to be
        // reaped rather than merely killed.
        let gone = Date().addingTimeInterval(5)
        while Date() < gone, kill(pid, 0) == 0 {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(kill(pid, 0) != 0)
    }

    // MARK: - Reconnect

    @Test("A session survives its client disconnecting and replays its history")
    func sessionSurvivesClientDisconnect() throws {
        let session = try createSession(makeSpec())
        try client.send(.attach(session.id, replayScrollback: false))
        try client.send(.input(session.id, Data("echo BEFORE_DISCONNECT\n".utf8)))
        try client.wait(timeout: 30) {
            String(decoding: $0.output(for: session.id), as: UTF8.self).contains("BEFORE_DISCONNECT")
        }

        // The GUI goes away entirely.
        client.close()
        Thread.sleep(forTimeInterval: 0.5)

        let reconnected = try harness.makeClient()
        defer { reconnected.close() }

        let listID = try reconnected.send(.listSessions)
        let listed = try reconnected.wait { $0.reply(to: listID) != nil }
        guard case let .sessions(list)? = listed.reply(to: listID) else {
            Issue.record("Expected a session list after reconnect")
            return
        }
        #expect(list.contains { $0.id == session.id })

        // Scrollback replay is what makes the terminal look untouched.
        try reconnected.send(.attach(session.id, replayScrollback: true))
        let replayed = try reconnected.wait(timeout: 30) {
            String(decoding: $0.output(for: session.id), as: UTF8.self).contains("BEFORE_DISCONNECT")
        }
        #expect(String(decoding: replayed.output(for: session.id), as: UTF8.self).contains("BEFORE_DISCONNECT"))

        // And the session is still interactive.
        try reconnected.send(.input(session.id, Data("echo AFTER_RECONNECT\n".utf8)))
        let live = try reconnected.wait(timeout: 30) {
            String(decoding: $0.output(for: session.id), as: UTF8.self).contains("AFTER_RECONNECT")
        }
        #expect(String(decoding: live.output(for: session.id), as: UTF8.self).contains("AFTER_RECONNECT"))
    }

    @Test("Output is only streamed to clients that attached")
    func outputIsNotBroadcastToUnattachedClients() throws {
        let observer = try harness.makeClient()
        defer { observer.close() }

        let session = try createSession(makeSpec())
        try client.send(.attach(session.id, replayScrollback: false))
        try client.send(.input(session.id, Data("echo ONLY_FOR_ATTACHED\n".utf8)))
        try client.wait(timeout: 30) {
            String(decoding: $0.output(for: session.id), as: UTF8.self).contains("ONLY_FOR_ATTACHED")
        }

        // The observer sees lifecycle events but must not pay for the byte stream.
        observer.pump()
        #expect(observer.messages.output(for: session.id).isEmpty)
        #expect(!observer.messages.snapshots(for: session.id).isEmpty)
    }

    @Test("Detaching stops the byte stream without touching the process")
    func detachStopsOutput() throws {
        let session = try createSession(makeSpec())
        try client.send(.attach(session.id, replayScrollback: false))
        try client.send(.input(session.id, Data("echo FIRST_MARKER\n".utf8)))
        try client.wait(timeout: 30) {
            String(decoding: $0.output(for: session.id), as: UTF8.self).contains("FIRST_MARKER")
        }

        let detachID = try client.send(.detach(session.id))
        try client.wait { $0.reply(to: detachID) != nil }

        try client.send(.input(session.id, Data("echo SECOND_MARKER\n".utf8)))
        Thread.sleep(forTimeInterval: 1.5)
        client.pump()
        #expect(!String(decoding: client.messages.output(for: session.id), as: UTF8.self).contains("SECOND_MARKER"))

        // Re-attaching replays everything that happened while detached.
        try client.send(.attach(session.id, replayScrollback: true))
        let replayed = try client.wait(timeout: 30) {
            String(decoding: $0.output(for: session.id), as: UTF8.self).contains("SECOND_MARKER")
        }
        #expect(String(decoding: replayed.output(for: session.id), as: UTF8.self).contains("SECOND_MARKER"))
    }
}
