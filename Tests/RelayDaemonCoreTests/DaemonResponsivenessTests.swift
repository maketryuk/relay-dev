import Foundation
import Testing

@testable import RelayDaemonCore
@testable import RelayProtocol

/// A command runner that takes its time, so "the daemon stayed responsive" can
/// be asserted instead of hoped for. Nothing real is executed, which also keeps
/// these tests independent of whether the machine has `lsof` or Docker.
private final class SlowCommandRunner: CommandRunning, @unchecked Sendable {
    private let delay: TimeInterval
    private let lock = NSLock()
    private var invocations: [String] = []

    init(delay: TimeInterval) {
        self.delay = delay
    }

    var calls: [String] {
        lock.withLock { invocations }
    }

    func run(_ executable: String, arguments _: [String], timeout _: TimeInterval) -> CommandResult? {
        lock.withLock { invocations.append(executable) }
        Thread.sleep(forTimeInterval: delay)
        return CommandResult(status: 0, standardOutput: "", standardError: "")
    }
}

@Suite("Daemon responsiveness", .serialized)
final class DaemonResponsivenessTests {
    private let runner = SlowCommandRunner(delay: 3)
    private let harness: DaemonHarness
    private let client: TestClient

    init() throws {
        harness = try DaemonHarness(commandRunner: runner)
        client = try harness.makeClient()
    }

    deinit {
        client.close()
        harness.shutdown()
    }

    @Test("A new session starts while a port scan is still running")
    func portScanDoesNotBlockSessionCreation() throws {
        // The scan and the PTY used to share one serial queue, so pressing ⌘T
        // while the ports window was refreshing left the new terminal at
        // "Starting", with nothing on screen, until `lsof` came back.
        try client.send(.listPorts(ProjectID(rawValue: "project")))

        let started = Date()
        let requestID = try client.send(.createSession(SessionSpec(
            projectID: ProjectID(rawValue: "project"),
            kind: .shell,
            name: "Terminal",
            workingDirectory: "/tmp"
        )))
        _ = try client.wait(timeout: 10) { $0.reply(to: requestID) != nil }
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    @Test("A ping is answered while a port scan is still running")
    func portScanDoesNotBlockOtherRequests() throws {
        try client.send(.listPorts(ProjectID(rawValue: "project")))

        let started = Date()
        let requestID = try client.send(.ping)
        _ = try client.wait(timeout: 10) { $0.reply(to: requestID) != nil }
        #expect(Date().timeIntervalSince(started) < 1.5)
    }

    @Test("Clients asking at the same time share one scan")
    func concurrentScansAreCoalesced() throws {
        // The ports window rescans while it is open, and it is not the only
        // thing that asks; one `lsof` per asker would be pure waste.
        let second = try harness.makeClient()
        let third = try harness.makeClient()
        defer {
            second.close()
            third.close()
        }

        let first = try client.send(.listPorts(ProjectID(rawValue: "project")))
        let secondID = try second.send(.listPorts(ProjectID(rawValue: "other")))
        let thirdID = try third.send(.listPorts(ProjectID(rawValue: "project")))

        _ = try client.wait(timeout: 10) { $0.reply(to: first) != nil }
        _ = try second.wait(timeout: 10) { $0.reply(to: secondID) != nil }
        _ = try third.wait(timeout: 10) { $0.reply(to: thirdID) != nil }

        #expect(runner.calls.filter { $0.hasSuffix("lsof") }.count == 1)
    }

    @Test("A paste into a terminal that is not reading holds up nothing else")
    func unreadInputDoesNotBlock() throws {
        // `sleep` reads nothing, so its terminal takes a couple of kilobytes of
        // the paste and refuses the rest until something does. The rest used to
        // be retried until it went, on the queue every session shares: every
        // terminal froze, and a core stayed busy, for as long as `sleep` ran.
        let createID = try client.send(.createSession(SessionSpec(
            projectID: ProjectID(rawValue: "project"),
            kind: .custom,
            name: "Not reading",
            workingDirectory: "/tmp",
            command: ["/bin/sleep", "30"]
        )))
        let created = try client.wait(timeout: 10) { $0.reply(to: createID) != nil }
        guard case let .session(session)? = created.reply(to: createID) else {
            Issue.record("Expected a session")
            return
        }

        try client.send(.input(session.id, Data(String(repeating: "a line nobody reads\n", count: 5_000).utf8)))
        let pingID = try client.send(.ping)
        _ = try client.wait(timeout: 10) { $0.reply(to: pingID) != nil }
    }

    @Test("A port scan still answers the client that asked for it")
    func portScanRepliesEventually() throws {
        let requestID = try client.send(.listPorts(ProjectID(rawValue: "project")))
        let messages = try client.wait(timeout: 10) { $0.reply(to: requestID) != nil }
        guard case .ports? = messages.reply(to: requestID) else {
            Issue.record("Expected a port list")
            return
        }
    }
}
