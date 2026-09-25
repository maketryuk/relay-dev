import Foundation
import Testing

@testable import RelayProtocol

@Suite("An agent's hook, as it arrives")
struct AgentHookEventTests {
    private let ancestry = [ProcessAncestor(pid: 4242, name: "claude")]

    private func event(_ json: String, agent: AgentHookEvent.Agent = .claude) -> AgentHookEvent? {
        AgentHookEvent(payload: Data(json.utf8), agent: agent, sessionID: "s", ancestry: ancestry)
    }

    /// Shaped like what Claude Code hands a hook: the documented fields, plus
    /// the tool input, which is cut down to nothing on the way.
    @Test("Claude's tool call is read down to its name and id")
    func claudeToolCall() throws {
        let parsed = try #require(event("""
        {"session_id":"abc","transcript_path":"/t.jsonl","cwd":"/code","hook_event_name":"PreToolUse",
         "tool_name":"Bash","tool_use_id":"toolu_01","tool_input":{"command":"rm -rf build"}}
        """))
        #expect(parsed.name == "PreToolUse")
        #expect(parsed.toolName == "Bash")
        #expect(parsed.toolUseID == "toolu_01")
        #expect(parsed.subagentID == nil)
        #expect(parsed.ancestry == ancestry)
    }

    @Test("A session start says why it started")
    func sessionStart() throws {
        let parsed = try #require(event(#"{"hook_event_name":"SessionStart","source":"resume"}"#))
        #expect(parsed.source == "resume")
    }

    @Test("A subagent's event says whose it is")
    func subagent() throws {
        let parsed = try #require(event(#"{"hook_event_name":"PostToolUse","tool_name":"Read","agent_id":"a1"}"#))
        #expect(parsed.subagentID == "a1")
    }

    @Test("Codex's events are read the same way")
    func codex() throws {
        let parsed = try #require(event(
            #"{"hook_event_name":"PermissionRequest","tool_name":"exec_command","turn_id":"t"}"#,
            agent: .codex
        ))
        #expect(parsed.agent == .codex)
        #expect(parsed.name == "PermissionRequest")
        #expect(parsed.toolName == "exec_command")
    }

    @Test("Anything that is not an event is nothing", arguments: [
        "", "not json", "[]", #"{"tool_name":"Bash"}"#, #"{"hook_event_name":""}"#,
    ])
    func rejected(json: String) {
        #expect(event(json) == nil)
    }

    @Test("It survives the trip to the daemon unchanged")
    func codable() throws {
        let original = try #require(event(#"{"hook_event_name":"Stop"}"#))
        let decoded = try JSONDecoder().decode(AgentHookEvent.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    @Test("A subagent's event and the call that started it survive the trip too")
    func subagentCodable() throws {
        var original = try #require(event("""
        {"hook_event_name":"PostToolUse","cwd":"/code/shop","agent_id":"a1","agent_type":"Explore","tool_name":"Agent",
         "tool_use_id":"toolu_1","tool_input":{"description":"Find it","subagent_type":"Explore"},
         "tool_response":{"agentId":"a2","isAsync":true}}
        """))
        original.assignment = .init(description: "Look around", agentID: "a1", toolUseID: "toolu_0")
        original.backgroundAgents = [.init(description: "Find it", agentID: "a2", runsInBackground: true)]
        let decoded = try JSONDecoder().decode(AgentHookEvent.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    /// The helper is whichever build is installed, and the daemon can be the
    /// previous one's: each has to read what the other writes.
    @Test("An event from a helper older than the subagent fields reads as saying nothing about them")
    func olderHelper() throws {
        let line = #"{"version":1,"sessionID":"s","agent":"claude","name":"Stop","ancestry":[]}"#
        let decoded = try JSONDecoder().decode(AgentHookEvent.self, from: Data(line.utf8))
        #expect(decoded.name == "Stop")
        #expect(decoded.workingDirectory == nil && decoded.delegation == nil && decoded.backgroundAgents == nil)
    }

    @Test("An event from a newer helper is read for what this build knows")
    func newerHelper() throws {
        let line = #"{"version":1,"sessionID":"s","agent":"claude","name":"Stop","ancestry":[],"futureField":{"x":1}}"#
        #expect(try JSONDecoder().decode(AgentHookEvent.self, from: Data(line.utf8)).name == "Stop")
    }

    @Test("Only the tool that starts agents is read as starting one", arguments: ["Agent", "Task"])
    func delegatingTools(tool: String) throws {
        let parsed = try #require(event("""
        {"hook_event_name":"PreToolUse","tool_name":"\(tool)","tool_use_id":"t","tool_input":{"description":"Map the code","subagent_type":"Explore"}}
        """))
        #expect(parsed.delegation?.description == "Map the code")
        #expect(parsed.delegation?.toolUseID == "t")
        let bash = try #require(event(#"{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"description":"List files"}}"#))
        #expect(bash.delegation == nil)
    }

    @Test("What an agent writes is bounded before the sidebar draws it")
    func bounded() throws {
        let long = String(repeating: "word ", count: 200)
        let parsed = try #require(event("""
        {"hook_event_name":"PreToolUse","tool_name":"Agent","tool_input":{"description":"\(long)"}}
        """))
        let description = try #require(parsed.delegation?.description)
        #expect(description.count == AgentHookPayload.longestDescription)
        #expect(description.hasSuffix("…"))
    }

    @Test("Only subagents still going are listed as running in the background")
    func backgroundTasks() throws {
        let parsed = try #require(event("""
        {"hook_event_name":"Stop","background_tasks":[
          {"id":"a1","type":"subagent","status":"running","description":"One","agent_type":"Explore"},
          {"id":"a2","type":"subagent","status":"completed","description":"Two"},
          {"id":"b1","type":"shell","status":"running","description":"npm run dev"},
          {"id":"../x","type":"subagent","status":"running"}
        ]}
        """))
        #expect(parsed.backgroundAgents == [.init(description: "One", agentType: "Explore", agentID: "a1", runsInBackground: true)])
        #expect(try #require(event(#"{"hook_event_name":"Stop"}"#)).backgroundAgents == nil)
    }

    @Test("The note on a subagent is looked for only under an id that is one")
    func noteLocation() {
        let transcript = "/Users/me/.claude/projects/-Users-me-code-shop/abc.jsonl"
        #expect(AgentHookEvent.Delegation.noteURL(transcriptPath: transcript, agentID: "a1b2")?.path
            == "/Users/me/.claude/projects/-Users-me-code-shop/abc/subagents/agent-a1b2.meta.json")
        #expect(AgentHookEvent.Delegation.noteURL(transcriptPath: transcript, agentID: "../../etc") == nil)
        #expect(AgentHookEvent.Delegation.noteURL(transcriptPath: "/tmp/abc.txt", agentID: "a1b2") == nil)
    }

    @Test("A note that is not one is no note", arguments: ["", "[]", #"{"spawnDepth":1}"#])
    func unreadableNote(note: String) {
        #expect(AgentHookEvent.Delegation(note: Data(note.utf8), agentID: "a1") == nil)
    }
}

@Suite("Whose hook it is")
struct AgentHookAncestryTests {
    private func event(_ chain: [(Int32, String)]) -> AgentHookEvent {
        AgentHookEvent(
            sessionID: "s",
            agent: .claude,
            name: "Stop",
            ancestry: chain.map { ProcessAncestor(pid: $0.0, name: $0.1) }
        )
    }

    @Test("The agent a session was started as")
    func agentSession() {
        #expect(event([(100, "claude"), (1, "launchd")]).comesFromSessionAgent(sessionPID: 100))
    }

    @Test("An agent started by hand in a shell session")
    func agentInShell() {
        #expect(event([(200, "claude"), (100, "zsh")]).comesFromSessionAgent(sessionPID: 100))
    }

    @Test("Not an agent that the session's agent started itself")
    func nestedAgent() {
        let nested = event([(300, "claude"), (250, "zsh"), (100, "claude")])
        #expect(!nested.comesFromSessionAgent(sessionPID: 100))
    }

    @Test("Not a terminal somewhere else")
    func foreign() {
        #expect(!event([(200, "claude"), (150, "zsh")]).comesFromSessionAgent(sessionPID: 100))
    }

    @Test("An agent that runs under node has no name to count, and is let through")
    func nodeHosted() {
        #expect(event([(200, "node"), (100, "zsh")]).comesFromSessionAgent(sessionPID: 100))
    }

    @Test("The current process can name its parents")
    func ownAncestry() {
        let chain = ProcessAncestor.ofCurrentProcess()
        #expect(chain.first?.pid == getppid())
        #expect(chain.allSatisfy { !$0.name.isEmpty })
    }
}

@Suite("Where hooks reach the daemon")
struct AgentHookSocketTests {
    @Test("Beside the daemon's own socket, so each daemon has its own")
    func beside() {
        let socket = URL(fileURLWithPath: "/tmp/relay-dev-501.sock")
        #expect(RelayPaths.hookSocketURL(beside: socket).path == "/tmp/relay-dev-501-hooks.sock")
    }
}
