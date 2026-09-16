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
public struct DockerSnapshot: Codable, Sendable, Hashable {
    /// False when the CLI is missing or the engine is not reachable.
    public var isAvailable: Bool
    public var composeProjectName: String?
    public var containers: [DockerContainer]
    /// Why Docker is unavailable, shown verbatim so the user can act on it.
    public var message: String?

    public init(
        isAvailable: Bool,
        composeProjectName: String? = nil,
        containers: [DockerContainer] = [],
        message: String? = nil
    ) {
        self.isAvailable = isAvailable
        self.composeProjectName = composeProjectName
        self.containers = containers
        self.message = message
    }

    public var aggregatedStatus: RuntimeStatus {
        containers.isEmpty ? .offline : RuntimeStatus.aggregate(containers.map(\.runtimeStatus))
    }
}
