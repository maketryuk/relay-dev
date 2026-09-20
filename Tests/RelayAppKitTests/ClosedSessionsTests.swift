import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("Reopening a closed session")
struct ClosedSessionsTests {
    private func spec(
        _ name: String,
        project: String = "one",
        role: SessionRole = .interactive
    ) -> SessionSpec {
        SessionSpec(
            projectID: ProjectID(rawValue: project),
            kind: .shell,
            name: name,
            workingDirectory: "/tmp",
            command: ["/bin/zsh"],
            role: role
        )
    }

    @Test("The last closed is the first back")
    func newestFirst() {
        var stack: [SessionSpec] = []
        stack = ClosedSessions.pushing(spec("a"), onto: stack)
        stack = ClosedSessions.pushing(spec("b"), onto: stack)
        #expect(stack.map(\.name) == ["b", "a"])

        let first = ClosedSessions.popping(stack) { _ in true }
        #expect(first?.spec.name == "b")
        // And again goes further back, which is what the gesture means in a
        // browser.
        let second = ClosedSessions.popping(first?.rest ?? []) { _ in true }
        #expect(second?.spec.name == "a")
        #expect(second?.rest.isEmpty == true)
    }

    @Test("The stack is capped, and the oldest falls off it")
    func capped() {
        var stack: [SessionSpec] = []
        for index in 0 ..< (ClosedSessions.limit + 5) {
            stack = ClosedSessions.pushing(spec("s\(index)"), onto: stack)
        }
        #expect(stack.count == ClosedSessions.limit)
        #expect(stack.first?.name == "s\(ClosedSessions.limit + 4)")
        #expect(!stack.contains { $0.name == "s0" })
    }

    @Test("A service is not something this brings back")
    func servicesAreLeftOut() {
        // It is started and stopped by the buttons beside it; reopening a
        // terminal should not start a dev server.
        let stack = ClosedSessions.pushing(spec("web", role: .service(id: "web")), onto: [])
        #expect(stack.isEmpty)
    }

    @Test("Nothing to reopen is answered with nothing")
    func emptyStack() {
        #expect(ClosedSessions.popping([]) { _ in true } == nil)
    }

    @Test("A session from elsewhere is passed over and left where it is")
    func skipsWhatItCannotOpen() {
        // The shortcut works on the project in front of you. Another
        // project's closed session is not discarded for being in the way —
        // it is still that project's to bring back.
        var stack: [SessionSpec] = []
        stack = ClosedSessions.pushing(spec("mine"), onto: stack)
        stack = ClosedSessions.pushing(spec("theirs", project: "two"), onto: stack)

        let popped = ClosedSessions.popping(stack) { $0.projectID.rawValue == "one" }
        #expect(popped?.spec.name == "mine")
        #expect(popped?.rest.map(\.name) == ["theirs"])
    }

    @Test("A project with nothing closed reopens nothing")
    func nothingForThisProject() {
        let stack = ClosedSessions.pushing(spec("theirs", project: "two"), onto: [])
        #expect(ClosedSessions.popping(stack) { $0.projectID.rawValue == "one" } == nil)
    }
}
