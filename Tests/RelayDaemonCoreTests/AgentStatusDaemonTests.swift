import Foundation
import Testing

@testable import RelayDaemonCore
@testable import RelayProtocol

/// A real daemon and real terminals.
@Suite("Agent status in the daemon", .serialized)
final class AgentStatusDaemonTests {
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

    private func createSession(kind: SessionKind, command: [String]) throws -> SessionSnapshot {
        let spec = SessionSpec(
            projectID: ProjectID(rawValue: "test-project"),
            kind: kind,
            name: "Agent",
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

    /// Redraws two hundred bytes for every key it reads, which is what an
    /// agent's input box does and a shell's echo does not. Says when it is
    /// reading keys one at a time, since a key sent before that waits for a
    /// newline that never comes.
    private static let inputBox = """
    stty -icanon -echo; printf 'ready\\n'; while dd bs=1 count=1 >/dev/null 2>&1; do printf '%0200d\\r' 0; done
    """

    /// Whether a snapshot matching `predicate` arrives within `window`, counting
    /// only snapshots after the first `skipping`.
    private func arrives(
        for session: SessionSnapshot,
        within window: TimeInterval,
        skipping: Int,
        _ predicate: @escaping (SessionSnapshot) -> Bool
    ) -> Bool {
        (try? client.wait(timeout: window) { $0.snapshots(for: session.id).dropFirst(skipping).contains(where: predicate) }) != nil
    }

    @Test("Typing into an agent without sending it is neither work nor a finished task")
    func typingIsNotWork() throws {
        let session = try createSession(kind: .claude, command: ["/bin/sh", "-c", Self.inputBox])
        try client.send(.attach(session.id, replayScrollback: false))
        try client.wait(timeout: 30) { $0.snapshots(for: session.id).contains { $0.status == .idle } }
        let settled = client.messages.snapshots(for: session.id).count

        for letter in ["h", "e", "l", "l", "o"] {
            try client.send(.input(session.id, Data(letter.utf8)))
        }
        // Every key redrawn, so all that is left to happen is the judgement.
        try client.wait(timeout: 10) { $0.output(for: session.id).count >= 5 * 200 }

        let judgedBusy = arrives(for: session, within: 3, skipping: settled) {
            $0.status == .working || $0.status == .finished
        }
        #expect(!judgedBusy)
    }
}
