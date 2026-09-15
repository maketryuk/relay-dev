import Foundation
import Testing

@testable import RelayAppKit
@testable import RelayProtocol

@Suite("Startup diagnostics")
struct StartupDiagnosticsTests {
    private func snapshot(status: RuntimeStatus, startedAgo: TimeInterval) -> SessionSnapshot {
        let start = Date().addingTimeInterval(-startedAgo)
        return SessionSnapshot(
            id: .generate(),
            projectID: .generate(),
            kind: .shell,
            name: "Shell",
            workingDirectory: "/tmp",
            command: [],
            status: status,
            pid: 1,
            exitCode: nil,
            startedAt: start,
            lastActivityAt: start,
            columns: 80,
            rows: 24
        )
    }

    @Test("A session that has just started gets no scary message")
    func quietDuringNormalStartup() {
        #expect(StartupDiagnostics.hint(for: snapshot(status: .starting, startedAgo: 1)) == nil)
        #expect(StartupDiagnostics.hint(for: snapshot(status: .starting, startedAgo: 7)) == nil)
    }

    @Test("A session stuck at starting is explained")
    func explainsStalledStartup() {
        let hint = StartupDiagnostics.hint(for: snapshot(status: .starting, startedAgo: 20))
        #expect(hint != nil)
        #expect(hint?.contains("permission dialog") == true)
        #expect(hint?.contains("zshrc") == true)
    }

    @Test("A session that produced output is never flagged, however old")
    func runningSessionsAreNotFlagged() {
        for status in [RuntimeStatus.working, .idle, .waiting, .finished, .error] {
            #expect(StartupDiagnostics.hint(for: snapshot(status: status, startedAgo: 600)) == nil)
        }
    }

    @Test("The elapsed time is reported so the user can judge for themselves")
    func reportsElapsedTime() {
        let hint = StartupDiagnostics.hint(for: snapshot(status: .starting, startedAgo: 42))
        #expect(hint?.contains("42s") == true)
    }
}
