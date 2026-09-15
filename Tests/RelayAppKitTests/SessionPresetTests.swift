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
        let byID = Dictionary(uniqueKeysWithValues: SessionPresets.builtIn.map { ($0.id, $0) })
        #expect(byID["builtin.claude.auto"]?.command == ["claude", "--permission-mode", "auto"])
        #expect(byID["builtin.codex.auto"]?.command == ["codex", "--approve-for-me"])
        #expect(byID["builtin.gemini.auto"]?.command == ["gemini", "--approval-mode", "auto_edit"])
    }

    @Test("A supervised variant is offered next to every automatic agent")
    func supervisedVariantsExist() {
        let byID = Dictionary(uniqueKeysWithValues: SessionPresets.builtIn.map { ($0.id, $0) })
        #expect(byID["builtin.claude"]?.command == ["claude"])
        #expect(byID["builtin.codex"]?.command == ["codex"])
    }

    @Test("A plain terminal preset runs the login shell")
    func terminalPreset() {
        let terminal = SessionPresets.builtIn.first { $0.kind == .shell }
        #expect(terminal?.name == "Terminal")
        #expect(terminal?.command.isEmpty == true)
    }

    @Test("Built-in presets have stable identifiers so they can be referenced")
    func stableIdentifiers() {
        let ids = SessionPresets.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("builtin.") })
        #expect(SessionPresets.builtIn.allSatisfy { $0.isBuiltIn })
    }

    @Test("A shortcut for a kind launches its automatic variant")
    func preferredPresetIsTheAutomaticOne() {
        #expect(SessionPresets.preferred(for: .claude).id == "builtin.claude.auto")
        #expect(SessionPresets.preferred(for: .codex).id == "builtin.codex.auto")
        #expect(SessionPresets.preferred(for: .shell).id == "builtin.terminal")
    }

    @Test("Out of the box the menu offers only the three most-used presets")
    func defaultMenuIsShort() {
        // A menu listing every agent anyone might use is a menu nobody reads.
        let offered = SessionPresets.enabled(custom: [], enabledIDs: nil)
        #expect(offered.map(\.id) == ["builtin.terminal", "builtin.claude.auto", "builtin.codex.auto"])
    }

    @Test("Enabling a preset adds it to the menu in catalogue order")
    func enablingKeepsOrder() {
        let offered = SessionPresets.enabled(
            custom: [],
            enabledIDs: ["builtin.gemini.auto", "builtin.terminal"]
        )
        #expect(offered.map(\.id) == ["builtin.terminal", "builtin.gemini.auto"])
    }

    @Test("A preset the user created is always offered")
    func customPresetsAreAlwaysOffered() {
        // Hiding one would mean it could only be reached from settings, which is
        // not where you start a session.
        let custom = SessionPreset(name: "Storybook", kind: .custom, customCommand: "pnpm storybook")
        let offered = SessionPresets.enabled(custom: [custom], enabledIDs: ["builtin.terminal"])
        #expect(offered.map(\.id) == ["builtin.terminal", custom.id])
    }

    @Test("The catalogue keeps everything, offered or not")
    func catalogueIsComplete() {
        let custom = SessionPreset(name: "X", kind: .custom, customCommand: "x")
        #expect(SessionPresets.catalogue(custom: [custom]).count == SessionPresets.builtIn.count + 1)
    }

    @Test("A shortcut still works for an agent hidden from the menu")
    func shortcutFallsBackToTheCatalogue() {
        let preferred = SessionPresets.preferred(for: .gemini, enabledIDs: ["builtin.terminal"])
        #expect(preferred.id == "builtin.gemini.auto")
    }

    @Test("Enabled presets survive persistence; nil means the defaults")
    func enabledPresetsPersist() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        WorkspaceStore(url: url).saveNow(WorkspaceState(enabledPresetIDs: ["builtin.terminal"]))
        #expect(WorkspaceStore(url: url).load().enabledPresetIDs == ["builtin.terminal"])

        try #"{"projects":[]}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(WorkspaceStore(url: url).load().enabledPresetIDs == nil)
    }

    @Test("A kind with no preset still yields something runnable")
    func preferredFallsBack() {
        let preset = SessionPresets.preferred(for: .ssh)
        #expect(preset.kind == .ssh)
        #expect(preset.command == ["ssh"])
    }

    @Test("Custom presets are listed after the built-ins")
    func customPresetsAppended() {
        let custom = SessionPreset(name: "Storybook", kind: .custom, customCommand: "pnpm storybook")
        let all = SessionPresets.all(custom: [custom])
        #expect(all.count == SessionPresets.builtIn.count + 1)
        #expect(all.last?.id == custom.id)
    }

    @Test("Custom presets survive persistence; built-ins are not stored")
    func customPresetsPersist() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        let custom = SessionPreset(name: "Storybook", kind: .custom, customCommand: "pnpm storybook")
        WorkspaceStore(url: url).saveNow(WorkspaceState(customPresets: [custom]))

        let loaded = WorkspaceStore(url: url).load()
        #expect(loaded.customPresets.count == 1)
        #expect(loaded.customPresets[0].customCommand == "pnpm storybook")
        // Built-ins live in code so improvements reach existing users.
        #expect(!loaded.customPresets.contains { $0.isBuiltIn })
    }

    @Test("A workspace written before presets existed still loads")
    func decodesWorkspaceWithoutPresets() throws {
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        try #"{"projects":[]}"#.write(to: url, atomically: true, encoding: .utf8)
        #expect(WorkspaceStore(url: url).load().customPresets.isEmpty)
    }

    @Test("Preset names are numbered like any other session name")
    func presetNamesFollowNumbering() {
        let preset = SessionPresets.preferred(for: .claude)
        #expect(SessionNaming.nextName(base: preset.name, existing: []) == "Claude")
        #expect(SessionNaming.nextName(base: preset.name, existing: ["Claude"]) == "Claude 2")
    }
}
