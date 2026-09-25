import Foundation
import Testing

@testable import RelayDaemonCore
@testable import RelayProtocol

@Suite("The subagents a session's agent has started")
struct SubagentRosterTests {
    private let start = Date(timeIntervalSinceReferenceDate: 20000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private func call(_ id: String, _ description: String, type: String = "Explore", background: Bool? = nil) -> AgentHookEvent {
        AgentHookEvent(
            sessionID: "s", agent: .claude, name: "PreToolUse", toolName: "Agent", toolUseID: id,
            delegation: .init(description: description, agentType: type, toolUseID: id, runsInBackground: background)
        )
    }

    private func answer(_ id: String, _ description: String, agent: String, type: String = "Explore", background: Bool) -> AgentHookEvent {
        AgentHookEvent(
            sessionID: "s", agent: .claude, name: "PostToolUse", toolName: "Agent", toolUseID: id,
            delegation: .init(description: description, agentType: type, agentID: agent, toolUseID: id, runsInBackground: background)
        )
    }

    private func from(
        _ agent: String,
        _ name: String,
        type: String = "Explore",
        tool: String? = nil,
        directory: String? = "/code/shop",
        assignment: AgentHookEvent.Delegation? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(
            sessionID: "s", agent: .claude, name: name, toolName: tool, subagentID: agent,
            workingDirectory: directory, agentType: type, assignment: assignment
        )
    }

    private func parent(_ name: String, source: String? = nil, background: [AgentHookEvent.Delegation]? = nil) -> AgentHookEvent {
        AgentHookEvent(sessionID: "s", agent: .claude, name: name, source: source, backgroundAgents: background)
    }

    private func descriptions(_ roster: SubagentRoster) -> [String: String?] {
        Dictionary(uniqueKeysWithValues: roster.agents.map { ($0.id, $0.description) })
    }

    @Test("A subagent appears when it starts, and is finished when it stops")
    func lifetime() {
        var roster = SubagentRoster()
        roster.apply(from("x", "SubagentStart"), at: at(0))
        #expect(roster.snapshots.map(\.status) == [.working])
        #expect(roster.snapshots.first?.workingDirectory == "/code/shop")
        roster.apply(from("x", "SubagentStop"), at: at(5))
        #expect(roster.snapshots.map(\.status) == [.finished])
        #expect(roster.snapshots.first?.finishedAt == at(5))
    }

    @Test("A subagent first heard of in the middle of its work still appears")
    func firstEventOfAny() {
        var roster = SubagentRoster()
        roster.apply(from("x", "PreToolUse", tool: "Read"), at: at(0))
        #expect(roster.snapshots.map(\.id) == ["x"])
    }

    @Test("A subagent first heard of as it stops leaves nothing to show")
    func stopAlone() {
        var roster = SubagentRoster()
        roster.apply(from("x", "SubagentStop"), at: at(0))
        #expect(roster.agents.isEmpty)
    }

    @Test("Asking for permission is waiting, and the tool running ends the wait")
    func waiting() {
        var roster = SubagentRoster()
        roster.apply(from("x", "SubagentStart"), at: at(0))
        roster.apply(from("x", "PermissionRequest", tool: "Bash"), at: at(1))
        #expect(roster.snapshots.map(\.status) == [.waiting])
        roster.apply(from("x", "PostToolUse", tool: "Read"), at: at(2))
        #expect(roster.snapshots.map(\.status) == [.waiting])
        roster.apply(from("x", "PostToolUse", tool: "Bash"), at: at(3))
        #expect(roster.snapshots.map(\.status) == [.working])
    }

    @Test("The one call of its type waiting for an agent is that agent's task")
    func elimination() {
        var roster = SubagentRoster()
        roster.apply(call("c1", "Find the parser", type: "Explore"), at: at(0))
        roster.apply(call("c2", "Review the diff", type: "reviewer"), at: at(0))
        roster.apply(from("x", "SubagentStart", type: "reviewer"), at: at(0.1))
        roster.apply(from("y", "SubagentStart", type: "Explore"), at: at(0.1))
        #expect(descriptions(roster) == ["x": "Review the diff", "y": "Find the parser"])
    }

    @Test("Two of a type started together are not guessed between")
    func noGuessBetweenTwins() {
        var roster = SubagentRoster()
        roster.apply(call("c1", "Find the parser"), at: at(0))
        roster.apply(call("c2", "Find the tests"), at: at(0))
        roster.apply(from("x", "SubagentStart"), at: at(0.1))
        roster.apply(from("y", "SubagentStart"), at: at(0.1))
        #expect(descriptions(roster) == ["x": nil, "y": nil])

        // Each one's note says which call it came from.
        roster.apply(from("y", "PreToolUse", tool: "Grep", assignment: .init(description: "Find the tests", agentID: "y", toolUseID: "c2")), at: at(1))
        roster.apply(from("x", "PreToolUse", tool: "Grep", assignment: .init(description: "Find the parser", agentID: "x", toolUseID: "c1")), at: at(1))
        #expect(descriptions(roster) == ["x": "Find the parser", "y": "Find the tests"])
    }

    @Test("A guess that something later proves wrong is taken back")
    func wrongGuess() {
        var roster = SubagentRoster()
        // The second call's hook reaches the daemon after its agent's start
        // does: only the first call is waiting when `y` starts.
        roster.apply(call("c1", "Find the parser", background: true), at: at(0))
        roster.apply(from("y", "SubagentStart"), at: at(0.1))
        roster.apply(call("c2", "Find the tests", background: true), at: at(0.1))
        roster.apply(from("x", "SubagentStart"), at: at(0.2))
        #expect(descriptions(roster)["y"] == "Find the parser")

        roster.apply(answer("c1", "Find the parser", agent: "x", background: true), at: at(0.3))
        roster.apply(answer("c2", "Find the tests", agent: "y", background: true), at: at(0.3))
        #expect(descriptions(roster) == ["x": "Find the parser", "y": "Find the tests"])
    }

    @Test("A background call's answer can arrive before its agent's first event")
    func answerFirst() {
        var roster = SubagentRoster()
        roster.apply(call("c1", "Watch the build", background: true), at: at(0))
        roster.apply(answer("c1", "Watch the build", agent: "x", background: true), at: at(0.01))
        roster.apply(from("x", "SubagentStart"), at: at(0.01))
        #expect(roster.agents.map(\.id) == ["x"])
        #expect(roster.snapshots.first?.description == "Watch the build")
        #expect(roster.snapshots.first?.runsInBackground == true)
    }

    @Test("A call that failed takes its foreground agent with it")
    func failedCall() {
        var roster = SubagentRoster()
        roster.apply(call("c1", "Find the parser"), at: at(0))
        roster.apply(from("x", "SubagentStart"), at: at(0.1))
        roster.apply(AgentHookEvent(sessionID: "s", agent: .claude, name: "PostToolUseFailure", toolName: "Agent", toolUseID: "c1",
                                    delegation: .init(description: "Find the parser", agentType: "Explore", toolUseID: "c1")), at: at(3))
        #expect(roster.agents.isEmpty)
    }

    @Test("What finished stays finished when a late event of its turn arrives, and works again when it starts work again")
    func stragglers() {
        var roster = SubagentRoster()
        roster.apply(from("x", "SubagentStart"), at: at(0))
        roster.apply(from("x", "SubagentStop"), at: at(2))
        roster.apply(from("x", "PostToolUse", tool: "Read"), at: at(2.01))
        roster.apply(from("x", "PermissionRequest", tool: "Bash"), at: at(2.02))
        #expect(roster.snapshots.map(\.status) == [.finished])
        roster.apply(from("x", "PreToolUse", tool: "Read"), at: at(30))
        #expect(roster.snapshots.map(\.status) == [.working])
        #expect(roster.snapshots.first?.finishedAt == nil)
    }

    @Test("The end of the parent's turn ends its foreground agents, and not its background ones")
    func turnEnd() {
        var roster = SubagentRoster()
        roster.apply(call("c1", "Find the parser"), at: at(0))
        roster.apply(from("x", "SubagentStart"), at: at(0.1))
        roster.apply(call("c2", "Watch the build", type: "general-purpose", background: true), at: at(0.2))
        roster.apply(from("y", "SubagentStart", type: "general-purpose"), at: at(0.3))
        roster.apply(parent("Stop"), at: at(9))
        #expect(roster.agents.first { $0.id == "x" }?.state == .finished)
        #expect(roster.agents.first { $0.id == "y" }?.state == .working)
    }

    @Test("What Claude Code lists as running in the background is, and what it no longer lists is done")
    func reconciliation() {
        var roster = SubagentRoster()
        roster.apply(from("x", "SubagentStart"), at: at(0))
        roster.apply(from("y", "SubagentStart"), at: at(0))
        let x = AgentHookEvent.Delegation(description: "Watch the build", agentType: "Explore", agentID: "x", runsInBackground: true)
        let y = AgentHookEvent.Delegation(description: "Read the logs", agentType: "Explore", agentID: "y", runsInBackground: true)
        roster.apply(parent("Stop", background: [x, y]), at: at(1))
        #expect(descriptions(roster) == ["x": "Watch the build", "y": "Read the logs"])
        #expect(roster.agents.allSatisfy { $0.state == .working && $0.runsInBackground == true })

        // `y` stops and still lists itself; `x` has gone from the list.
        roster.apply(AgentHookEvent(sessionID: "s", agent: .claude, name: "SubagentStop", subagentID: "y", backgroundAgents: [y]), at: at(5))
        #expect(roster.agents.map(\.state) == [.finished, .finished])
    }

    @Test("A finished row goes after a while, and a silent one after a long while")
    func expiry() {
        var roster = SubagentRoster()
        roster.apply(from("done", "SubagentStart"), at: at(0))
        roster.apply(from("done", "SubagentStop"), at: at(1))
        roster.apply(from("quiet", "SubagentStart"), at: at(0))
        roster.apply(from("asking", "PermissionRequest", tool: "Bash"), at: at(0))

        let early = roster.expire(now: at(SubagentRoster.finishedLinger))
        let lingered = roster.expire(now: at(1 + SubagentRoster.finishedLinger))
        #expect(!early && lingered)
        #expect(roster.agents.map(\.id) == ["quiet", "asking"])

        // Minutes of quiet are a long command, not an end.
        let longCommand = roster.expire(now: at(20 * 60))
        let silent = roster.expire(now: at(SubagentRoster.silenceLimit))
        #expect(!longCommand && silent)
        #expect(roster.agents.map(\.id) == ["asking"])
    }

    @Test("The list is bounded, and the oldest finished row makes room first")
    func bounded() {
        var roster = SubagentRoster()
        for index in 0 ..< SubagentRoster.capacity {
            roster.apply(from("a\(index)", "SubagentStart"), at: at(Double(index)))
        }
        roster.apply(from("a3", "SubagentStop"), at: at(20))
        roster.apply(from("a5", "SubagentStop"), at: at(21))
        roster.apply(from("new", "SubagentStart"), at: at(22))
        #expect(roster.agents.count == SubagentRoster.capacity)
        #expect(!roster.agents.contains { $0.id == "a3" })
        #expect(roster.agents.contains { $0.id == "a5" })

        // With nothing finished, the one heard from longest ago.
        roster.apply(from("a5", "PreToolUse", tool: "Read"), at: at(23))
        roster.apply(from("newer", "SubagentStart"), at: at(24))
        #expect(!roster.agents.contains { $0.id == "a0" })
        #expect(roster.agents.count == SubagentRoster.capacity)
    }

    @Test("Calls waiting for their agents are bounded too")
    func pendingBounded() {
        var roster = SubagentRoster()
        roster.apply(call("first", "The first task", type: "only"), at: at(0))
        for index in 0 ..< SubagentRoster.pendingCapacity {
            roster.apply(call("c\(index)", "Task \(index)"), at: at(0))
        }
        // The oldest call was let go, so nothing is waiting for this type.
        roster.apply(from("x", "SubagentStart", type: "only"), at: at(1))
        #expect(descriptions(roster)["x"] == .some(nil))
    }

    @Test("The session ending, or starting over, clears the list", arguments: [
        ("SessionEnd", nil), ("SessionStart", "clear"), ("SessionStart", "startup"), ("SessionStart", "resume"),
    ] as [(String, String?)])
    func clearing(name: String, source: String?) {
        var roster = SubagentRoster()
        roster.apply(from("x", "SubagentStart"), at: at(0))
        roster.apply(parent(name, source: source), at: at(1))
        #expect(roster.agents.isEmpty)
    }

    @Test("A compaction keeps the list")
    func compaction() {
        var roster = SubagentRoster()
        roster.apply(from("x", "SubagentStart"), at: at(0))
        roster.apply(parent("SessionStart", source: "compact"), at: at(1))
        #expect(roster.agents.count == 1)
    }
}

@Suite("Subagents over a captured run")
struct CapturedSubagentReplayTests {
    private func replay(_ events: [(Date, AgentHookEvent)], until stop: ((AgentHookEvent) -> Bool)? = nil) -> AgentStatusTracker {
        var tracker = AgentStatusTracker()
        for (time, event) in events {
            tracker.apply(event, at: time)
            if let stop, stop(event) { break }
        }
        return tracker
    }

