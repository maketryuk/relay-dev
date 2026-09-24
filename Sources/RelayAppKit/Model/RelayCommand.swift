import Foundation

/// Where a command appears in the shortcuts list.
enum ShortcutCategory: String, CaseIterable, Identifiable, Sendable {
    case application
    case sessions
    case services
    case projects
    case editor
    case browser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .application: "Application"
        case .sessions: "Sessions"
        case .services: "Services"
        case .projects: "Projects"
        case .editor: "Editor"
        case .browser: "Browser"
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
    case increaseTerminalFontSize
    case decreaseTerminalFontSize
    case resetTerminalFontSize

    case newShell
    case newClaude
    case newCodex
    case closeSession
    case reopenSession
    case renameSession
    case nextSession
    case previousSession
    case focusTerminal
    case splitRight
    case splitDown
    case focusNextPane

    case startDefaultService
    case restartDefaultService

    case reviewChanges
    case switchBranch
    case newWorktree
    case cleanUpWorktrees

    case goToDefinition
    case goBack
    case findInFile
    case searchProject
    case toggleMarkdownPreview

    case nextProject
    case previousProject
    case addProject
    case revealProject
    case projectSettings

    case newBrowserTab
    case toggleDesignMode
    case reloadBrowser
    case openBrowserDevTools

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandPalette: "Command Palette"
        case .openSettings: "Settings"
        case .togglePorts: "Ports"
        case .openSSHHosts: "SSH Hosts"
        case .toggleRightSidebar: "Toggle Project Panel"
        case .toggleLeftSidebar: "Toggle Sessions Sidebar"
        case .increaseTerminalFontSize: "Increase Font Size"
        case .decreaseTerminalFontSize: "Decrease Font Size"
        case .resetTerminalFontSize: "Reset Font Size"
        case .newShell: "New Shell"
        case .newClaude: "New Claude Session"
        case .newCodex: "New Codex Session"
        case .closeSession: "Close Pane"
        case .reopenSession: "Reopen Closed Session"
        case .renameSession: "Rename Session"
        case .nextSession: "Next Session"
        case .previousSession: "Previous Session"
        case .focusTerminal: "Focus Terminal"
        case .splitRight: "Split Right"
        case .splitDown: "Split Down"
        case .focusNextPane: "Focus Next Pane"
        case .startDefaultService: "Start Dev Service"
        case .restartDefaultService: "Restart Dev Service"
        case .reviewChanges: "Review Changes"
        case .switchBranch: "Switch Branch"
        case .newWorktree: "New Worktree"
        case .cleanUpWorktrees: "Clean Up Worktrees"
        case .nextProject: "Next Project"
        case .previousProject: "Previous Project"
        case .addProject: "Add Project"
        case .revealProject: "Open Project in Finder"
        case .projectSettings: "Project Settings"
        case .goToDefinition: "Go to Definition"
        case .goBack: "Back"
        case .findInFile: "Find"
        case .searchProject: "Find in Files"
        case .toggleMarkdownPreview: "Toggle Markdown Preview"
        case .newBrowserTab: "New Browser Tab"
        case .toggleDesignMode: "Toggle Design Mode"
        case .reloadBrowser: "Reload Page"
        case .openBrowserDevTools: "Developer Tools"
        }
    }

    var category: ShortcutCategory {
        switch self {
        case .commandPalette, .openSettings, .togglePorts, .openSSHHosts,
             .toggleRightSidebar, .toggleLeftSidebar,
             .increaseTerminalFontSize, .decreaseTerminalFontSize, .resetTerminalFontSize: .application
        case .newShell, .newClaude, .newCodex, .closeSession, .reopenSession, .renameSession,
             .nextSession, .previousSession, .focusTerminal,
             .splitRight, .splitDown, .focusNextPane: .sessions
        case .startDefaultService, .restartDefaultService: .services
        case .nextProject, .previousProject, .addProject, .revealProject,
             .projectSettings, .reviewChanges, .switchBranch, .newWorktree,
             .cleanUpWorktrees: .projects
        case .goToDefinition, .goBack, .findInFile, .searchProject, .toggleMarkdownPreview: .editor
        case .newBrowserTab, .toggleDesignMode, .reloadBrowser, .openBrowserDevTools: .browser
        }
    }

    /// Defaults follow macOS convention where one exists, and VS Code's where
    /// it does not. `⌘W` closes the pane rather than the window: Relay is a
    /// single-window app, so closing what is in front of you is what the key is
    /// for here. The identifier stays `closeSession`, because it is what a
    /// user's own rebinding is stored under.
    var defaultBinding: KeyBinding? {
        switch self {
        case .commandPalette: KeyBinding("p", .command)
        case .openSettings: KeyBinding(",", .command)
        case .togglePorts: KeyBinding("\\", .command)
        case .openSSHHosts: KeyBinding("s", [.command, .shift])
        case .toggleRightSidebar: KeyBinding("b", [.command, .option])
        case .toggleLeftSidebar: KeyBinding("b", .command)
        // `⌘+` rather than `⌘=`, because that is what the key is called on the
        // menu everywhere else; `⌘=` reaches the same command through a hidden
        // twin, since it is the same physical key without the Shift.
        case .increaseTerminalFontSize: KeyBinding("+", .command)
        case .decreaseTerminalFontSize: KeyBinding("-", .command)
        case .resetTerminalFontSize: KeyBinding("0", .command)
        case .newShell: KeyBinding("t", .command)
        case .newClaude: KeyBinding("c", [.command, .shift])
        case .newCodex: KeyBinding("x", [.command, .shift])
        case .closeSession: KeyBinding("w", .command)
        // `⌘T` opens a terminal here as it opens a tab in a browser, so the
        // shift on top of it means what it means there.
        case .reopenSession: KeyBinding("t", [.command, .shift])
        case .renameSession: KeyBinding("r", [.command, .shift])
        case .nextSession: KeyBinding("]", [.command, .shift])
        case .previousSession: KeyBinding("[", [.command, .shift])
        case .focusTerminal: KeyBinding("return", .command)
        case .splitRight: KeyBinding("d", .command)
        case .splitDown: KeyBinding("d", [.command, .shift])
        case .focusNextPane: KeyBinding("]", [.command, .option])
        // Deliberately unbound. `⌘R` means reload everywhere else on this
        // machine, and spending it on "start the dev service" would both
        // surprise people and burn the key the browser pane reloads its page
        // with. The command is still in the palette and the menu, and still
        // rebindable.
        case .startDefaultService: nil
        case .restartDefaultService: KeyBinding("r", [.command, .option])
        // `⌘G` is "find again" in a document app; Relay has no find, and
        // this is the thing you reach for as often.
        case .reviewChanges: KeyBinding("g", .command)
        // Deliberately unbound: it is one palette entry away, and the letters
        // left on `⌘` are worth more to things done many times an hour.
        case .switchBranch: nil
        // Unbound for the same reason: a piece of work is started a few times
        // a day, not a few times an hour.
        case .newWorktree: nil
        // And finished as often.
        case .cleanUpWorktrees: nil
        case .nextProject: KeyBinding("down", [.command, .option])
        case .previousProject: KeyBinding("up", [.command, .option])
        case .addProject: KeyBinding("n", [.command, .shift])
        case .revealProject: KeyBinding("o", [.command, .shift])
        case .projectSettings: KeyBinding(",", [.command, .shift])
        // Xcode's, because this is the one shortcut a Mac developer already
        // has in their hands; `⌘B`, which is JetBrains', is the sidebar here.
        case .goToDefinition: KeyBinding("j", [.command, .control])
        // And the bracket every editor and every browser goes back with.
        case .goBack: KeyBinding("[", .command)
        // `⌘F` finds in what is in front of you and `⇧⌘F` in everything, the
        // way every editor on this machine divides the two.
        case .findInFile: KeyBinding("f", .command)
        case .searchProject: KeyBinding("f", [.command, .shift])
        // VS Code's. Paste-and-match-style, which it means in a text view,
        // has nothing to do in a plain-text editor or a terminal.
        case .toggleMarkdownPreview: KeyBinding("v", [.command, .shift])
        // `⌘B` is the sidebar and `⌥⌘B` the other one, so the shift is what is
        // left of the letter a browser starts with.
        case .newBrowserTab: KeyBinding("b", [.command, .shift])
        // E for element, which is what design mode is for pointing at.
        case .toggleDesignMode: KeyBinding("e", [.command, .shift])
        // The key that was kept free for exactly this.
        case .reloadBrowser: KeyBinding("r", .command)
        // Chrome's and Safari's, so a hand that has opened an inspector
        // before does not have to learn it again.
        case .openBrowserDevTools: KeyBinding("i", [.command, .option])
        }
    }
}
