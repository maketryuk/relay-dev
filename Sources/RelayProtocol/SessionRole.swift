import Foundation

/// What a session is *for*.
///
/// Services reuse the entire session runtime — same PTY, same scrollback, same
/// reconnect behaviour — and differ only in how the UI presents them. That is
/// deliberate: a dev server whose logs cannot be scrolled or interrupted would
/// be a downgrade from running it in a terminal.
public enum SessionRole: Codable, Sendable, Hashable {
    /// A terminal the user drives directly.
    case interactive
    /// A managed long-running process, tied back to its definition in the
    /// project configuration so it can be recovered after a GUI restart.
    case service(id: String)

    public var serviceID: String? {
        if case let .service(id) = self { return id }
        return nil
    }

    public var isService: Bool { serviceID != nil }
}
