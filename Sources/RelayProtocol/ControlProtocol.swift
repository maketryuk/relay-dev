import Foundation

/// How the `relay` command talks to the running app.
///
/// Not the daemon's protocol, and versioned apart from it. The daemon owns
/// processes and outlives the app; this reaches the app itself — the model the
/// sidebar is drawn from — so a command is carried out by the code the window
/// uses and is on screen as soon as it is done. One JSON line each way over a
/// Unix socket, and then the connection closes.
public enum ControlProtocol {
    /// Bumped only when a field changes meaning or a command goes away. A new
    /// command or a new field needs no bump: an app that does not know a
    /// command says so by name, and a field nobody reads is ignored.
    public static let version = 1

    /// The longest request the app reads. A prompt is the only long thing a
    /// command carries, and a megabyte of one is not a prompt.
    public static let requestLimit = 1 << 20

    /// JSON the way both ends write it.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = MessageFraming.makeEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func encodeLine(_ value: some Encodable) throws -> Data {
        try MessageFraming.encode(value, using: makeEncoder())
    }
}

/// What a terminal Relay started tells the `relay` command run inside it.
public enum ControlEnvironment {
    /// The control socket of the app whose daemon started the terminal, so a
    /// command typed in Relay Dev reaches Relay Dev.
    public static let socketKey = "RELAY_CONTROL_SOCKET"
    /// The command itself, for a shell whose profile rebuilt `PATH` without it.
    public static let executableKey = "RELAY_CLI"

    /// The socket to use: the one the terminal names, or else the socket of
    /// the flavour this process belongs to, which is the released app's unless
    /// `RELAY_FLAVOUR` says otherwise.
    public static func socketPath(in environment: [String: String], bundleIdentifier: String?) -> String {
        if let named = environment[socketKey], !named.isEmpty { return named }
        let flavour = RelayFlavour.resolve(
            environment: environment[RelayFlavour.environmentKey],
            bundleIdentifier: bundleIdentifier
        )
        return RelayPaths.controlSocketURL(beside: RelayPaths.socketURL(for: flavour)).path
    }
}

/// One command, as the `relay` executable sends it.
public struct ControlRequest: Codable, Sendable, Equatable {
    public var version: Int
    /// Where the command was run, which is what "this worktree" means when
    /// none is named.
    public var directory: String
    /// The terminal it was run in, when Relay started that terminal. It names
    /// the project even after the shell has wandered out of it.
    public var sessionID: String?
    public var command: ControlCommand

    public init(
        version: Int = ControlProtocol.version,
        directory: String,
        sessionID: String? = nil,
        command: ControlCommand
    ) {
        self.version = version
        self.directory = directory
        self.sessionID = sessionID
        self.command = command
    }

    /// Reads one request line.
    ///
    /// Tells a line that is not a request apart from a request for a command
    /// this build does not have — which is what an older app has to say to a
    /// newer command, and has to say in words.
    public static func decode(_ line: Data) -> Result<ControlRequest, ControlFailure> {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            return .failure(ControlFailure(.badRequest, "The request is not a JSON object."))
        }
        guard let version = object["version"] as? Int else {
            return .failure(ControlFailure(.badRequest, "The request has no version."))
        }
        guard version <= ControlProtocol.version else {
            return .failure(ControlFailure(
                .unsupportedVersion,
                "This Relay speaks version \(ControlProtocol.version) and the command version \(version). Update Relay."
            ))
        }
        if let command = object["command"] as? [String: Any], command.count == 1,
           let name = command.keys.first, ControlCommand.Name(rawValue: name) == nil {
            return .failure(ControlFailure(.unknownCommand, "This Relay has no command called \(name). Update Relay."))
        }
        do {
            return .success(try MessageFraming.makeDecoder().decode(ControlRequest.self, from: line))
        } catch {
            return .failure(ControlFailure(.badRequest, "The request could not be read: \(error)"))
        }
    }
}

/// What the app can be asked to do.
///
/// Each case encodes as an object with one key, its name, holding its
/// arguments, and an argument left out is absent rather than null — the shape
/// the daemon's messages have, pinned by `ControlProtocolTests`.
public enum ControlCommand: Codable, Sendable, Equatable {
    case worktreeList
    case worktreeCurrent
    /// `base` is where a new branch starts; nil is git's `HEAD` in the
    /// project's folder. `agent` names a session preset to start in it, and
    /// `prompt` is typed into that agent once it is ready for it.
    case worktreeCreate(name: String, base: String?, agent: String?, prompt: String?)
    /// `target` is a branch, a folder name or a path; nil is the worktree the
    /// command was run in.
    case worktreeRemove(target: String?, force: Bool)
    /// A nil `status` leaves it as it is unless `clearsStatus`; a nil
    /// `comment` leaves it, and an empty one clears it.
    case worktreeSet(target: String?, status: WorktreeWorkStatus?, clearsStatus: Bool, comment: String?)

    /// The key each case is encoded under, which is how a request for a
    /// command this build lacks is told from one that is malformed.
    public enum Name: String, CaseIterable, Sendable {
        case worktreeList
        case worktreeCurrent
        case worktreeCreate
        case worktreeRemove
        case worktreeSet
    }

    public var name: Name {
        switch self {
        case .worktreeList: .worktreeList
        case .worktreeCurrent: .worktreeCurrent
        case .worktreeCreate: .worktreeCreate
        case .worktreeRemove: .worktreeRemove
        case .worktreeSet: .worktreeSet
        }
    }
}

