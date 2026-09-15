import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("Daemon event delivery")
struct DaemonClientEventTests {
    private func snapshot(status: RuntimeStatus) -> SessionSnapshot {
        SessionSnapshot(
            id: SessionID(rawValue: "session"),
            projectID: ProjectID(rawValue: "project"),
            kind: .shell,
            name: "Terminal",
            workingDirectory: "/tmp",
            command: [],
            status: status,
            pid: 4_242,
            exitCode: nil,
            startedAt: Date(timeIntervalSince1970: 1_000),
            lastActivityAt: Date(timeIntervalSince1970: 1_001),
            columns: 80,
            rows: 24
        )
    }

    private func frame(_ event: DaemonEvent) throws -> Data {
        try MessageFraming.makeEncoder().encode(ServerMessage.event(event))
    }

    @Test("Events still arrive after an earlier consumer was cancelled")
    func eventsSurviveConsumerCancellation() async throws {
        // Every reconnect tears the event loop down and starts another one. An
        // `AsyncStream` is finished for good once its consumer is cancelled, so
        // a client that hands out the same stream twice goes permanently silent
        // after the first disconnect — replies keep working, which is why the
        // app looked connected while every session sat at "Starting".
        let client = DaemonClient()

        let firstConsumer = Task {
            for await _ in client.eventStream() {}
        }
        try await Task.sleep(for: .milliseconds(50))
        firstConsumer.cancel()
        _ = await firstConsumer.value

        let stream = client.eventStream()
        var iterator = stream.makeAsyncIterator()
        client.handle(frame: try frame(.sessionUpdated(snapshot(status: .working))))

        let received = await iterator.next()
        guard case let .sessionUpdated(delivered)? = received else {
            Issue.record("expected a sessionUpdated event, got \(String(describing: received))")
            return
        }
        #expect(delivered.status == .working)
    }

    @Test("A finished consumer stops being fed")
    func terminatedConsumersAreForgotten() async throws {
        let client = DaemonClient()

        let consumer = Task {
            for await _ in client.eventStream() {}
        }
        try await Task.sleep(for: .milliseconds(50))
        consumer.cancel()
        _ = await consumer.value
        try await Task.sleep(for: .milliseconds(50))

        // Feeding a client with no live subscriber must be harmless, and must
        // not keep the dead one's continuation alive.
        client.handle(frame: try frame(.sessionRemoved(SessionID(rawValue: "session"))))
        #expect(client.subscriberCount == 0)
    }
}
