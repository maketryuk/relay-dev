import Foundation
import Testing

@testable import RelayDaemonCore
@testable import RelayProtocol

/// What a session's output costs the daemon and every client, over and above
/// the bytes themselves.
@Suite("What output costs", .serialized)
final class DaemonOutputCostTests {
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

    private enum TestFailure: Error { case message(String) }

    private func createSession(command: [String]) throws -> SessionSnapshot {
        let spec = SessionSpec(
            projectID: ProjectID(rawValue: "test-project"),
            kind: .custom,
            name: "Output",
            workingDirectory: "/tmp",
            command: command
        )
        let requestID = try client.send(.createSession(spec))
        let messages = try client.wait(timeout: 30) {
            $0.reply(to: requestID) != nil || $0.failure(to: requestID) != nil
        }
        guard case let .session(snapshot)? = messages.reply(to: requestID) else {
            throw TestFailure.message("createSession failed: \(String(describing: messages.failure(to: requestID)))")
        }
        return snapshot
    }

    private static func outputBytes(in messages: [ServerMessage], for sessionID: SessionID) -> Int {
        messages.events.reduce(0) { total, event in
            guard case let .output(identifier, chunk) = event, identifier == sessionID else { return total }
            return total + chunk.count
        }
    }

    @Test("What a session prints is not kept once it has been passed on")
    func printedOutputIsNotRetained() throws {
        // Four megabytes through a half-megabyte scrollback, to a client that
        // is attached. The scrollback, the tail kept for the status and the
        // connection's queue of writes each used to hold on to all of it.
        let printed = 4 * 1024 * 1024
        let before = allocatedBytes()
        let session = try createSession(command: [
            "/bin/sh", "-c", "head -c \(printed) /dev/zero | tr '\\000' x; exec sleep 60",
        ])
        try client.send(.attach(session.id, replayScrollback: false))
        _ = try client.wait(timeout: 60) { Self.outputBytes(in: $0, for: session.id) >= printed }

        client.forgetReceived()
        #expect(allocatedBytes() - before < 3 * 1024 * 1024)
    }
}
