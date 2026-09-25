import Foundation
import Testing

import RelayProtocol
@testable import RelayDaemonCore

@Suite("Reading an agent's title")
struct AgentTitleTests {
    @Test("Claude Code's marks: ✳ waiting for a prompt, a spinner while it works", arguments: [
        ("✳ Claude Code", AgentTitleActivity.idle),
        ("⠂ Refactor the parser", .working),
        ("⠐ Claude Code", .working),
        ("◐ Fixing tests", .working),
        ("◓ Fixing tests", .working),
    ])
    func claude(title: String, expected: AgentTitleActivity) {
        #expect(AgentTitle.classify(title) == expected)
    }

    @Test("Gemini's glyphs, one for each state", arguments: [
        ("✦ Working on it", AgentTitleActivity.working),
        ("⏲ Working silently", .working),
        ("◇ Ready", .idle),
        ("✋ Action required", .waiting),
    ])
    func gemini(title: String, expected: AgentTitleActivity) {
        #expect(AgentTitle.classify(title) == expected)
    }

    @Test("A title that is not an agent's says nothing", arguments: [
        "zsh", "me@mac: ~/code/relay", "vim README.md", "*.swift", "",
    ])
    func plain(title: String) {
        #expect(AgentTitle.classify(title) == nil)
    }

    @Test("An agent asking for action says so in words too")
    func actionRequired() {
        #expect(AgentTitle.classify("Codex - action required") == .waiting)
    }
}

@Suite("An agent's status from its own signals")
struct AgentStatusTrackerTests {
    private let start = Date(timeIntervalSinceReferenceDate: 10000)

    private func at(_ seconds: TimeInterval) -> Date {
        start.addingTimeInterval(seconds)
    }

    private func hook(
        _ name: String,
        tool: String? = nil,
        id: String? = nil,
        subagent: String? = nil,
        source: String? = nil
    ) -> AgentHookEvent {
        AgentHookEvent(
            sessionID: "session",
            agent: .claude,
            name: name,
            toolName: tool,
            toolUseID: id,
            subagentID: subagent,
            source: source
        )
    }

    @Test("Nothing heard is nothing to say, and the screen is asked instead")
    func silence() {
        let tracker = AgentStatusTracker()
        #expect(tracker.status(now: start) == nil)
        #expect(!tracker.isAuthoritative(now: start))
    }

    @Test("A prompt is work, a tool call is work, and the end of the turn is finished")
    func turn() {
        var tracker = AgentStatusTracker()
        tracker.apply(hook("SessionStart", source: "startup"), at: at(0))
        #expect(tracker.status(now: at(0)) == .idle)
        tracker.apply(hook("UserPromptSubmit"), at: at(1))
        #expect(tracker.status(now: at(1)) == .working)
        tracker.apply(hook("PreToolUse", tool: "Bash", id: "a"), at: at(2))
        tracker.apply(hook("PostToolUse", tool: "Bash", id: "a"), at: at(5))
        #expect(tracker.status(now: at(5)) == .working)
        tracker.apply(hook("Stop"), at: at(8))
        #expect(tracker.status(now: at(8)) == .finished)
    }

    @Test("A compaction restarting the session mid-turn is not a new session")
    func compaction() {
        var tracker = AgentStatusTracker()
        tracker.apply(hook("UserPromptSubmit"), at: at(0))
        tracker.apply(hook("SessionStart", source: "compact"), at: at(1))
        #expect(tracker.status(now: at(1)) == .working)
    }

    @Test("A permission prompt waits until that tool runs, whatever else is reported")
    func permissionIsSticky() {
        var tracker = AgentStatusTracker()
        tracker.apply(hook("UserPromptSubmit"), at: at(0))
        tracker.apply(hook("PreToolUse", tool: "Bash", id: "rm"), at: at(1))
        // Claude does not say which call it is asking about.
        tracker.apply(hook("PermissionRequest", tool: "Bash"), at: at(1.1))
        #expect(tracker.status(now: at(1.1)) == .waiting)

        // A read running beside it finishes meanwhile.
        tracker.apply(hook("PostToolUse", tool: "Read", id: "read"), at: at(2))
        #expect(tracker.status(now: at(2)) == .waiting)

        tracker.apply(hook("PostToolUse", tool: "Bash", id: "rm"), at: at(9))
        #expect(tracker.status(now: at(9)) == .working)
    }

