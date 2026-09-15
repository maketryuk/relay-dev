import Foundation
import Testing

@testable import RelayProtocol

@Suite("Wire codec")
struct WireTests {
    private let encoder = MessageFraming.makeEncoder()
    private let decoder = MessageFraming.makeDecoder()

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let data = try encoder.encode(value)
        return try decoder.decode(T.self, from: data)
    }

    @Test("Every request case survives a round trip")
    func requestRoundTrip() throws {
        let sessionID = SessionID.generate()
        let spec = SessionSpec(
            projectID: .generate(),
            kind: .claude,
            name: "Claude",
            workingDirectory: "/tmp"
        )
        let requests: [DaemonRequest] = [
            .handshake(protocolVersion: 1, clientName: "test"),
            .listSessions,
            .createSession(spec),
            .attach(sessionID, replayScrollback: true),
            .detach(sessionID),
            .input(sessionID, Data([0x1B, 0x5B, 0x41])),
            .resize(sessionID, columns: 120, rows: 40),
            .rename(sessionID, name: "Renamed"),
            .terminate(sessionID),
            .forget(sessionID),
            .shutdownDaemon,
            .ping,
        ]

        for request in requests {
            let message = try roundTrip(ClientMessage(requestID: 42, request: request))
            #expect(message.requestID == 42)
        }
    }

    @Test("Binary PTY output survives encoding")
    func binaryOutputRoundTrip() throws {
        // Terminal output is arbitrary bytes, including invalid UTF-8 mid-frame.
        let payload = Data((0 ... 255).map { UInt8($0) })
        let decoded = try roundTrip(ServerMessage.event(.output(.generate(), payload)))
        guard case let .event(.output(_, bytes)) = decoded else {
            Issue.record("Expected an output event")
            return
        }
        #expect(bytes == payload)
    }

    @Test("Snapshots keep their identity and status through the wire")
    func snapshotRoundTrip() throws {
        let snapshot = SessionSnapshot(
            id: .generate(),
            projectID: .generate(),
            kind: .codex,
            name: "Codex 2",
            workingDirectory: "/Users/test/project",
            command: ["codex"],
            status: .waiting,
            pid: 4242,
            exitCode: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastActivityAt: Date(timeIntervalSince1970: 1_700_000_050),
            columns: 100,
            rows: 30
        )
        let decoded = try roundTrip(snapshot)
        #expect(decoded == snapshot)
    }

    @Test("Identifiers encode as bare strings, not objects")
    func identifierEncoding() throws {
        let identifier = SessionID(rawValue: "abc-123")
        let data = try encoder.encode(identifier)
        #expect(String(decoding: data, as: UTF8.self) == "\"abc-123\"")
    }

    @Test("A protocol mismatch names both versions")
    func protocolMismatchError() {
        let error = DaemonError.protocolMismatch(99)
        #expect(error.code == "protocol_mismatch")
        #expect(error.message.contains("99"))
        #expect(error.message.contains("\(RelayProtocolVersion.current)"))
    }
}

@Suite("Session specification")
struct SessionSpecTests {
    @Test("An empty command falls back to the kind's default")
    func defaultCommandApplied() {
        let spec = SessionSpec(projectID: .generate(), kind: .claude, name: "Claude", workingDirectory: "/tmp")
        #expect(spec.command == ["claude"])
    }

    @Test("Shell has no default command so the login shell is used")
    func shellHasNoDefaultCommand() {
        let spec = SessionSpec(projectID: .generate(), kind: .shell, name: "Shell", workingDirectory: "/tmp")
        #expect(spec.command.isEmpty)
    }

    @Test("An explicit command is never overridden")
    func explicitCommandWins() {
        let spec = SessionSpec(
            projectID: .generate(),
            kind: .claude,
            name: "Claude",
            workingDirectory: "/tmp",
            command: ["claude", "--resume"]
        )
        #expect(spec.command == ["claude", "--resume"])
    }

    @Test("Quick actions are the three the sidebar surfaces")
    func quickActions() {
        let quick = Set(SessionKind.allCases.filter(\.isQuickAction))
        #expect(quick == [.claude, .codex, .shell])
    }
}
