import Darwin
import Foundation

/// One thing an agent said about itself through its own hooks, cut down to
/// what a status needs.
///
/// Claude Code and Codex run a command at every turn boundary, tool call and
/// permission prompt, and hand it a JSON description on stdin. That is the
/// agent's own account of what it is doing, which no reading of its screen can
/// match: a spinner can be drawn over, a question can scroll away, and a line
/// of prose can look like a question. `relay-hook` is that command; it sends
/// one of these to the daemon that owns the terminal it ran in.
public struct AgentHookEvent: Codable, Sendable, Equatable {
    public enum Agent: String, Codable, Sendable {
        case claude
        case codex
    }

    /// Bumped only if a field changes meaning. The helper and the daemon come
    /// from the same bundle but not always the same build: a daemon outlives
    /// an update, and the helper it names is whichever one is installed now.
    public var version: Int
    public var sessionID: String
    public var agent: Agent
    /// `hook_event_name`, spelled as the agent spells it: `PreToolUse`, `Stop`.
    public var name: String
    public var toolName: String?
    public var toolUseID: String?
    /// Set by Claude on events that come from a subagent rather than the agent
    /// the person is talking to.
    public var subagentID: String?
    /// Why a `SessionStart` happened: `startup`, `resume`, `clear`, `compact`.
    public var source: String?
    /// The processes above the hook, nearest first.
    public var ancestry: [ProcessAncestor]

    // Everything below arrived after the first release of the helper, so each
    // is optional: a daemon older than the helper never reads them, and one
    // newer than it reads their absence as "not said".

    /// `cwd`: where the agent is working — on a subagent's event, where the
    /// subagent is. Claude Code moves it with the agent, into a worktree once
    /// one is entered, and a subagent started with `isolation: "worktree"`
    /// works in one of its own.
    public var workingDirectory: String?
    /// `agent_type` on a subagent's event: `Explore`, `general-purpose`, or a
    /// name the person defined.
    public var agentType: String?
    /// The work a call to Claude's `Agent` tool hands to a subagent, read off
    /// the call: on its `PreToolUse`, and with the subagent's id added on its
    /// `PostToolUse`.
    public var delegation: Delegation?
    /// What the subagent this event came from was handed, as Claude Code noted
    /// it beside the transcript. The event itself never says, so the helper
    /// reads the note; see `Delegation.noteURL`.
    public var assignment: Delegation?
    /// The subagents Claude Code lists as still running in the background, on
    /// `Stop` and `SubagentStop`. Nil when it did not say.
    public var backgroundAgents: [Delegation]?

    /// Work handed from one agent to another, as far as anything has said.
    public struct Delegation: Codable, Sendable, Equatable {
        /// The few words the calling agent gave the task.
        public var description: String?
        public var agentType: String?
        /// The subagent's `agent_id`, once something has named it.
        public var agentID: String?
        /// The `Agent` call that started it.
        public var toolUseID: String?
        public var runsInBackground: Bool?

        public init(
            description: String? = nil,
            agentType: String? = nil,
            agentID: String? = nil,
            toolUseID: String? = nil,
            runsInBackground: Bool? = nil
        ) {
            self.description = description
            self.agentType = agentType
            self.agentID = agentID
            self.toolUseID = toolUseID
            self.runsInBackground = runsInBackground
        }
    }

    public init(
        version: Int = 1,
        sessionID: String,
        agent: Agent,
        name: String,
        toolName: String? = nil,
        toolUseID: String? = nil,
        subagentID: String? = nil,
        source: String? = nil,
        ancestry: [ProcessAncestor] = [],
        workingDirectory: String? = nil,
        agentType: String? = nil,
        delegation: Delegation? = nil,
        assignment: Delegation? = nil,
        backgroundAgents: [Delegation]? = nil
    ) {
        self.version = version
        self.sessionID = sessionID
        self.agent = agent
        self.name = name
        self.toolName = toolName
        self.toolUseID = toolUseID
        self.subagentID = subagentID
        self.source = source
        self.ancestry = ancestry
        self.workingDirectory = workingDirectory
        self.agentType = agentType
        self.delegation = delegation
        self.assignment = assignment
        self.backgroundAgents = backgroundAgents
    }

    /// Reads a hook's stdin. Nil when it is not a JSON object naming an event.
    public init?(payload: Data, agent: Agent, sessionID: String, ancestry: [ProcessAncestor]) {
        guard let read = AgentHookPayload(payload, agent: agent, sessionID: sessionID, ancestry: ancestry) else {
            return nil
        }
        self = read.event
    }

