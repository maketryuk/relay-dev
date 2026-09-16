import Foundation
import Testing

@testable import RelayAppKit
@testable import RelayProtocol

@Suite("Snapshot merging")
struct SessionMergeTests {
    private let identifier = SessionID(rawValue: "s1")

    private func snapshot(
        status: RuntimeStatus,
        activity: TimeInterval,
        exitCode: Int32? = nil
    ) -> SessionSnapshot {
        let start = Date(timeIntervalSince1970: 1_000_000)
        return SessionSnapshot(
            id: identifier,
            projectID: .generate(),
            kind: .custom,
            name: "Dev",
            workingDirectory: "/tmp",
            command: ["/bin/sh", "-c", "npm run dev"],
            status: status,
            pid: 1,
            exitCode: exitCode,
            startedAt: start,
            lastActivityAt: start.addingTimeInterval(activity),
            columns: 80,
            rows: 24
        )
    }

    @Test("The first snapshot is always applied")
    func firstSnapshotApplies() {
        #expect(SessionMerge.shouldApply(snapshot(status: .starting, activity: 0), over: nil))
    }

    @Test("A reply that arrives after an event does not rewind the session")
    func staleReplyIsIgnored() {
        // The exact bug this exists for: `createSession` answers with
        // `starting`, the events that follow say `working` then `idle`, and the
        // reply lands last. A dev server that starts and goes quiet then reads
        // "Starting" for as long as it runs, because nothing else ever arrives.
        let live = snapshot(status: .idle, activity: 5)
        let reply = snapshot(status: .starting, activity: 0)
        #expect(!SessionMerge.shouldApply(reply, over: live))
    }

    @Test("A newer snapshot is applied")
    func newerSnapshotApplies() {
        let old = snapshot(status: .starting, activity: 0)
        let new = snapshot(status: .working, activity: 2)
        #expect(SessionMerge.shouldApply(new, over: old))
    }

    @Test("A snapshot from the same moment is applied, so equal timestamps do not stall")
    func equalTimestampsApply() {
        let first = snapshot(status: .working, activity: 3)
        let second = snapshot(status: .waiting, activity: 3)
        #expect(SessionMerge.shouldApply(second, over: first))
    }

    @Test("An exit is final and cannot be undone by an older snapshot")
    func exitWins() {
        let exited = snapshot(status: .finished, activity: 9, exitCode: 0)
        let running = snapshot(status: .working, activity: 20)
        #expect(!SessionMerge.shouldApply(running, over: exited))

        // And learning about an exit always applies, whatever its timestamp.
        let live = snapshot(status: .working, activity: 50)
        let late = snapshot(status: .error, activity: 1, exitCode: 1)
        #expect(SessionMerge.shouldApply(late, over: live))
    }

    @Test("Merging writes through the dictionary only when it should")
    func mergingRespectsTheRule() {
        var sessions: [SessionID: SessionSnapshot] = [:]
        SessionMerge.merging(snapshot(status: .starting, activity: 0), into: &sessions)
        #expect(sessions[identifier]?.status == .starting)

        SessionMerge.merging(snapshot(status: .working, activity: 2), into: &sessions)
        #expect(sessions[identifier]?.status == .working)

        SessionMerge.merging(snapshot(status: .starting, activity: 0), into: &sessions)
        #expect(sessions[identifier]?.status == .working)
    }

    @Test("A session the user has closed does not come back")
    func closingSessionIsNotResurrected() {
        // Closing a pane while the daemon is still answering the request that
        // created it used to put the session back: the reply arrived after the
        // decision, reinstated it, and selecting it attached to a session the
        // daemon had already forgotten — which is what produced "Session … is
        // not known to the daemon" out of nowhere.
        var sessions: [SessionID: SessionSnapshot] = [:]
        SessionMerge.merging(
            snapshot(status: .starting, activity: 0),
            into: &sessions,
            closing: [identifier]
        )
        #expect(sessions.isEmpty)
    }

    @Test("Its own exit event does not bring it back either")
    func closingSessionIgnoresItsExit() {
        // Terminating a session produces an exit event; by then the user has
        // already asked for it to go away.
        var sessions: [SessionID: SessionSnapshot] = [identifier: snapshot(status: .working, activity: 1)]
        sessions.removeValue(forKey: identifier)

        SessionMerge.merging(
            snapshot(status: .finished, activity: 5, exitCode: 0),
            into: &sessions,
            closing: [identifier]
        )
        #expect(sessions.isEmpty)
    }

    @Test("Other sessions are unaffected by one being closed")
    func closingOneDoesNotBlockAnother() {
        var sessions: [SessionID: SessionSnapshot] = [:]
        SessionMerge.merging(
            snapshot(status: .working, activity: 2),
            into: &sessions,
            closing: [SessionID(rawValue: "someone-else")]
        )
        #expect(sessions[identifier]?.status == .working)
    }
}

@Suite("Session labels")
struct SessionLabelTests {
    private func session(_ id: String, name: String, title: String?, userDefined: Bool = false) -> SessionSnapshot {
        SessionSnapshot(
            id: SessionID(rawValue: id),
            projectID: ProjectID(rawValue: "p"),
            kind: .claude,
            name: name,
            workingDirectory: "/tmp",
            command: ["claude"],
            status: .idle,
            pid: 1,
            exitCode: nil,
            startedAt: Date(timeIntervalSince1970: 0),
            lastActivityAt: Date(timeIntervalSince1970: 0),
            columns: 80,
            rows: 24,
            title: title,
            isNameUserDefined: userDefined
        )
    }

    @Test("Two agents that report the same title are still told apart")
    func sharedTitles() {
        // Every Claude session calls its terminal "Claude Code", so the titles
        // alone give a list of identical rows.
        let labels = SessionNaming.labels(for: [
            session("a", name: "Claude Code", title: "Claude Code"),
            session("b", name: "Claude Code 2", title: "Claude Code"),
        ])
        #expect(labels[SessionID(rawValue: "a")] == "Claude Code")
        #expect(labels[SessionID(rawValue: "b")] == "Claude Code 2")
    }

    @Test("A title nobody else claims is left alone")
    func uniqueTitleWins() {
        let labels = SessionNaming.labels(for: [
            session("a", name: "Claude Code", title: "relay — fixing the parser"),
        ])
        #expect(labels[SessionID(rawValue: "a")] == "relay — fixing the parser")
    }

    @Test("A name the user chose is never rewritten")
    func userNamesAreKept() {
        let labels = SessionNaming.labels(for: [
            session("a", name: "Reviewer", title: "Claude Code", userDefined: true),
            session("b", name: "Claude Code", title: "Claude Code"),
        ])
        #expect(labels[SessionID(rawValue: "a")] == "Reviewer")
        #expect(labels[SessionID(rawValue: "b")] == "Claude Code")
    }

    @Test("Names that collide too are numbered rather than repeated")
    func numbersAsALastResort() {
        // Sessions started before the daemon was restarted can share a name.
        let labels = SessionNaming.labels(for: [
            session("a", name: "Claude Code", title: "Claude Code"),
            session("b", name: "Claude Code", title: "Claude Code"),
            session("c", name: "Claude Code", title: "Claude Code"),
        ])
        #expect(Set(labels.values).count == 3)
        #expect(labels[SessionID(rawValue: "c")] == "Claude Code 3")
    }
}
