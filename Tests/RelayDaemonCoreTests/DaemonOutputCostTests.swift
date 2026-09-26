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

    /// Whether the only thing that moved between two snapshots is the time.
    private static func onlyActivityMoved(from earlier: SessionSnapshot, to later: SessionSnapshot) -> Bool {
        var aligned = earlier
        aligned.lastActivityAt = later.lastActivityAt
        return aligned == later && earlier.lastActivityAt != later.lastActivityAt
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
        // Let go of as the daemon and the client get round to it, which on a
        // busy machine is not the moment the last byte arrived. Held on to, it
        // never comes down at all: four megabytes kept is over the line however
        // long it is waited for.
        let limit = 3 * 1024 * 1024
        for _ in 0 ..< 100 where allocatedBytes() - before >= limit {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(allocatedBytes() - before < limit)
    }

    @Test("Output that changes nothing but the time is not a snapshot per chunk")
    func outputIsNotReportedChunkByChunk() throws {
        // Every chunk used to carry a snapshot to every client, and every
        // snapshot redrew the window's session lists: a terminal printing a
        // log redrew the sidebar once per kilobyte.
        let started = Date()
        let session = try createSession(command: [
            "/bin/sh", "-c",
            "i=0; while [ $i -lt 50 ]; do echo line$i; sleep 0.02; i=$((i+1)); done; exec sleep 30",
        ])
        try client.send(.attach(session.id, replayScrollback: false))
        let messages = try client.wait(timeout: 30) {
            String(decoding: $0.output(for: session.id), as: UTF8.self).contains("line49")
        }
        let elapsed = Date().timeIntervalSince(started)

        let snapshots = messages.snapshots(for: session.id)
        let activityOnly = zip(snapshots, snapshots.dropFirst()).filter {
            Self.onlyActivityMoved(from: $0.0, to: $0.1)
        }
        #expect(activityOnly.count <= Int(elapsed / SessionRuntime.activityReportInterval) + 1)
    }

    @Test("A session that keeps printing still tells clients when it was last active")
    func steadyOutputStillReportsActivity() throws {
        let session = try createSession(command: ["/bin/sh", "-c", "while true; do echo tick; sleep 0.1; done"])
        let working = try client.wait(timeout: 30) {
            $0.snapshots(for: session.id).contains { $0.status == .working }
        }
        let reported = try #require(working.snapshots(for: session.id).last { $0.status == .working })

        // Nothing else about it changes while it prints, so only the report of
        // its activity can bring the newer time.
        let later = try client.wait(timeout: 10) {
            $0.snapshots(for: session.id).contains {
                $0.status == .working && $0.lastActivityAt.timeIntervalSince(reported.lastActivityAt) > 0.5
            }
        }
        #expect(later.snapshots(for: session.id).last?.status == .working)
    }
}
