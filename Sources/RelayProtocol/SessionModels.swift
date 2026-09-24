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
        hostsAgent: Bool = false
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
    }
}
