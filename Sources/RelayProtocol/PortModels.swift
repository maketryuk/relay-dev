import Foundation

/// A TCP port a project's process tree is listening on.
public struct ListeningPort: Codable, Sendable, Hashable, Identifiable {
    public var port: Int
    public var address: String
    public var pid: Int32
    public var processName: String
    /// The session or service this port was traced back to, when known.
    public var ownerSessionID: SessionID?
    public var ownerName: String?
    /// The project that owns the session, when the port belongs to one.
    public var ownerProjectID: ProjectID?

    public var id: String { "\(pid)-\(address)-\(port)" }

    public init(
        port: Int,
        address: String,
        pid: Int32,
        processName: String,
        ownerSessionID: SessionID? = nil,
        ownerName: String? = nil,
        ownerProjectID: ProjectID? = nil
    ) {
        self.port = port
        self.address = address
        self.pid = pid
        self.processName = processName
        self.ownerSessionID = ownerSessionID
        self.ownerName = ownerName
        self.ownerProjectID = ownerProjectID
    }

    /// True when Relay started the process, which is the only case where it may
    /// offer to stop it. External processes are listed but never touched.
    public var isManagedByRelay: Bool { ownerSessionID != nil }

    /// Loopback and wildcard binds are reachable at localhost; a port bound to a
    /// specific external interface is not.
    public var isLocallyReachable: Bool {
        address == "*" || address == "127.0.0.1" || address == "::1" || address == "0.0.0.0" || address == "[::]"
    }

    public var url: URL? {
        guard isLocallyReachable else { return nil }
        return URL(string: "http://localhost:\(port)")
    }
}
