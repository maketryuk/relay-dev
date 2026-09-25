import Foundation
import Testing

@testable import RelayDaemonCore
@testable import RelayProtocol

/// The captures, read the way `relay-hook` reads them.
enum CapturedEvents {
    static let start = Date(timeIntervalSinceReferenceDate: 50000)

    static func event(_ payload: String, withNotes: Bool = false) -> AgentHookEvent {
        let read = AgentHookPayload(Data(payload.utf8), agent: .claude, sessionID: "session", ancestry: [])!
        var event = read.event
        // The note is written a moment after the subagent starts, so the
        // helper finds it from the subagent's first tool call on.
        if withNotes, event.name != "SubagentStart", let id = event.subagentID, let note = ClaudeSubagentCaptures.notes[id] {
            event.assignment = AgentHookEvent.Delegation(note: Data(note.utf8), agentID: id)
        }
        return event
    }

    static func events(_ captures: [ClaudeSubagentCaptures.Capture], withNotes: Bool = false) -> [(Date, AgentHookEvent)] {
        captures.map { (start.addingTimeInterval($0.at), event($0.payload, withNotes: withNotes)) }
    }

    static func named(_ name: String, agent: String? = nil, in captures: [ClaudeSubagentCaptures.Capture]) -> [AgentHookEvent] {
        events(captures).map(\.1).filter { $0.name == name && (agent == nil || $0.subagentID == agent) }
    }
}

@Suite("Claude Code's hooks around subagents, as captured")
struct CapturedSubagentHookTests {
    private let alpha = "a91551d74c9284977"
    private let beta = "a35227e31b33122de"
    private let gamma = "a1b8113bf743cd781"
    private let delta = "a93fe69a1d9768e3e"

    @Test("The call to Agent names the task, and its answer names the agent")
    func delegation() throws {
        let calls = CapturedEvents.named("PreToolUse", in: ClaudeSubagentCaptures.background).filter { $0.subagentID == nil }
        let alphaCall = try #require(calls.first?.delegation)
        #expect(alphaCall.description == "Alpha directory check")
        #expect(alphaCall.agentType == "general-purpose")
        #expect(alphaCall.runsInBackground == true)
        #expect(alphaCall.agentID == nil)
        #expect(alphaCall.toolUseID == "toolu_01QfZTCt96ciGEHNeowWqxb9")

        let answers = CapturedEvents.named("PostToolUse", in: ClaudeSubagentCaptures.background).filter { $0.toolName == "Agent" }
        #expect(answers.map(\.delegation?.agentID) == [alpha, beta])
        // Asked for an isolated worktree and nothing about the background,
        // and run in the background all the same: the answer is what says.
        #expect(calls.dropFirst().first?.delegation?.runsInBackground == nil)
        #expect(answers.last?.delegation?.runsInBackground == true)
    }

    @Test("A foreground call names its agent only once the agent has stopped")
    func foregroundAnswer() throws {
        let events = CapturedEvents.events(ClaudeSubagentCaptures.foreground).map(\.1)
        let stop = try #require(events.firstIndex { $0.name == "SubagentStop" && $0.subagentID == delta })
        let answer = try #require(events.firstIndex { $0.name == "PostToolUse" && $0.delegation?.agentID == delta })
        #expect(stop < answer)
        #expect(events[answer].delegation?.runsInBackground == false)
        #expect(events[answer].delegation?.description == "Delta directory check")
    }

    @Test("A subagent works where its parent does, unless it was given a worktree of its own")
    func workingDirectories() {
        let starts = CapturedEvents.named("SubagentStart", in: ClaudeSubagentCaptures.background)
        #expect(starts.map(\.subagentID) == [alpha, beta])
        #expect(starts.map(\.agentType) == ["general-purpose", "general-purpose"])
        #expect(starts.first?.workingDirectory == "/Users/me/code/shop")
        #expect(starts.last?.workingDirectory == "/Users/me/code/shop/.claude/worktrees/agent-\(beta)")
    }

    @Test("A subagent that changes directory in a command is still where it started")
    func cdDoesNotMove() {
        let calls = CapturedEvents.named("PreToolUse", agent: gamma, in: ClaudeSubagentCaptures.foreground)
        #expect(!calls.isEmpty)
        #expect(calls.allSatisfy { $0.workingDirectory == "/Users/me/code/shop" })
    }

    @Test("The end of a turn lists the agents still running in the background, with their tasks")
    func backgroundList() {
        let stops = CapturedEvents.named("Stop", in: ClaudeSubagentCaptures.background)
        #expect(stops.first?.backgroundAgents?.map(\.agentID) == [alpha, beta])
        #expect(stops.first?.backgroundAgents?.map(\.description) == ["Alpha directory check", "Beta directory check"])
        #expect(stops.last?.backgroundAgents == [])

        // Still listing the agent that is stopping.
        let first = CapturedEvents.named("SubagentStop", agent: alpha, in: ClaudeSubagentCaptures.background)
        #expect(first.first?.backgroundAgents?.map(\.agentID) == [alpha, beta])
    }

    @Test("Claude Code's note on a subagent ties it to the call that started it")
    func note() throws {
        let note = try #require(ClaudeSubagentCaptures.notes[gamma])
        let read = try #require(AgentHookEvent.Delegation(note: Data(note.utf8), agentID: gamma))
        #expect(read.description == "Gamma directory check")
        #expect(read.toolUseID == "toolu_01Nh9yG6C11Tp6nMce2Fz4DK")
        #expect(read.agentType == "general-purpose")
        #expect(read.runsInBackground == false)
        #expect(read.agentID == gamma)
    }

    @Test("The note is found beside the transcript every event names")
    func noteLocation() throws {
        let payload = try #require(ClaudeSubagentCaptures.foreground.first { $0.payload.contains("\"SubagentStart\"") }?.payload)
        let read = try #require(AgentHookPayload(Data(payload.utf8), agent: .claude, sessionID: "s", ancestry: []))
        let transcript = try #require(read.transcriptPath)
        let url = try #require(AgentHookEvent.Delegation.noteURL(transcriptPath: transcript, agentID: gamma))
        #expect(url.path == "/Users/me/.claude/projects/-Users-me-code-shop/cc57cbca-7029-4013-a302-a18f70a93df2/subagents/agent-\(gamma).meta.json")
    }
}
