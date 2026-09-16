import Foundation

public struct DockerPort: Codable, Sendable, Hashable {
    public var published: Int
    public var target: Int
    public var networkProtocol: String

    public init(published: Int, target: Int, networkProtocol: String = "tcp") {
        self.published = published
        self.target = target
        self.networkProtocol = networkProtocol
    }

    public var url: URL? {
        guard networkProtocol == "tcp" else { return nil }
        return URL(string: "http://localhost:\(published)")
    }

    public var displayText: String {
        "\(published)→\(target)"
    }
}

public struct DockerContainer: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var service: String?
    public var image: String
    /// Raw docker state: running, exited, paused, restarting, created, dead.
    public var state: String
    /// Human string such as "Up 2 minutes" or "Exited (1) 5 seconds ago".
    public var status: String
    public var publishedPorts: [DockerPort]
    /// Compose project the container belongs to, from its labels.
    public var composeProject: String?
    /// Directory Compose was invoked from, which is how a container is matched
    /// to a project even when the stack lives in a subdirectory.
    public var composeWorkingDirectory: String?
    /// The Compose file this container was defined by, as Compose itself
    /// recorded it. Guessing which file a stack uses is guesswork; this is the
    /// answer, and it is written on every container Compose creates.
    public var composeConfigFile: String?

    public init(
        id: String,
        name: String,
        service: String? = nil,
        image: String = "",
        state: String,
        status: String = "",
        publishedPorts: [DockerPort] = [],
        composeProject: String? = nil,
        composeWorkingDirectory: String? = nil,
        composeConfigFile: String? = nil
    ) {
        self.id = id
        self.name = name
        self.service = service
        self.image = image
        self.state = state
        self.status = status
        self.publishedPorts = publishedPorts
        self.composeProject = composeProject
        self.composeWorkingDirectory = composeWorkingDirectory
        self.composeConfigFile = composeConfigFile
    }

    /// Maps docker vocabulary onto Relay's single status model so containers
    /// colour the same way as sessions and services.
    public var runtimeStatus: RuntimeStatus {
        switch state.lowercased() {
        case "running": .working
        case "restarting": .starting
        case "created", "paused": .idle
        case "exited":
            // "Exited (0)" is a clean stop; anything else failed.
            status.contains("(0)") ? .finished : .error
        case "dead": .error
        default: .offline
        }
    }
}

/// Everything the sidebar needs to render the Docker section.
/// An engine Relay found on the machine and could start on request.
///
/// Named rather than described by a command: the daemon says which engine it
/// recognised and the app decides what to run, so nothing Docker printed can
/// become something Relay executes.
public enum DockerEngine: String, Codable, Sendable, Hashable {
    case dockerDesktop
    case colima

    public var displayName: String {
        switch self {
        case .dockerDesktop: "Docker Desktop"
        case .colima: "Colima"
        }
    }
}

/// Why Docker has nothing to show.
///
/// Worth distinguishing, because the three have nothing in common but the empty
/// panel they produce. Relay ships no engine and replaces no part of one — it
/// shows containers, and when there is no engine on the machine at all that is
/// the honest end of it, not a button.
public enum DockerAbsence: Codable, Sendable, Hashable {
    /// No `docker` anywhere Relay looks.
    case notInstalled
    /// The CLI is installed and has nobody to talk to. Carries what to offer to
    /// start, or nil when Relay recognised no engine it could press for you —
    /// a button that cannot honour itself is worse than no button.
    case engineStopped(DockerEngine?)
    /// Something else went wrong, and `message` is what it said.
    case failed
}

public struct DockerSnapshot: Codable, Sendable, Hashable {
    /// False when the CLI is missing or the engine is not reachable.
    public var isAvailable: Bool
    public var composeProjectName: String?
    public var containers: [DockerContainer]
    /// Why Docker is unavailable, shown verbatim so the user can act on it.
    public var message: String?
    /// Which kind of nothing this is, when `isAvailable` is false.
    public var absence: DockerAbsence?

    public init(
        isAvailable: Bool,
        composeProjectName: String? = nil,
        containers: [DockerContainer] = [],
        message: String? = nil,
        absence: DockerAbsence? = nil
    ) {
        self.isAvailable = isAvailable
        self.composeProjectName = composeProjectName
        self.containers = containers
        self.message = message
        self.absence = absence
    }

    public var aggregatedStatus: RuntimeStatus {
        containers.isEmpty ? .offline : RuntimeStatus.aggregate(containers.map(\.runtimeStatus))
    }
}
