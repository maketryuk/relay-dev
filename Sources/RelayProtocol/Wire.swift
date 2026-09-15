import Foundation

public enum RelayProtocolVersion {
    /// Bumped whenever the message set changes.
    ///
    /// This matters more here than in most apps: the daemon deliberately
    /// outlives the GUI, so a freshly built app routinely meets a daemon from
    /// the previous build. The mismatch is detected at handshake and the GUI
    /// restarts the daemon rather than misbehaving.
    public static let current = 4
}

/// Requests the GUI sends to the daemon.
public enum DaemonRequest: Codable, Sendable {
    case handshake(protocolVersion: Int, clientName: String)
    case listSessions
    /// Listening ports owned by one project's process tree.
    case listPorts(ProjectID)
    /// Compose state for a project directory.
    case dockerStatus(projectDirectory: String)
    /// One-shot docker invocation: start, stop or restart a container.
    case dockerCommand(projectDirectory: String, arguments: [String])
    case createSession(SessionSpec)
    /// Subscribe to a session's output. `replayScrollback` re-sends the stored
    /// buffer so a freshly launched GUI can reconstruct the terminal view.
    case attach(SessionID, replayScrollback: Bool)
    case detach(SessionID)
    case input(SessionID, Data)
    case resize(SessionID, columns: Int, rows: Int)
    case rename(SessionID, name: String)
    case terminate(SessionID)
    /// Drops an already-exited session from the registry.
    case forget(SessionID)
    case shutdownDaemon
    case ping
}

/// Successful payloads returned for a `DaemonRequest`.
public enum DaemonReply: Codable, Sendable {
    case ok
    /// `buildIdentity` lets the GUI notice that the daemon is running older
    /// code even when the protocol has not changed.
    case pong(daemonVersion: String, protocolVersion: Int, buildIdentity: String, uptime: TimeInterval)
    case sessions([SessionSnapshot])
    case ports([ListeningPort])
    case docker(DockerSnapshot)
    case commandOutput(status: Int32, output: String)
    case session(SessionSnapshot)
}

public struct DaemonError: Codable, Sendable, Error, LocalizedError {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }

    public static func unknownSession(_ id: SessionID) -> DaemonError {
        DaemonError(code: "unknown_session", message: "Session \(id.rawValue) is not known to the daemon")
    }

    public static func spawnFailed(_ reason: String) -> DaemonError {
        DaemonError(code: "spawn_failed", message: reason)
    }

    public static func protocolMismatch(_ got: Int) -> DaemonError {
        DaemonError(
            code: "protocol_mismatch",
            message: "Client speaks protocol \(got), daemon speaks \(RelayProtocolVersion.current)"
        )
    }
}

/// Unsolicited state changes pushed to every connected client.
public enum DaemonEvent: Codable, Sendable {
    case sessionCreated(SessionSnapshot)
    case sessionUpdated(SessionSnapshot)
    case sessionRemoved(SessionID)
    /// Raw PTY bytes. Only delivered to clients that attached to this session.
    case output(SessionID, Data)
    case daemonStopping
}

public struct ClientMessage: Codable, Sendable {
    public var requestID: UInt64
    public var request: DaemonRequest

    public init(requestID: UInt64, request: DaemonRequest) {
        self.requestID = requestID
        self.request = request
    }
}

public enum ServerMessage: Codable, Sendable {
    case reply(requestID: UInt64, DaemonReply)
    case failure(requestID: UInt64, DaemonError)
    case event(DaemonEvent)
}