    @Test("A question to the person waits, and its answer ends the wait")
    func question() {
        var tracker = AgentStatusTracker()
        tracker.apply(hook("UserPromptSubmit"), at: at(0))
        tracker.apply(hook("PreToolUse", tool: "AskUserQuestion", id: "q"), at: at(1))
        #expect(tracker.status(now: at(1)) == .waiting)
        tracker.apply(hook("PostToolUse", tool: "AskUserQuestion", id: "q"), at: at(6))
        #expect(tracker.status(now: at(6)) == .working)
    }

    @Test("Codex's question tool is a question too")
    func codexQuestion() {
        #expect(AgentStatusTracker.isQuestion("request_user_input"))
        #expect(AgentStatusTracker.isQuestion("AskUserQuestion"))
        #expect(!AgentStatusTracker.isQuestion("Bash"))
    }

    @Test("A subagent's work is its parent's; only its need for the person counts")
    func subagent() {
        var tracker = AgentStatusTracker()
        tracker.apply(hook("UserPromptSubmit"), at: at(0))
        tracker.apply(hook("Stop", subagent: "child"), at: at(1))
        #expect(tracker.status(now: at(1)) == .working)

        tracker.apply(hook("PermissionRequest", tool: "Edit", subagent: "child"), at: at(2))
        #expect(tracker.status(now: at(2)) == .waiting)
        tracker.apply(hook("PostToolUse", tool: "Edit", id: "e", subagent: "child"), at: at(3))
        #expect(tracker.status(now: at(3)) == .working)
    }

