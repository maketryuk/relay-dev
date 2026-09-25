import Foundation
import RelayProtocol

/// A long-running process the project knows how to start.
///
/// Definitions are configuration and live with the project; the running process
/// is an ordinary daemon session tagged with this definition's id, which is how
/// a restarted GUI reconnects a service to its row in the sidebar.
struct ServiceDefinition: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    /// Written the way the user would type it into a shell.
    var command: String
    /// Started by the one-click Run Dev action and the ⌘R shortcut.
    var isDefault: Bool
    /// Set when detection guesses wrong.
    var urlOverride: String?

    init(
        id: String = UUID().uuidString,
        name: String,
        command: String,
        isDefault: Bool = false,
        urlOverride: String? = nil
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.isDefault = isDefault
        self.urlOverride = urlOverride
    }

    /// Services run through the login shell, so the command is passed through
    /// verbatim rather than being split on spaces — quoting and `&&` survive.
    var argv: [String] { ["/bin/sh", "-c", command] }
}

/// Lifecycle of a service, as the spec names them.
enum ServiceState: String, CaseIterable, Sendable {
    case stopped
    case starting
    case running
    case failed
    case stopping

    var displayName: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .failed: "Failed"
        case .stopping: "Stopping"
        }
    }

    var runtimeStatus: RuntimeStatus {
        switch self {
        case .stopped: .offline
        case .starting: .starting
        case .running: .working
        case .failed: .error
        case .stopping: .idle
        }
    }

    var isActive: Bool {
        self == .running || self == .starting || self == .stopping
    }

    /// Derives the service state from the session backing it, if any.
    ///
    /// A service has no PTY of its own: its state is simply how its session is
    /// doing, reinterpreted in service vocabulary.
    static func derive(from session: SessionSnapshot?) -> ServiceState {
        guard let session else { return .stopped }
        if let exitCode = session.exitCode {
            return exitCode == 0 ? .stopped : .failed
        }
        switch session.status {
        case .starting: return .starting
        case .error: return .failed
        default: return .running
        }
    }
}
