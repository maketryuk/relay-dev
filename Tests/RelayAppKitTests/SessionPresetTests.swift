import Foundation
import Testing

@testable import RelayAppKit
@testable import RelayProtocol

@Suite("Session presets")
struct SessionPresetTests {
    @Test("A preset's command is the kind's command plus its arguments")
    func commandComposition() {
        let preset = SessionPreset(name: "Claude", kind: .claude, arguments: ["--permission-mode", "auto"])
        #expect(preset.command == ["claude", "--permission-mode", "auto"])
    }

    @Test("A custom preset runs through a shell so quoting and pipes survive")
    func customCommandGoesThroughShell() {
        let preset = SessionPreset(name: "Build", kind: .custom, customCommand: "make build && make test")
        #expect(preset.command == ["/bin/sh", "-c", "make build && make test"])
    }

    @Test("The subtitle shows exactly what will run")
    @MainActor
    func subtitleShowsCommand() {
        #expect(SessionPreset(name: "Claude", kind: .claude).subtitle == "claude")
        #expect(
            SessionPreset(name: "Claude", kind: .claude, arguments: ["--permission-mode", "auto"]).subtitle
                == "claude --permission-mode auto"
        )
        #expect(SessionPreset(name: "X", kind: .custom, customCommand: "pnpm dev").subtitle == "pnpm dev")
    }

    @Test("Agents default to their own automatic-approval flag")
    func automaticModesUseTheRightFlag() {
        // Each CLI spells this differently, which is precisely why it belongs in
        // a preset rather than in the user's memory.
        #expect(SessionPresets.autoArguments(for: .claude) == ["--permission-mode", "auto"])
        #expect(SessionPresets.autoArguments(for: .codex) == ["--approve-for-me"])
        #expect(SessionPresets.autoArguments(for: .gemini) == ["--approval-mode", "auto_edit"])
    }

    @Test("The seeded set is short and puts agents in automatic mode")
    func defaultSetIsShort() {
        let defaults = SessionPresets.defaultSet
        #expect(defaults.map(\.kind) == [.shell, .claude, .codex])
        #expect(defaults[1].command == ["claude", "--permission-mode", "auto"])
        #expect(defaults[2].command == ["codex", "--approve-for-me"])
    }

    @Test("Only the plain terminal is undeletable")
    func onlyTerminalIsProtected() {
        // Every preset is editable; there simply has to remain a way to open a
        // shell.
        let defaults = SessionPresets.defaultSet
        #expect(defaults.filter(\.isProtected).map(\.kind) == [.shell])
    }

    @Test("Templates cover the agents that are not seeded")
    func templatesCoverTheRest() {
        let kinds = Set(SessionPresets.templates.map(\.kind))
        #expect(kinds.contains(.gemini))
        #expect(kinds.contains(.opencode))
        #expect(kinds.contains(.custom))
    }

    @Test("A shortcut picks the first preset for its kind")
    func preferredPreset() {
        let presets = SessionPresets.defaultSet
        #expect(SessionPresets.preferred(for: .claude, in: presets).id == "preset.claude")
        #expect(SessionPresets.preferred(for: .shell, in: presets).id == "preset.terminal")
        // A kind with no preset still yields something runnable.
        #expect(SessionPresets.preferred(for: .gemini, in: presets).command == ["gemini"])
    }

    @Test("Editing arguments round-trips through the text field")
    func argumentTextRoundTrips() {
        var preset = SessionPreset(name: "Claude", kind: .claude)
        preset.argumentText = "--permission-mode auto"
        #expect(preset.arguments == ["--permission-mode", "auto"])
        #expect(preset.argumentText == "--permission-mode auto")
    }

    @Test("A workspace from before presets were editable is migrated")
    func migratesLegacyWorkspace() {
        // Toggled-off built-ins stay off; custom presets are carried across.
        let custom = SessionPreset(name: "Storybook", kind: .custom, customCommand: "pnpm storybook")
        let migrated = SessionPresets.migrate(
            custom: [custom],
            enabledIDs: ["builtin.terminal", "builtin.claude.auto"]
        )
        #expect(migrated.map(\.name) == ["Terminal", "Claude", "Storybook"])
    }

    @Test("Migration without stored choices seeds the defaults")
    func migratesWithoutChoices() {
        let migrated = SessionPresets.migrate(custom: [], enabledIDs: nil)
        #expect(migrated.map(\.id) == SessionPresets.defaultSet.map(\.id))
    }

    @Test("Presets survive persistence; an older file is migrated on load")
    func presetsPersist() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        var preset = SessionPreset(name: "Storybook", kind: .custom, customCommand: "pnpm storybook")
        preset.id = "custom-1"
        WorkspaceStore(url: url).saveNow(WorkspaceState(presets: [preset]))
        #expect(WorkspaceStore(url: url).load().presets?.map(\.id) == ["custom-1"])

        try #"{"projects":[]}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(WorkspaceStore(url: url).load().presets == nil)
    }
}
