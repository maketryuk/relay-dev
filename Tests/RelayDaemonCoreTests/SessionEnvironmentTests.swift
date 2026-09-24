import Foundation
import Testing

@testable import RelayDaemonCore
@testable import RelayProtocol

@Suite("What a terminal is told about Relay")
struct SessionEnvironmentTests {
    private let session = SessionID(rawValue: "S-1")

    @Test("The relay command's directory goes first on PATH, once")
    func searchPath() {
        let helpers = "/Applications/Relay.app/Contents/Helpers"
        #expect(LaunchPlanBuilder.searchPath("/usr/bin:/bin", prepending: helpers) == "\(helpers):/usr/bin:/bin")
        #expect(LaunchPlanBuilder.searchPath("/usr/bin:\(helpers)::/bin", prepending: helpers) == "\(helpers):/usr/bin:/bin")
        #expect(LaunchPlanBuilder.searchPath(nil, prepending: helpers) == helpers)
    }

    @Test("A terminal gets the sockets, its session and the command, and the command is on its PATH")
    func relayEnvironment() {
        let relay = [
            ControlEnvironment.socketKey: "/tmp/relay-dev-501-control.sock",
            ControlEnvironment.executableKey: "/Applications/Relay Dev.app/Contents/Helpers/relay",
            AgentHookEnvironment.helperKey: "/Applications/Relay Dev.app/Contents/MacOS/relay-hook",
        ]
        let inherited = [
            "PATH": "/usr/bin:/bin",
            // Left by a Relay terminal the app was itself started from.
            ControlEnvironment.socketKey: "/tmp/relay-501-control.sock",
        ]
        let environment = LaunchPlanBuilder.environment(inherited, telling: relay, session: session)
        #expect(environment[ControlEnvironment.socketKey] == "/tmp/relay-dev-501-control.sock")
        #expect(environment[ControlEnvironment.executableKey] == "/Applications/Relay Dev.app/Contents/Helpers/relay")
        #expect(environment[AgentHookEnvironment.sessionKey] == "S-1")
        #expect(environment["PATH"] == "/Applications/Relay Dev.app/Contents/Helpers:/usr/bin:/bin")
    }

    @Test("Without the command beside it, PATH is left as it was")
    func noCommand() {
        let relay = [ControlEnvironment.socketKey: "/tmp/relay-501-control.sock"]
        let environment = LaunchPlanBuilder.environment(["PATH": "/usr/bin"], telling: relay, session: session)
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment[ControlEnvironment.executableKey] == nil)
        #expect(environment[AgentHookEnvironment.sessionKey] == "S-1")
    }
}

/// The same, through a real daemon and a real terminal.
@Suite("The control socket reaches a terminal", .serialized)
final class SessionControlSocketTests {
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

    @Test("A terminal names the control socket beside its own daemon's")
    func socketReachesTerminal() throws {
        let spec = SessionSpec(
            projectID: ProjectID(rawValue: "test-project"),
            kind: .custom,
            name: "Environment",
            workingDirectory: "/tmp",
            command: ["/bin/sh", "-c", "printf '[%s]\\n' \"$RELAY_CONTROL_SOCKET\""]
        )
        let requestID = try client.send(.createSession(spec))
        let created = try client.wait(timeout: 30) { $0.reply(to: requestID) != nil || $0.failure(to: requestID) != nil }
        guard case let .session(session)? = created.reply(to: requestID) else {
            Issue.record("createSession failed: \(String(describing: created.failure(to: requestID)))")
            return
        }
        try client.send(.attach(session.id, replayScrollback: true))

        let expected = "[\(RelayPaths.controlSocketURL(beside: harness.socketURL).path)]"
        let messages = try client.wait {
            String(decoding: $0.output(for: session.id), as: UTF8.self).contains(expected)
        }
        #expect(String(decoding: messages.output(for: session.id), as: UTF8.self).contains(expected))
    }
}
