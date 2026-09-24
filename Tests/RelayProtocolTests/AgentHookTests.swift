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