    private func beforeTheEnd(_ captures: [ClaudeSubagentCaptures.Capture]) -> [(Date, AgentHookEvent)] {
        CapturedEvents.events(captures).filter { $0.1.name != "SessionEnd" }
    }

    @Test("Two background agents of one type keep their own tasks and their own folders")
    func background() {
        let tracker = replay(beforeTheEnd(ClaudeSubagentCaptures.background))
        let rows = tracker.subagents.snapshots
        #expect(rows.map(\.description) == ["Alpha directory check", "Beta directory check"])
        #expect(rows.map(\.workingDirectory) == [
            "/Users/me/code/shop",
            "/Users/me/code/shop/.claude/worktrees/agent-a35227e31b33122de",
        ])
        #expect(rows.allSatisfy { $0.runsInBackground && $0.status == .finished })
    }

    @Test("Two foreground agents of one type, started one after the other in one message, are not swapped")
    func foreground() {
        let events = CapturedEvents.events(ClaudeSubagentCaptures.foreground)
        let starts = replay(events) { $0.name == "SubagentStart" && $0.subagentID == "a93fe69a1d9768e3e" }
        // The only call of the type waiting when each one started was its own.
        #expect(starts.subagents.snapshots.map(\.description) == ["Gamma directory check", "Delta directory check"])

        let tracker = replay(beforeTheEnd(ClaudeSubagentCaptures.foreground))
        #expect(tracker.subagents.snapshots.map(\.description) == ["Gamma directory check", "Delta directory check"])
        #expect(tracker.subagents.snapshots.allSatisfy { !$0.runsInBackground && $0.status == .finished })
    }

    @Test("The end of the session takes its subagents with it")
    func sessionEnd() {
        #expect(replay(CapturedEvents.events(ClaudeSubagentCaptures.foreground)).subagents.agents.isEmpty)
    }

    @Test("Started together, two of one type wait for the note that says which is which")
    func foregroundTogether() {
        // Both calls reach the daemon before either agent does.
        var events = CapturedEvents.events(ClaudeSubagentCaptures.foreground, withNotes: true)
        let secondCall = events.firstIndex { $0.1.name == "PreToolUse" && $0.1.delegation?.description == "Delta directory check" }!
        let moved = events.remove(at: secondCall)
        events.insert(moved, at: events.firstIndex { $0.1.name == "SubagentStart" }!)

        let started = replay(events) { $0.name == "SubagentStart" && $0.subagentID == "a93fe69a1d9768e3e" }
        #expect(started.subagents.snapshots.map(\.description) == [nil, nil])

        let working = replay(events) { $0.name == "PreToolUse" && $0.subagentID == "a1b8113bf743cd781" }
        #expect(working.subagents.snapshots.map(\.description) == ["Gamma directory check", "Delta directory check"])
    }
}
