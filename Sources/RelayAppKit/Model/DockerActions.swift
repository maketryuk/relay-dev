import Foundation
import RelayProtocol

/// Compose-level actions the sidebar offers.
enum ComposeAction: String, CaseIterable, Identifiable {
    case up
    case down
    case restart
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .up: "Up"
        case .down: "Down"
        case .restart: "Restart"
        case .logs: "Logs"
        }
    }

    var symbolName: String {
        switch self {
        case .up: "play.fill"
        case .down: "stop.fill"
        case .restart: "arrow.clockwise"
        case .logs: "text.alignleft"
        }
    }

    var arguments: [String] {
        switch self {
        // `up` stays attached so the user sees build and startup output; the
        // session is the log view.
        case .up: ["up"]
        case .down: ["down"]
        case .restart: ["restart"]
        case .logs: ["logs", "--follow", "--tail", "200"]
        }
    }

    var sessionName: String {
        "compose \(rawValue)"
    }
}

/// Actions for a single container.
enum ContainerAction: String, CaseIterable, Identifiable {
    /// A prompt inside the container, which is what you open a container for.
    case shell
    case start
    case stop
    case restart
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shell: "Shell"
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        case .logs: "Logs"
        }
    }

    var sessionPrefix: String {
        switch self {
        case .shell: "shell"
        case .start: "start"
        case .stop: "stop"
        case .restart: "restart"
        case .logs: "logs"
        }
    }

    /// Whether the action is something to watch rather than something that
    /// happens. Starting a container finishes in a second and leaves nothing to
    /// read; a prompt inside one is the opposite of that.
    var needsTerminal: Bool {
        switch self {
        case .shell, .logs: true
        case .start, .stop, .restart: false
        }
    }

    /// Bash where the image has it and sh where it does not, which is most of
    /// them. Asked with `command -v` rather than by trying to exec bash and
    /// falling back: a failed `exec` ends the shell rather than carrying on to
    /// the next command, so the fallback would never run.
    static let preferredShell = "command -v bash >/dev/null 2>&1 && exec bash || exec sh"

    func arguments(for container: DockerContainer) -> [String] {
        switch self {
        case .shell: ["exec", "--interactive", "--tty", container.name, "sh", "-c", Self.preferredShell]
        case .start: ["start", container.name]
        case .stop: ["stop", container.name]
        case .restart: ["restart", container.name]
        case .logs: ["logs", "--follow", "--tail", "200", container.name]
        }
    }
}
