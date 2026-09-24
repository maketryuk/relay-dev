import Foundation
import Testing

@testable import RelayDaemonCore
@testable import RelayProtocol

/// A real daemon, real terminals, and hooks delivered the way `relay-hook`
/// delivers them.
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

    private func send(_ name: String, to session: SessionSnapshot, from pid: Int32? = nil, tool: String? = nil) throws {
        let event = AgentHookEvent(
            sessionID: session.id.rawValue,
            agent: .claude,
            name: name,
            toolName: tool,
            ancestry: [ProcessAncestor(pid: try #require(pid ?? session.pid), name: "sh")]
        )
        let socket = RelayPaths.hookSocketURL(beside: harness.socketURL).path
        #expect(AgentHookDelivery.send(event, to: socket))
    }

    /// Redraws two hundred bytes for every key it reads, which is what an
    /// agent's input box does and a shell's echo does not. Says when it is
    /// reading keys one at a time, since a key sent before that waits for a
    /// newline that never comes.
    private static let inputBox = """
    stty -icanon -echo; printf 'ready\\n'; while dd bs=1 count=1 >/dev/null 2>&1; do printf '%0200d\\r' 0; done
    """

    /// An agent that says nothing on its own, as a process the session's pid
    /// stays with.
    private static let quietAgent = ["/bin/sh", "-c", "printf 'ready\\n'; exec sleep 60"]

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

    @Test("What the session's agent reports through its hooks is its status")
    func hooksSetTheStatus() throws {
        let session = try createSession(kind: .claude, command: Self.quietAgent)
        try client.wait(timeout: 30) { $0.snapshots(for: session.id).contains { $0.status == .idle } }

        try send("PermissionRequest", to: session, tool: "Bash")
        try client.wait(timeout: 10) { $0.snapshots(for: session.id).last?.status == .waiting }

        try send("PostToolUse", to: session, tool: "Bash")
        try client.wait(timeout: 10) { $0.snapshots(for: session.id).last?.status == .working }

        try send("Stop", to: session)
        let messages = try client.wait(timeout: 10) { $0.snapshots(for: session.id).last?.status == .finished }
        #expect(messages.snapshots(for: session.id).last?.status == .finished)
    }

    @Test("A plain terminal hosts no agent until one announces itself in it")
    func agentInShell() throws {
        let session = try createSession(kind: .shell, command: [])
        #expect(!session.hostsAgent)
        try client.wait(timeout: 30) { $0.snapshots(for: session.id).contains { $0.status == .idle } }

        // What Claude Code's title looks like, from a job the shell runs in
        // the foreground, as it would run `claude`.
        let job = "sh -c 'printf \"\\033]0;\u{2733} Claude Code\\007\"; sleep 20'\n"
        try client.send(.input(session.id, Data(job.utf8)))
        let messages = try client.wait(timeout: 10) { $0.snapshots(for: session.id).contains { $0.hostsAgent } }
        #expect(messages.snapshots(for: session.id).contains { $0.reportsStatus })
    }

    @Test("A hook from a terminal the session does not own changes nothing")
    func foreignHookIsIgnored() throws {
        let session = try createSession(kind: .claude, command: Self.quietAgent)
        try client.wait(timeout: 30) { $0.snapshots(for: session.id).contains { $0.status == .idle } }

        let settled = client.messages.snapshots(for: session.id).count
        try send("PermissionRequest", to: session, from: 1, tool: "Bash")
        #expect(!arrives(for: session, within: 2, skipping: settled) { $0.status == .waiting })
    }
}
