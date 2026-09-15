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
                    window.titlebarAppearsTransparent = true
                    window.collectionBehavior.insert(.fullScreenPrimary)
                    // Relay drags the window itself, from regions it knows are
                    // empty. AppKit would otherwise drag from anywhere in the
                    // title bar strip, buttons included.
                    window.isMovable = false
                    window.isMovableByWindowBackground = false
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1240, height: 760)
        .commands { RelayCommands(model: model) }
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

    var body: some Commands {
        // SwiftUI's Settings scene installs its own ⌘, on the standard menu
        // item. Replacing it keeps the shortcut editor honest: rebinding
        // "Settings" in the app has to actually change the shortcut.
        CommandGroup(replacing: .appSettings) {
            Button(RelayCommand.openSettings.localizedTitle + "…") { model.toggleModal(.settings) }
                .relayShortcut(model.binding(for: .openSettings))
        }

        CommandGroup(replacing: .newItem) {
            Button(RelayCommand.newShell.localizedTitle) { newSession(.shell) }
                .relayShortcut(model.binding(for: .newShell))
            Button(RelayCommand.newClaude.localizedTitle) { newSession(.claude) }
                .relayShortcut(model.binding(for: .newClaude))
            Button(RelayCommand.newCodex.localizedTitle) { newSession(.codex) }
                .relayShortcut(model.binding(for: .newCodex))
            Divider()
            Button(RelayCommand.addProject.localizedTitle) { model.isAddingProject = true }
                .relayShortcut(model.binding(for: .addProject))
        }

        // `⌘W` closes the session, so window closing moves aside rather than
        // fighting it.
        CommandGroup(replacing: .saveItem) {}

        CommandMenu("Session") {
            Button(RelayCommand.closeSession.localizedTitle) {
                if let id = model.selectedSessionID { model.closeSession(id) }
            }
            .relayShortcut(model.binding(for: .closeSession))

            Button(RelayCommand.renameSession.localizedTitle) { model.beginRenamingSelectedSession() }
                .relayShortcut(model.binding(for: .renameSession))

            Divider()

            Button(RelayCommand.nextSession.localizedTitle) { model.selectAdjacentSession(offset: 1) }
                .relayShortcut(model.binding(for: .nextSession))
            Button(RelayCommand.previousSession.localizedTitle) { model.selectAdjacentSession(offset: -1) }
                .relayShortcut(model.binding(for: .previousSession))
            Button(RelayCommand.focusTerminal.localizedTitle) { model.focusTerminal() }
                .relayShortcut(model.binding(for: .focusTerminal))

            Divider()

            Button(RelayCommand.splitRight.localizedTitle) { model.splitFocusedPane(axis: .horizontal) }
                .relayShortcut(model.binding(for: .splitRight))
            Button(RelayCommand.splitDown.localizedTitle) { model.splitFocusedPane(axis: .vertical) }
                .relayShortcut(model.binding(for: .splitDown))
            Button(RelayCommand.focusNextPane.localizedTitle) { model.focusNextPane() }
                .relayShortcut(model.binding(for: .focusNextPane))

            if model.shortcutSettings.indexShortcutsEnabled {
                Divider()
                ForEach(1 ... 9, id: \.self) { number in
                    Button("Session \(number)") { model.selectSession(atIndex: number - 1) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
            }
        }

        CommandMenu("Service") {
            Button(RelayCommand.startDefaultService.localizedTitle) {
                if let projectID = model.selectedProjectID { model.startDefaultService(in: projectID) }
            }
            .relayShortcut(model.binding(for: .startDefaultService))

            Button(RelayCommand.restartDefaultService.localizedTitle) {
                guard let projectID = model.selectedProjectID,
                      let service = model.project(projectID)?.defaultService else { return }
                model.restartService(service, in: projectID)
            }
            .relayShortcut(model.binding(for: .restartDefaultService))
        }

        CommandMenu("Project") {
            Button(RelayCommand.nextProject.localizedTitle) { model.selectNextProject(offset: 1) }
                .relayShortcut(model.binding(for: .nextProject))
            Button(RelayCommand.previousProject.localizedTitle) { model.selectNextProject(offset: -1) }
                .relayShortcut(model.binding(for: .previousProject))

            Divider()

            Button(RelayCommand.revealProject.localizedTitle) {
                if let project = model.selectedProject { model.revealInFinder(project) }
            }
            .relayShortcut(model.binding(for: .revealProject))

            Button(RelayCommand.projectSettings.localizedTitle) { model.isProjectSettingsOpen = true }
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
            Button(RelayCommand.commandPalette.localizedTitle) { model.isCommandPaletteOpen.toggle() }
                .relayShortcut(model.binding(for: .commandPalette))
            // ⌘K is muscle memory from every other tool; keep it alongside ⌘P.
            Button(relayLocalized("Command Palette (⌘K)")) { model.isCommandPaletteOpen.toggle() }
                .keyboardShortcut("k", modifiers: .command)
                .hidden()

            Button(RelayCommand.togglePorts.localizedTitle) { model.toggleModal(.ports) }
                .relayShortcut(model.binding(for: .togglePorts))

            Button(RelayCommand.openSSHHosts.localizedTitle) { model.toggleModal(.sshHosts) }
                .relayShortcut(model.binding(for: .openSSHHosts))

            Button(RelayCommand.toggleRightSidebar.localizedTitle) { model.toggleRightSidebar() }
                .relayShortcut(model.binding(for: .toggleRightSidebar))
        }
    }


    private func newSession(_ kind: SessionKind) {
        guard let projectID = model.selectedProjectID else { return }
        model.createSession(
            from: SessionPresets.preferred(for: kind, in: model.presets),
            in: projectID
        )
    }
}