    @Test("A turn that ends with its agents still at work in the background is not finished until they are")
    func backgroundAgentsHoldTheTurn() throws {
        // Claude Code's own run: two background agents started, the turn
        // ended while both ran, and each one's result came back as a prompt.
        let events = CapturedEvents.events(ClaudeSubagentCaptures.background)
        var tracker = AgentStatusTracker()
        var verdicts: [(String, RuntimeStatus?)] = []
        for (time, event) in events {
            tracker.apply(event, at: time)
            if ["Stop", "SubagentStop", "UserPromptSubmit"].contains(event.name) {
                verdicts.append((event.name, tracker.status(now: time)))
            }
        }
        #expect(verdicts.map(\.0) == [
            "UserPromptSubmit", "Stop", "SubagentStop", "SubagentStop",
            "UserPromptSubmit", "Stop", "UserPromptSubmit", "Stop",
        ])
        // The first `Stop` came while both were running.
        #expect(verdicts.map(\.1) == [
            .working, .working, .working, .working,
            .working, .finished, .working, .finished,
        ])
    }

    @Test("The last background agent finishing ends a turn nobody takes up again")
    func backgroundHandoff() {
        var tracker = AgentStatusTracker()
        let agent = AgentHookEvent.Delegation(description: "Watch the build", agentType: "Explore", agentID: "x", runsInBackground: true)
        tracker.apply(hook("UserPromptSubmit"), at: at(0))
        tracker.apply(AgentHookEvent(sessionID: "session", agent: .claude, name: "Stop", backgroundAgents: [agent]), at: at(1))
        #expect(tracker.status(now: at(60)) == .working)

        tracker.apply(AgentHookEvent(sessionID: "session", agent: .claude, name: "SubagentStop", subagentID: "x",
                                     backgroundAgents: [agent]), at: at(90))
        // Claude hands the result back as a prompt a moment later, and the
        // session must not flicker to finished in between.
        #expect(tracker.status(now: at(90.5)) == .working)
        #expect(tracker.status(now: at(90 + SubagentRoster.handoffGrace)) == .finished)
    }

    @Test("A turn held open by background work stays believed while that work keeps reporting")
    func heldTurnStaysFresh() {
        var tracker = AgentStatusTracker()
        let agent = AgentHookEvent.Delegation(agentType: "Explore", agentID: "x", runsInBackground: true)
        tracker.apply(hook("UserPromptSubmit"), at: at(0))
        tracker.apply(AgentHookEvent(sessionID: "session", agent: .claude, name: "Stop", backgroundAgents: [agent]), at: at(1))
        for minute in stride(from: 10.0, through: 40, by: 10) {
            tracker.apply(hook("PostToolUse", tool: "Bash", id: "b\(minute)", subagent: "x"), at: at(minute * 60))
        }
        #expect(tracker.status(now: at(41 * 60)) == .working)
    }

    @Test("A cancelled turn takes its foreground subagents with it")
    func cancelEndsForegroundSubagents() {
        var tracker = AgentStatusTracker()
        tracker.noteTitle("✳ Claude Code", at: at(0))
        tracker.apply(hook("UserPromptSubmit"), at: at(1))
        tracker.noteTitle("⠂ Exploring", at: at(1.1))
        tracker.apply(hook("SubagentStart", subagent: "x"), at: at(2))
        tracker.noteTitle("✳ Claude Code", at: at(5))
        let beforeTheHold = tracker.advance(to: at(5.5))
        #expect(!beforeTheHold)
        #expect(tracker.subagents.snapshots.map(\.status) == [.working])
        let afterIt = tracker.advance(to: at(5 + AgentStatusTracker.idleTitleHold))
        #expect(afterIt)
        #expect(tracker.subagents.snapshots.map(\.status) == [.finished])
    }

    @Test("A cancelled turn is idle once the agent's own idle mark has stayed up")
    func interruptedByTitle() {
        var tracker = AgentStatusTracker()
        tracker.noteTitle("✳ Claude Code", at: at(0))
        tracker.apply(hook("UserPromptSubmit"), at: at(1))
        tracker.noteTitle("⠂ Thinking", at: at(1.1))
        // No hook fires when the person presses Esc.
        tracker.noteTitle("✳ Claude Code", at: at(3))
        #expect(tracker.status(now: at(3.5)) == .working)
        #expect(tracker.status(now: at(3 + AgentStatusTracker.idleTitleHold)) == .idle)
    }

    @Test("An idle mark from before the last hook does not end the turn")
    func idleMarkBeforePrompt() {
        var tracker = AgentStatusTracker()
        tracker.noteTitle("✳ Claude Code", at: at(0))
        tracker.apply(hook("UserPromptSubmit"), at: at(1))
        #expect(tracker.status(now: at(10)) == .working)
    }

    @Test("An answer chosen in a permission prompt hands over to the title if no hook follows")
    func answeredPermission() {
        var tracker = AgentStatusTracker()
        tracker.apply(hook("UserPromptSubmit"), at: at(0))
        tracker.apply(hook("PermissionRequest", tool: "Bash"), at: at(1))
        tracker.noteTitle("⠂ Running", at: at(1))

        tracker.noteInput(Data("\u{1B}".utf8), at: at(2))
        #expect(tracker.status(now: at(2.5)) == .waiting)
        tracker.noteTitle("✳ Claude Code", at: at(2.2))
        #expect(tracker.status(now: at(2 + AgentStatusTracker.answerGrace)) == .idle)
    }

    @Test("Arrow keys in a prompt are not an answer")
    func navigatingIsNotAnswering() {
        var tracker = AgentStatusTracker()
        tracker.apply(hook("PermissionRequest", tool: "Bash"), at: at(0))
        tracker.noteInput(Data("\u{1B}[B".utf8), at: at(1))
        #expect(tracker.status(now: at(5)) == .waiting)
    }

    @Test("A hook gone quiet for half an hour gives way to the title")
    func staleHook() {
        var tracker = AgentStatusTracker()
        tracker.apply(hook("UserPromptSubmit"), at: at(0))
        let later = AgentStatusTracker.hookFreshness + 1
        tracker.noteTitle("✳ Claude Code", at: at(later - 1))
        #expect(tracker.status(now: at(later)) == .idle)
    }

    @Test("Without hooks the title tells the turn: a spinner is work, and ✳ after it is finished")
    func titleOnly() {
        var tracker = AgentStatusTracker()
        tracker.noteTitle("✳ Claude Code", at: at(0))
        #expect(tracker.status(now: at(0)) == .idle)
        tracker.noteTitle("⠂ Claude Code", at: at(1))
        #expect(tracker.status(now: at(1.5)) == .working)
        tracker.noteTitle("✳ Claude Code", at: at(4))
        #expect(tracker.status(now: at(4)) == .finished)
    }

    @Test("A spinner that stopped moving has stopped working")
    func frozenSpinner() {
        var tracker = AgentStatusTracker()
        tracker.noteTitle("⠋ Codex", at: at(0))
        #expect(tracker.status(now: at(1)) == .working)
        #expect(tracker.status(now: at(AgentStatusTracker.staleSpinner + 0.1)) == .finished)
    }

    @Test("When the agent has gone, nothing it said is left behind")
    func forgetting() {
        var tracker = AgentStatusTracker()
        tracker.apply(hook("SubagentStart", subagent: "x"), at: at(0))
        tracker.apply(hook("Stop"), at: at(0))
        tracker.noteTitle("✳ Claude Code", at: at(0))
        tracker.forgetAgent()
        #expect(tracker.status(now: at(1)) == nil)
        #expect(!tracker.hasEvidence)
        #expect(tracker.subagents.agents.isEmpty)
    }
}
