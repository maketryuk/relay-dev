import Foundation

/// Everything the daemon needs in order to spawn a session.
public struct SessionSpec: Codable, Sendable, Hashable {
    public var projectID: ProjectID
    public var kind: SessionKind
    public var name: String
    public var workingDirectory: String
    /// Empty means "use the login shell in interactive mode".
    public var command: [String]
    public var environment: [String: String]
    public var columns: Int
    public var rows: Int
    public var role: SessionRole

    public init(
        projectID: ProjectID,
        kind: SessionKind,
        name: String,
        workingDirectory: String,
        command: [String] = [],
        environment: [String: String] = [:],
        columns: Int = 120,
        rows: Int = 32,
        role: SessionRole = .interactive
    ) {
        self.projectID = projectID
        self.kind = kind
        self.name = name
        self.workingDirectory = workingDirectory
        self.command = command.isEmpty ? kind.defaultCommand : command
        self.environment = environment
        self.columns = columns
        self.rows = rows
        self.role = role
    }

    /// Tolerant decoding keeps a session created by an older peer readable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        kind = try container.decode(SessionKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        command = try container.decodeIfPresent([String].self, forKey: .command) ?? []
        environment = try container.decodeIfPresent([String: String].self, forKey: .environment) ?? [:]
        columns = try container.decodeIfPresent(Int.self, forKey: .columns) ?? 120
        rows = try container.decodeIfPresent(Int.self, forKey: .rows) ?? 32
        role = try container.decodeIfPresent(SessionRole.self, forKey: .role) ?? .interactive
    }
}

/// Immutable view of a live session, as reported by the daemon.
public struct SessionSnapshot: Codable, Sendable, Hashable, Identifiable {
    public var id: SessionID
    public var projectID: ProjectID
    public var kind: SessionKind
    public var name: String
    public var workingDirectory: String
    public var command: [String]
    public var status: RuntimeStatus
    public var pid: Int32?
    public var exitCode: Int32?
    public var startedAt: Date
    public var lastActivityAt: Date
    public var columns: Int
    public var rows: Int
    public var role: SessionRole
    /// What the running program calls itself, via `OSC 0/1/2`.
    public var title: String?
    /// True once the user has renamed the session by hand, after which the
    /// reported title stops overriding it.
    public var isNameUserDefined: Bool
    /// Whether an agent has said, through its hooks or its title, that it is
    /// running in this terminal — the way a shell session learns that
    /// somebody typed `claude` into it.
    public var hostsAgent: Bool
    /// The subagents the session's agent has started, in the order it started
    /// them, for as long as the daemon keeps them: while they work, and a
    /// little after they finish.
    public var subagents: [SubagentSnapshot]

    public init(
        id: SessionID,
        projectID: ProjectID,
        kind: SessionKind,
        name: String,
        workingDirectory: String,
        command: [String],
        status: RuntimeStatus,
        pid: Int32?,
        exitCode: Int32?,
        startedAt: Date,
        lastActivityAt: Date,
        columns: Int,
        rows: Int,
        role: SessionRole = .interactive,
        title: String? = nil,
        isNameUserDefined: Bool = false,
        hostsAgent: Bool = false,
        subagents: [SubagentSnapshot] = []
    ) {
        self.id = id
        self.projectID = projectID
        self.kind = kind
        self.name = name
        self.workingDirectory = workingDirectory
        self.command = command
        self.status = status
        self.pid = pid
        self.exitCode = exitCode
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.columns = columns
        self.rows = rows
        self.role = role
        self.title = title
        self.isNameUserDefined = isNameUserDefined
        self.hostsAgent = hostsAgent
        self.subagents = subagents
    }

    /// Whether this session has a status worth marking: it is an agent, or has
    /// one in it. A plain terminal does not — a shell at its prompt, a build
    /// running in it, a `vim` — and marking one said "working" whenever it
    /// printed anything, which is what a terminal is for.
    public var reportsStatus: Bool {
        kind.isAgent || hostsAgent
    }

    /// The name to show: what the user chose, otherwise what the program calls
    /// itself, otherwise the default assigned at creation.
    public var displayName: String {
        if isNameUserDefined { return name }
        if let title, !title.isEmpty { return title }
        return name
    }

    /// Tolerant decoding keeps a snapshot from an older daemon readable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(SessionID.self, forKey: .id)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        kind = try container.decode(SessionKind.self, forKey: .kind)
        name = try container.decode(String.self, forKey: .name)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        command = try container.decodeIfPresent([String].self, forKey: .command) ?? []
        status = try container.decode(RuntimeStatus.self, forKey: .status)
        pid = try container.decodeIfPresent(Int32.self, forKey: .pid)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        lastActivityAt = try container.decode(Date.self, forKey: .lastActivityAt)
        columns = try container.decodeIfPresent(Int.self, forKey: .columns) ?? 120
        rows = try container.decodeIfPresent(Int.self, forKey: .rows) ?? 32
        role = try container.decodeIfPresent(SessionRole.self, forKey: .role) ?? .interactive
        title = try container.decodeIfPresent(String.self, forKey: .title)
        isNameUserDefined = try container.decodeIfPresent(Bool.self, forKey: .isNameUserDefined) ?? false
        hostsAgent = try container.decodeIfPresent(Bool.self, forKey: .hostsAgent) ?? false
        // A daemon older than the field has none to send, and a list this
        // build cannot read costs the rows, never the session.
        subagents = (try? container.decodeIfPresent([SubagentSnapshot].self, forKey: .subagents)) ?? []
    }
}

/// A subagent a session's agent started, as the daemon last heard of it.
///
/// Not a session: it has no terminal of its own, and nothing can be typed to
/// it. It is here so the sidebar can say that it exists, what it was asked to
/// do and whether it is still at it — under the worktree it is working in.
public struct SubagentSnapshot: Codable, Sendable, Hashable, Identifiable {
    /// Claude Code's `agent_id`.
    public var id: String
    public var agentType: String?
    /// The few words the agent that started it gave the task. Nil until
    /// something has said which task is this one's.
    public var description: String?
    /// Where it works, from its own events; nil until one has arrived.
    public var workingDirectory: String?
    /// `working`, `waiting` or `finished`.
    public var status: RuntimeStatus
    public var runsInBackground: Bool
    public var startedAt: Date
    public var finishedAt: Date?

    public init(
        id: String,
        agentType: String? = nil,
        description: String? = nil,
        workingDirectory: String? = nil,
        status: RuntimeStatus,
        runsInBackground: Bool = false,
        startedAt: Date,
        finishedAt: Date? = nil
    ) {
        self.id = id
        self.agentType = agentType
        self.description = description
        self.workingDirectory = workingDirectory
        self.status = status
        self.runsInBackground = runsInBackground
        self.startedAt = startedAt
        self.finishedAt = finishedAt
    }

    /// Tolerant for the same reason the snapshot around it is, and a status
    /// this build does not know reads as work rather than failing the list.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        agentType = try container.decodeIfPresent(String.self, forKey: .agentType)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        status = (try? container.decode(RuntimeStatus.self, forKey: .status)) ?? .working
        runsInBackground = try container.decodeIfPresent(Bool.self, forKey: .runsInBackground) ?? false
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt) ?? .distantPast
        finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
    }
}