    /// Whether this came from the agent the session is running, rather than
    /// from one that agent started.
    ///
    /// An agent can run another — `claude -p` from a shell tool is ordinary —
    /// and the inner one inherits the terminal and its environment, so its
    /// `Stop` would otherwise end the outer one's turn. Walking up from the
    /// hook, the session's own process must be reached through at most one
    /// agent. A node-hosted agent has no name to count, which only makes the
    /// check more lenient, never wrong.
    public func comesFromSessionAgent(sessionPID: Int32) -> Bool {
        guard let index = ancestry.firstIndex(where: { $0.pid == sessionPID }) else { return false }
        let agents = ancestry[...index].filter { Self.agentExecutables.contains($0.name) }
        return agents.count <= 1
    }

    static let agentExecutables: Set<String> = ["claude", "codex"]
}

/// A hook's stdin, read once for everything the helper wants from it.
public struct AgentHookPayload {
    public var event: AgentHookEvent
    /// Where Claude Code writes the conversation. Not sent on: the helper
    /// needs it only to find the note about a subagent, and the daemon not at
    /// all.
    public var transcriptPath: String?

    /// Every string a hook hands on is bounded, because the agent writes them
    /// and the sidebar draws them.
    static let longestDescription = 200
    static let longestName = 80
    static let mostBackgroundAgents = 32

    public init?(_ payload: Data, agent: AgentHookEvent.Agent, sessionID: String, ancestry: [ProcessAncestor]) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        func string(_ keys: String...) -> String? {
            keys.lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty }
        }
        guard let name = string("hook_event_name", "hookEventName") else { return nil }
        let toolName = string("tool_name", "name")
        let toolUseID = string("tool_use_id")
        event = AgentHookEvent(
            sessionID: sessionID,
            agent: agent,
            name: name,
            toolName: toolName,
            toolUseID: toolUseID,
            subagentID: string("agent_id"),
            source: string("source"),
            ancestry: ancestry,
            workingDirectory: string("cwd"),
            agentType: string("agent_type").map { Self.bounded($0, to: Self.longestName) },
            delegation: Self.delegation(
                tool: toolName,
                callID: toolUseID,
                input: object["tool_input"] as? [String: Any],
                response: object["tool_response"] as? [String: Any]
            ),
            backgroundAgents: (object["background_tasks"] as? [Any]).map(Self.backgroundAgents)
        )
        transcriptPath = string("transcript_path")
    }

    /// Claude's tool for starting a subagent is `Agent`, and was `Task`.
    static func startsSubagent(_ toolName: String?) -> Bool {
        toolName == "Agent" || toolName == "Task"
    }

    /// The call's input names the task; its answer, once there is one, names
    /// the agent — `agentId`, which is what every event from that agent then
    /// carries as `agent_id`. Claude answers a background call as soon as it
    /// has started the agent, and a foreground one only once it has finished.
    private static func delegation(
        tool: String?,
        callID: String?,
        input: [String: Any]?,
        response: [String: Any]?
    ) -> AgentHookEvent.Delegation? {
        guard startsSubagent(tool), let input else { return nil }
        let launchedAsync = (response?["isAsync"] as? Bool) ?? (response?["status"] as? String).map { $0 == "async_launched" }
        return AgentHookEvent.Delegation(
            description: text(input["description"], limit: longestDescription),
            agentType: text(input["subagent_type"], limit: longestName),
            agentID: (response?["agentId"] as? String).flatMap(identifier),
            toolUseID: callID,
            runsInBackground: launchedAsync ?? (input["run_in_background"] as? Bool)
        )
    }

    /// `background_tasks`, cut down to the subagents still going. A task
    /// leaves the list when it is done, so an entry is running unless it says
    /// otherwise.
    private static func backgroundAgents(_ tasks: [Any]) -> [AgentHookEvent.Delegation] {
        let ended: Set<String> = ["completed", "failed", "killed", "stopped", "cancelled", "error"]
        return tasks.lazy
            .compactMap { $0 as? [String: Any] }
            .filter { ($0["type"] as? String) == "subagent" && !ended.contains(($0["status"] as? String) ?? "") }
            .compactMap { task -> AgentHookEvent.Delegation? in
                guard let id = (task["id"] as? String).flatMap(identifier) else { return nil }
                return AgentHookEvent.Delegation(
                    description: text(task["description"], limit: longestDescription),
                    agentType: text(task["agent_type"], limit: longestName),
                    agentID: id,
                    runsInBackground: true
                )
            }
            .prefix(mostBackgroundAgents)
            .map { $0 }
    }

    private static func text(_ value: Any?, limit: Int) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : bounded(trimmed, to: limit)
    }

    private static func bounded(_ string: String, to limit: Int) -> String {
        string.count <= limit ? string : String(string.prefix(limit - 1)) + "…"
    }

    /// An agent id as Claude spells them — letters, digits, `-` and `_` — or
    /// nothing, since one goes into the path of the note read for it.
    static func identifier(_ raw: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !raw.isEmpty, raw.count <= 128, raw.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else {
            return nil
        }
        return raw
    }
}

