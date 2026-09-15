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
    case start
    case stop
    case restart
    case logs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .start: "Start"
        case .stop: "Stop"
        case .restart: "Restart"
        case .logs: "Logs"
        }
    }

    var sessionPrefix: String {
        switch self {
        case .start: "start"
        case .stop: "stop"
        case .restart: "restart"
        case .logs: "logs"
        }
    }

    func arguments(for container: DockerContainer) -> [String] {
        switch self {
        case .start: ["start", container.name]
        case .stop: ["stop", container.name]
        case .restart: ["restart", container.name]
        case .logs: ["logs", "--follow", "--tail", "200", container.name]
        }
    }
}
