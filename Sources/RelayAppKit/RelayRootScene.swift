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
        // Before the model reads anything: an install written by a build that
        // kept its files in Application Support has to be found where this one
        // looks, and the first thing to look is the workspace store.
        RelayPaths.migrateFromLegacyLocation()
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
                    TrafficLightAligner.align(window, barHeight: Theme.Metrics.titleBarHeight)
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

    /// The one thing quitting does have to coordinate: Chromium's pages are
    /// in this process, unlike the terminals, and CEF has to be stopped before
    /// the process ends.
    func applicationWillTerminate(_ notification: Notification) {
        ChromiumEngine.shared.shutdown()
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
            Button(RelayCommand.addProject.localizedTitle) { model.toggleModal(.addProject) }
                .relayShortcut(model.binding(for: .addProject))
        }

        // `⌘W` closes the session, so window closing moves aside rather than
        // fighting it. Saving belongs here, where every Mac application puts
        // it — even though the editor also writes the file when the pane loses
        // focus and when it closes, because a person who presses ⌘S and sees
        // nothing happen does not conclude that it was already saved.
        CommandGroup(replacing: .saveItem) {
            Button(relayLocalized("Save")) { model.saveFocusedFile() }
                .keyboardShortcut("s", modifiers: .command)
        }

        CommandMenu(relayLocalized("Editor")) {
            Button(RelayCommand.findInFile.localizedTitle) { model.findInFocusedFile() }
                .relayShortcut(model.binding(for: .findInFile))

            Button(RelayCommand.searchProject.localizedTitle) {
                if let projectID = model.selectedProjectID { model.presentModal(.search(projectID)) }
            }
            .relayShortcut(model.binding(for: .searchProject))

            Button(RelayCommand.toggleMarkdownPreview.localizedTitle) { model.toggleMarkdownPreview() }
                .relayShortcut(model.binding(for: .toggleMarkdownPreview))
                .disabled(!model.isMarkdownFocused)

            Divider()

            Button(RelayCommand.goToDefinition.localizedTitle) { model.goToDefinitionFromCaret() }
                .relayShortcut(model.binding(for: .goToDefinition))
                .disabled(model.editors.focused == nil)
            Button(RelayCommand.goBack.localizedTitle) { model.goBackToOrigin() }
                .relayShortcut(model.binding(for: .goBack))
                .disabled(!model.canGoBackToOrigin)
        }

        CommandMenu(relayLocalized("Session")) {
            Button(RelayCommand.closeSession.localizedTitle) { model.closeFocusedPane() }
                .relayShortcut(model.binding(for: .closeSession))

            Button(RelayCommand.reopenSession.localizedTitle) {
                model.reopenLastClosedSession()
            }
            .relayShortcut(model.binding(for: .reopenSession))

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

            // Nine items nobody reads, hidden because they are not for reading:
            // SwiftUI can only attach a shortcut to a menu item, so ⌘1…⌘9 has
            // to be carried by one each. On screen they filled the menu with
            // "Session 4" and said nothing the numbers on the sidebar rows do
            // not. Settings names the shortcut instead.
            if model.shortcutSettings.indexShortcutsEnabled {
                ForEach(1 ... 9, id: \.self) { number in
                    Button { model.selectSession(atIndex: number - 1) } label: { Text(verbatim: "Session \(number)") }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                        .hidden()
                }
            }
        }

        CommandMenu(relayLocalized("Browser")) {
            Button(RelayCommand.newBrowserTab.localizedTitle) {
                if let projectID = model.selectedProjectID { model.newBrowserTab(in: projectID) }
            }
            .relayShortcut(model.binding(for: .newBrowserTab))
            .disabled(model.selectedProjectID == nil)

            Button(RelayCommand.toggleDesignMode.localizedTitle) { model.toggleDesignMode() }
                .relayShortcut(model.binding(for: .toggleDesignMode))
                .disabled(model.selectedProjectID == nil)

            Divider()

            Button(RelayCommand.reloadBrowser.localizedTitle) { model.activeBrowserPage?.reload() }
                .relayShortcut(model.binding(for: .reloadBrowser))
                .disabled(model.activeBrowserPage == nil)

            Button(RelayCommand.openBrowserDevTools.localizedTitle) { model.activeBrowserPage?.showDevTools() }
                .relayShortcut(model.binding(for: .openBrowserDevTools))
                .disabled(model.activeBrowserPage == nil)
        }

        CommandMenu(relayLocalized("Service")) {
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

        CommandMenu(relayLocalized("Project")) {
            Button(RelayCommand.nextProject.localizedTitle) { model.selectNextProject(offset: 1) }
                .relayShortcut(model.binding(for: .nextProject))
            Button(RelayCommand.previousProject.localizedTitle) { model.selectNextProject(offset: -1) }
                .relayShortcut(model.binding(for: .previousProject))

            Divider()

            Button(RelayCommand.revealProject.localizedTitle) {
                if let project = model.selectedProject { model.revealInFinder(project) }
            }
            .relayShortcut(model.binding(for: .revealProject))

            Button(RelayCommand.reviewChanges.localizedTitle) {
                if let projectID = model.selectedProjectID { model.reviewChanges(in: projectID) }
            }
            .relayShortcut(model.binding(for: .reviewChanges))

            Button(RelayCommand.switchBranch.localizedTitle) {
                if let projectID = model.selectedProjectID { model.pickBranch(in: projectID) }
            }
            .relayShortcut(model.binding(for: .switchBranch))

            Button(RelayCommand.newWorktree.localizedTitle + "…") {
                if let projectID = model.selectedProjectID { model.beginNewWorktree(in: projectID) }
            }
            .relayShortcut(model.binding(for: .newWorktree))
            .disabled(!(model.selectedProjectID.map(model.gitRepositories.contains) ?? false))

            Button(RelayCommand.cleanUpWorktrees.localizedTitle + "…") {
                if let projectID = model.selectedProjectID { model.beginWorktreeCleanup(in: projectID) }
            }
            .relayShortcut(model.binding(for: .cleanUpWorktrees))
            .disabled(!(model.selectedProjectID.map(model.offersWorktreeCleanup) ?? false))

            Button(RelayCommand.projectSettings.localizedTitle) { model.openProjectSettings() }
                .relayShortcut(model.binding(for: .projectSettings))

            if model.shortcutSettings.indexShortcutsEnabled {
                ForEach(1 ... 9, id: \.self) { number in
                    Button { model.selectProject(atIndex: number - 1) } label: { Text(verbatim: "Project \(number)") }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(number)")),
                            modifiers: [.command, .option]
                        )
                        .hidden()
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

            Divider()

            Button(RelayCommand.increaseTerminalFontSize.localizedTitle) { model.stepFontSize(by: 1) }
                .relayShortcut(model.binding(for: .increaseTerminalFontSize))
            // `⌘+` is `⌘=` with the Shift held, and which of the two a person
            // presses is not something they think about. The menu shows the one
            // it is called by; this one is here so the other also arrives.
            Button(relayLocalized("Increase Font Size (⌘=)")) { model.stepFontSize(by: 1) }
                .keyboardShortcut("=", modifiers: .command)
                .hidden()
            Button(RelayCommand.decreaseTerminalFontSize.localizedTitle) { model.stepFontSize(by: -1) }
                .relayShortcut(model.binding(for: .decreaseTerminalFontSize))
            Button(RelayCommand.resetTerminalFontSize.localizedTitle) { model.resetFontSize() }
                .relayShortcut(model.binding(for: .resetTerminalFontSize))
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