public extension AgentHookEvent.Delegation {
    /// Where Claude Code keeps its note on a subagent: beside the transcript,
    /// in a folder named after it, as `subagents/agent-<id>.meta.json`.
    ///
    /// It is the only place a subagent's own events are tied to the call that
    /// started it: the note holds that call's id and the task's description,
    /// and every event of the subagent's names the subagent. The events do not
    /// say which call they belong to, and a foreground call names its agent
    /// only when it returns — so without the note, two agents of one type
    /// started together could only be told apart by guessing. The note is not
    /// documented; anything unexpected in it is read as no note at all.
    static func noteURL(transcriptPath: String, agentID: String) -> URL? {
        guard transcriptPath.hasSuffix(".jsonl"), let id = AgentHookPayload.identifier(agentID) else { return nil }
        return URL(fileURLWithPath: String(transcriptPath.dropLast(".jsonl".count)), isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent("agent-\(id).meta.json", isDirectory: false)
    }

    /// Reads the note. Nil unless it is a JSON object that names at least the
    /// call or the task.
    init?(note: Data, agentID: String) {
        guard let object = try? JSONSerialization.jsonObject(with: note) as? [String: Any] else { return nil }
        func text(_ key: String, limit: Int) -> String? {
            guard let value = (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value.count <= limit ? value : String(value.prefix(limit - 1)) + "…"
        }
        let description = text("description", limit: AgentHookPayload.longestDescription)
        let call = text("toolUseId", limit: 128)
        guard description != nil || call != nil else { return nil }
        self.init(
            description: description,
            agentType: text("agentType", limit: AgentHookPayload.longestName),
            agentID: agentID,
            toolUseID: call,
            runsInBackground: (object["requestShape"] as? String).map { $0 == "background" }
        )
    }
}

public struct ProcessAncestor: Codable, Sendable, Equatable {
    public var pid: Int32
    public var name: String

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }

    /// The parents of this process, nearest first, as far as `launchd`.
    public static func ofCurrentProcess(limit: Int = 32) -> [ProcessAncestor] {
        var chain: [ProcessAncestor] = []
        var pid = getppid()
        while pid > 1, chain.count < limit, let entry = describe(pid) {
            chain.append(ProcessAncestor(pid: pid, name: entry.name))
            pid = entry.parent
        }
        return chain
    }

    private static func describe(_ pid: pid_t) -> (name: String, parent: pid_t)? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var query: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&query, u_int(query.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let name = withUnsafeBytes(of: info.kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return (name, info.kp_eproc.e_ppid)
    }
}

/// What a terminal Relay started tells the hooks that run inside it.
///
/// Outside Relay none of these is set, which is what makes the hook a no-op
/// there: the same entry in `~/.claude/settings.json` serves every terminal
/// on the machine, and only Relay's have anywhere to send to.
public enum AgentHookEnvironment {
    public static let sessionKey = "RELAY_SESSION_ID"
    public static let socketKey = "RELAY_HOOK_SOCKET"
    /// The helper to run, named by the daemon that started the terminal, so
    /// the entry in an agent's settings never has to say where Relay is.
    public static let helperKey = "RELAY_HOOK"
}

/// Hands an event to the daemon: one JSON line over a Unix socket.
public enum AgentHookDelivery {
    /// Never long enough to be felt: the agent waits for its hooks.
    public static let timeout: TimeInterval = 1

    @discardableResult
    public static func send(_ event: AgentHookEvent, to path: String) -> Bool {
        guard var line = try? JSONEncoder().encode(event) else { return false }
        line.append(0x0A)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var limit = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return false }
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, 103) }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }

        return line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