/// The app's answer. Which of the optional fields are set depends on the
/// command; each is named for what it holds, so the line reads the same to an
/// agent as to the command that prints it.
public struct ControlResponse: Codable, Sendable, Equatable {
    public var version: Int
    public var ok: Bool
    public var error: ControlFailure?
    /// The project the command was about.
    public var project: ControlProject?
    /// `list`.
    public var worktrees: [ControlWorktree]?
    /// `current`, `create`, `set`, and `rm`, which describes what it removed.
    public var worktree: ControlWorktree?
    /// The preset `create` started in the new worktree.
    public var agent: String?
    /// What `rm` did to the worktree's branch.
    public var branch: ControlBranchOutcome?

    public init(
        version: Int = ControlProtocol.version,
        ok: Bool = true,
        error: ControlFailure? = nil,
        project: ControlProject? = nil,
        worktrees: [ControlWorktree]? = nil,
        worktree: ControlWorktree? = nil,
        agent: String? = nil,
        branch: ControlBranchOutcome? = nil
    ) {
        self.version = version
        self.ok = ok
        self.error = error
        self.project = project
        self.worktrees = worktrees
        self.worktree = worktree
        self.agent = agent
        self.branch = branch
    }

    public static func failure(_ failure: ControlFailure) -> ControlResponse {
        ControlResponse(ok: false, error: failure)
    }
}

/// Why a command was not carried out, in a sentence meant to be read out, and
/// a code meant to be matched.
public struct ControlFailure: Codable, Sendable, Equatable, Error {
    /// Open rather than an enum, so a code a newer app sends still decodes.
    public struct Code: RawRepresentable, Codable, Hashable, Sendable {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        public static let badRequest = Code(rawValue: "bad_request")
        public static let requestTooLarge = Code(rawValue: "request_too_large")
        public static let unknownCommand = Code(rawValue: "unknown_command")
        public static let unsupportedVersion = Code(rawValue: "unsupported_version")
        public static let notInProject = Code(rawValue: "not_in_project")
        public static let notARepository = Code(rawValue: "not_a_repository")
        public static let notInWorktree = Code(rawValue: "not_in_worktree")
        public static let noSuchWorktree = Code(rawValue: "no_such_worktree")
        public static let ambiguousWorktree = Code(rawValue: "ambiguous_worktree")
        public static let noSuchPreset = Code(rawValue: "no_such_preset")
        public static let invalidArgument = Code(rawValue: "invalid_argument")
        public static let alreadyOpen = Code(rawValue: "already_open")
        public static let uncommittedChanges = Code(rawValue: "uncommitted_changes")
        public static let refused = Code(rawValue: "refused")
        /// The command's own: what was typed is not a command.
        public static let usage = Code(rawValue: "usage")
        /// The command's own: nothing answered on the socket.
        public static let notRunning = Code(rawValue: "not_running")
        /// The command's own: what answered was not an answer.
        public static let badResponse = Code(rawValue: "bad_response")
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

public struct ControlProject: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var path: String

    public init(id: String, name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

/// One worktree, as a command reports it.
public struct ControlWorktree: Codable, Sendable, Equatable {
    /// As git spells it, which is what a note is filed under.
    public var path: String
    /// Nil when `HEAD` is detached.
    public var branch: String?
    /// What the sidebar calls it: the branch, or the folder when there is none.
    public var name: String
    public var head: String?
    /// The checkout the repository lives in, which git never removes.
    public var isMain: Bool
    /// The project's own folder, which is removed by removing the project.
    public var isProjectFolder: Bool
    /// The one the command was run in.
    public var isCurrent: Bool
    public var isLocked: Bool
    /// As last read for the sidebar rather than read again for this answer;
    /// nil until it has been.
    public var changes: ControlChanges?
    public var note: WorktreeNote?

    public init(
        path: String,
        branch: String?,
        name: String,
        head: String? = nil,
        isMain: Bool = false,
        isProjectFolder: Bool = false,
        isCurrent: Bool = false,
        isLocked: Bool = false,
        changes: ControlChanges? = nil,
        note: WorktreeNote? = nil
    ) {
        self.path = path
        self.branch = branch
        self.name = name
        self.head = head
        self.isMain = isMain
        self.isProjectFolder = isProjectFolder
        self.isCurrent = isCurrent
        self.isLocked = isLocked
        self.changes = changes
        self.note = note
    }
}

/// What the sidebar's heading says about a worktree's working copy.
public struct ControlChanges: Codable, Sendable, Equatable {
    public var changedFiles: Int
    public var insertions: Int
    public var deletions: Int
    public var ahead: Int
    public var behind: Int

    public init(changedFiles: Int, insertions: Int, deletions: Int, ahead: Int, behind: Int) {
        self.changedFiles = changedFiles
        self.insertions = insertions
        self.deletions = deletions
        self.ahead = ahead
        self.behind = behind
    }
}

/// What removing a worktree did to its branch.
public enum ControlBranchOutcome: String, Codable, Sendable, CaseIterable {
    /// Relay made it, and its work is already in the base: merged, squashed
    /// or rebased in.
    case deleted
    /// Relay made it, and it has commits that exist nowhere else.
    case keptUnmerged = "kept-unmerged"
    /// Somebody else's branch, one another worktree has checked out, or none
    /// at all.
    case untouched
}
