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

    public init(
        version: Int = 1,
        sessionID: String,
        agent: Agent,
        name: String,
        toolName: String? = nil,
        toolUseID: String? = nil,
        subagentID: String? = nil,
        source: String? = nil,
        ancestry: [ProcessAncestor] = []
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
    }

    /// Reads a hook's stdin. Nil when it is not a JSON object naming an event.
    public init?(payload: Data, agent: Agent, sessionID: String, ancestry: [ProcessAncestor]) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        func string(_ keys: String...) -> String? {
            keys.lazy.compactMap { object[$0] as? String }.first { !$0.isEmpty }
        }
        guard let name = string("hook_event_name", "hookEventName") else { return nil }
        self.init(
            sessionID: sessionID,
            agent: agent,
            name: name,
            toolName: string("tool_name", "name"),
            toolUseID: string("tool_use_id"),
            subagentID: string("agent_id"),
            source: string("source"),
            ancestry: ancestry
        )
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
