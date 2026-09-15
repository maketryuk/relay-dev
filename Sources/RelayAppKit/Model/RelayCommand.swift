import Foundation

/// Where a command appears in the shortcuts list.
enum ShortcutCategory: String, CaseIterable, Identifiable, Sendable {
    case application
    case sessions
    case services
    case projects

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: "Application"
        case .sessions: "Sessions"
        case .services: "Services"
        case .projects: "Projects"
        }
    }
}

/// Every action that can carry a keyboard shortcut.
enum RelayCommand: String, CaseIterable, Identifiable, Codable, Sendable {
    case commandPalette
    case openSettings
    case togglePorts
    case openSSHHosts
    case toggleRightSidebar
    case toggleLeftSidebar

    case newShell
    case newClaude
    case newCodex
    case closeSession
    case renameSession
    case nextSession
    case previousSession
    case focusTerminal
    case splitRight
    case splitDown
    case focusNextPane

    case startDefaultService
    case restartDefaultService

    case nextProject
    case previousProject
    case addProject
    case revealProject
    case projectSettings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandPalette: "Command Palette"
        case .openSettings: "Settings"
        case .togglePorts: "Ports"
        case .openSSHHosts: "SSH Hosts"
        case .toggleRightSidebar: "Toggle Project Panel"
        case .toggleLeftSidebar: "Toggle Sessions Sidebar"
        case .newShell: "New Shell"
        case .newClaude: "New Claude Session"
        case .newCodex: "New Codex Session"
        case .closeSession: "Close Session"
        case .renameSession: "Rename Session"
        case .nextSession: "Next Session"
        case .previousSession: "Previous Session"
        case .focusTerminal: "Focus Terminal"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .focusNextPane: "Focus Next Pane"
        case .startDefaultService: "Start Dev Service"
        case .restartDefaultService: "Restart Dev Service"
        case .nextProject: "Next Project"
        case .previousProject: "Previous Project"
        case .addProject: "Add Project"
        case .revealProject: "Open Project in Finder"
        case .projectSettings: "Project Settings"
        }
    }

    var category: ShortcutCategory {
        switch self {
        case .commandPalette, .openSettings, .togglePorts, .openSSHHosts,
             .toggleRightSidebar, .toggleLeftSidebar: .application
        case .newShell, .newClaude, .newCodex, .closeSession, .renameSession,
             .nextSession, .previousSession, .focusTerminal,
             .splitRight, .splitDown, .focusNextPane: .sessions
        case .startDefaultService, .restartDefaultService: .services
        case .nextProject, .previousProject, .addProject, .revealProject, .projectSettings: .projects
        }
    }

    /// Defaults follow macOS convention where one exists, and VS Code's where
    /// it does not. `⌘W` closes the session rather than the window: Relay is a
    /// single-window app, so closing a tab is what the key is for here.
    var defaultBinding: KeyBinding? {
        switch self {
        case .commandPalette: KeyBinding("p", .command)
        case .openSettings: KeyBinding(",", .command)
        case .togglePorts: KeyBinding("\\", .command)
        case .openSSHHosts: KeyBinding("s", [.command, .shift])
        case .toggleRightSidebar: KeyBinding("b", [.command, .option])
        case .toggleLeftSidebar: KeyBinding("b", .command)
        case .newShell: KeyBinding("t", .command)
        case .newClaude: KeyBinding("c", [.command, .shift])
        case .newCodex: KeyBinding("x", [.command, .shift])
        case .closeSession: KeyBinding("w", .command)
        case .renameSession: KeyBinding("r", [.command, .shift])
        case .nextSession: KeyBinding("]", [.command, .shift])
        case .previousSession: KeyBinding("[", [.command, .shift])
        case .focusTerminal: KeyBinding("return", .command)
        case .splitRight: KeyBinding("d", .command)
        case .splitDown: KeyBinding("d", [.command, .shift])
        case .focusNextPane: KeyBinding("]", [.command, .option])
        case .startDefaultService: KeyBinding("r", .command)
        case .restartDefaultService: KeyBinding("r", [.command, .option])
        case .nextProject: KeyBinding("down", [.command, .option])
        case .previousProject: KeyBinding("up", [.command, .option])
        case .addProject: KeyBinding("n", [.command, .shift])
        case .revealProject: KeyBinding("o", [.command, .shift])
        case .projectSettings: KeyBinding(",", [.command, .shift])
        }
    }
}
