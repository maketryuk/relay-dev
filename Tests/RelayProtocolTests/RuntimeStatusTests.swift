import Testing

@testable import RelayProtocol

@Suite("Runtime status aggregation")
struct RuntimeStatusTests {
    @Test("A single session waiting for input outranks everything else")
    func waitingWinsOverWorking() {
        // The spec's worked example: Claude #1 working, Claude #2 waiting,
        // Codex finished — the project must read as "waiting".
        let aggregate = RuntimeStatus.aggregate([.working, .waiting, .finished])
        #expect(aggregate == .waiting)
    }

    @Test("Errors outrank everything except a request for attention")
    func errorPriority() {
        #expect(RuntimeStatus.aggregate([.working, .error, .idle]) == .error)
        #expect(RuntimeStatus.aggregate([.waiting, .error]) == .waiting)
    }

    @Test("An empty project is offline")
    func emptyAggregate() {
        #expect(RuntimeStatus.aggregate([]) == .offline)
    }

    @Test(
        "Priority order matches the product spec",
        arguments: [
            (RuntimeStatus.waiting, RuntimeStatus.error),
            (.error, .working),
            (.working, .starting),
            (.starting, .finished),
            (.finished, .idle),
            (.idle, .offline),
        ]
    )
    func priorityOrdering(higher: RuntimeStatus, lower: RuntimeStatus) {
        #expect(higher.priority < lower.priority)
        #expect(RuntimeStatus.aggregate([lower, higher]) == higher)
    }

    @Test("Only states with a running process are live")
    func liveness() {
        #expect(RuntimeStatus.waiting.isLive)
        #expect(RuntimeStatus.working.isLive)
        #expect(RuntimeStatus.starting.isLive)
        #expect(RuntimeStatus.idle.isLive)
        #expect(!RuntimeStatus.error.isLive)
        #expect(!RuntimeStatus.finished.isLive)
        #expect(!RuntimeStatus.offline.isLive)
    }

    @Test("Every status has a display name")
    func displayNames() {
        for status in RuntimeStatus.allCases {
            #expect(!status.displayName.isEmpty)
        }
    }
}
