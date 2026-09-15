import AppKit
import RelayProtocol
import RelayUI
import SwiftUI

/// Entry point. `main()` is invoked from the thin `RelayApp` executable rather
/// than via `@main` so the whole UI stays inside an importable library.
public enum RelayApplication {
    /// `App.main()` is main-actor isolated. Swift 6.2 infers that through the
    /// wrapper; 6.1 does not, and CI runs 6.1 — so it is stated explicitly
    /// rather than left to the compiler's mood.
    @MainActor
    public static func main() {
        RelayMainApp.main()
    }
}

struct RelayMainApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Relay", id: "relay.main") {
            RootView()
                .environment(model)
                .task { await model.bootstrap() }
                .onDisappear { model.persistImmediately() }
                .configureWindow { window in
                    // Zooming must be available for the double-click action to
                    // do anything, and dragging the background matches how a
                    // chrome-less window is expected to behave.
                    window.styleMask.insert([.resizable, .miniaturizable])
                    window.isMovableByWindowBackground = false
                    window.titlebarAppearsTransparent = true
                    window.collectionBehavior.insert(.fullScreenPrimary)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1240, height: 760)
        .commands { RelayCommands(model: model) }

        Window("Ports", id: PortsWindow.id) {
            PortsWindowView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 560, height: 480)
        .keyboardShortcut(nil)

        Window("SSH Hosts", id: SSHWindow.id) {
            SSHWindowView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 520, height: 480)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// The daemon keeps running by design, so quitting is genuinely just closing a
/// window — no process teardown to coordinate.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

extension View {
    /// Applies a binding only when one is configured, so an unbound command
    /// simply has no shortcut rather than a placeholder one.
    @ViewBuilder
    func relayShortcut(_ binding: KeyBinding?) -> some View {
        if let shortcut = binding?.keyboardShortcut {
            keyboardShortcut(shortcut)
        } else {
            self
        }
    }
}

struct RelayCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        // SwiftUI's Settings scene installs its own ⌘, on the standard menu
        // item. Replacing it keeps the shortcut editor honest: rebinding
        // "Settings" in the app has to actually change the shortcut.
        CommandGroup(replacing: .appSettings) {
            Button(RelayCommand.openSettings.title + "…") { openSettings() }
                .relayShortcut(model.binding(for: .openSettings))
        }

        CommandGroup(replacing: .newItem) {
            Button(RelayCommand.newShell.title) { newSession(.shell) }
                .relayShortcut(model.binding(for: .newShell))
            Button(RelayCommand.newClaude.title) { newSession(.claude) }
                .relayShortcut(model.binding(for: .newClaude))
            Button(RelayCommand.newCodex.title) { newSession(.codex) }
                .relayShortcut(model.binding(for: .newCodex))
            Divider()
            Button(RelayCommand.addProject.title) { model.isAddingProject = true }
                .relayShortcut(model.binding(for: .addProject))
        }

        // `⌘W` closes the session, so window closing moves aside rather than
        // fighting it.
        CommandGroup(replacing: .saveItem) {}

        CommandMenu("Session") {
            Button(RelayCommand.closeSession.title) {
                if let id = model.selectedSessionID { model.closeSession(id) }
            }
            .relayShortcut(model.binding(for: .closeSession))

            Button(RelayCommand.renameSession.title) { model.beginRenamingSelectedSession() }
                .relayShortcut(model.binding(for: .renameSession))

            Divider()

            Button(RelayCommand.nextSession.title) { model.selectAdjacentSession(offset: 1) }
                .relayShortcut(model.binding(for: .nextSession))
            Button(RelayCommand.previousSession.title) { model.selectAdjacentSession(offset: -1) }
                .relayShortcut(model.binding(for: .previousSession))
            Button(RelayCommand.focusTerminal.title) { model.focusTerminal() }
                .relayShortcut(model.binding(for: .focusTerminal))

            if model.shortcutSettings.indexShortcutsEnabled {
                Divider()
                ForEach(1 ... 9, id: \.self) { number in
                    Button("Session \(number)") { model.selectSession(atIndex: number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
            }
        }

        CommandMenu("Service") {
            Button(RelayCommand.startDefaultService.title) {
                if let projectID = model.selectedProjectID { model.startDefaultService(in: projectID) }
            }
            .relayShortcut(model.binding(for: .startDefaultService))

            Button(RelayCommand.restartDefaultService.title) {
                guard let projectID = model.selectedProjectID,
                      let service = model.project(projectID)?.defaultService else { return }
                model.restartService(service, in: projectID)
            }
            .relayShortcut(model.binding(for: .restartDefaultService))
        }

        CommandMenu("Project") {
            Button(RelayCommand.nextProject.title) { model.selectNextProject(offset: 1) }
                .relayShortcut(model.binding(for: .nextProject))
            Button(RelayCommand.previousProject.title) { model.selectNextProject(offset: -1) }
                .relayShortcut(model.binding(for: .previousProject))

            Divider()

            Button(RelayCommand.revealProject.title) {
                if let project = model.selectedProject { model.revealInFinder(project) }
            }
            .relayShortcut(model.binding(for: .revealProject))

            Button(RelayCommand.projectSettings.title) { model.isProjectSettingsOpen = true }
                .relayShortcut(model.binding(for: .projectSettings))

            if model.shortcutSettings.indexShortcutsEnabled {
                Divider()
                ForEach(1 ... 9, id: \.self) { number in
                    Button("Project \(number)") { model.selectProject(atIndex: number - 1) }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(number)")),
                            modifiers: [.command, .option]
                        )
                }
            }
        }

        CommandGroup(after: .toolbar) {
            Button(RelayCommand.commandPalette.title) { model.isCommandPaletteOpen.toggle() }
                .relayShortcut(model.binding(for: .commandPalette))
            // ⌘K is muscle memory from every other tool; keep it alongside ⌘P.
            Button("Command Palette (⌘K)") { model.isCommandPaletteOpen.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()

            Button(RelayCommand.togglePorts.title) { openWindow(id: PortsWindow.id) }
                .relayShortcut(model.binding(for: .togglePorts))

            Button(RelayCommand.openSSHHosts.title) { openWindow(id: SSHWindow.id) }
                .relayShortcut(model.binding(for: .openSSHHosts))

            Button(RelayCommand.toggleRightSidebar.title) { model.toggleRightSidebar() }
                .relayShortcut(model.binding(for: .toggleRightSidebar))
        }
    }

    private func newSession(_ kind: SessionKind) {
        guard let projectID = model.selectedProjectID else { return }
        model.createSession(
            from: SessionPresets.preferred(for: kind, custom: model.customPresets),
            in: projectID
        )
    }
}
