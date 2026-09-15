import Foundation
import Testing

@testable import RelayAppKit
@testable import RelayProtocol

@Suite("Key bindings")
struct KeyBindingTests {
    @Test("Modifier glyphs follow Apple's order regardless of how they were given")
    func modifierOrder() {
        let binding = KeyBinding("k", [.command, .control, .shift, .option])
        #expect(binding.displayString == "⌃⌥⇧⌘K")
    }

    @Test("Letters are shown uppercase, named keys as their glyph")
    func displayForms() {
        #expect(KeyBinding("t", .command).displayString == "⌘T")
        #expect(KeyBinding("return", .command).displayString == "⌘↩")
        #expect(KeyBinding("escape", []).displayString == "⎋")
        #expect(KeyBinding("up", [.command, .option]).displayString == "⌥⌘↑")
        #expect(KeyBinding("[", [.command, .shift]).displayString == "⇧⌘[")
    }

    @Test("Keys are stored case-insensitively")
    func keyIsNormalised() {
        #expect(KeyBinding("T", .command) == KeyBinding("t", .command))
    }

    @Test("A binding without a real modifier would swallow typing")
    func rejectsUnusableBindings() {
        // The terminal must keep receiving ordinary keystrokes.
        #expect(!KeyBinding("t", []).isUsable)
        #expect(!KeyBinding("t", .shift).isUsable)
        #expect(KeyBinding("t", .command).isUsable)
        #expect(KeyBinding("t", .control).isUsable)
        #expect(KeyBinding("t", [.shift, .command]).isUsable)
    }

    @Test("Named keys map onto SwiftUI equivalents")
    func keyEquivalents() {
        #expect(KeyBinding("return", .command).keyEquivalent != nil)
        #expect(KeyBinding("up", .command).keyEquivalent != nil)
        #expect(KeyBinding("t", .command).keyEquivalent != nil)
        // An unknown multi-character name cannot be represented.
        #expect(KeyBinding("f13", .command).keyEquivalent == nil)
        #expect(!KeyBinding("f13", .command).isUsable)
    }

    @Test("Bindings survive persistence")
    func codableRoundTrip() throws {
        let binding = KeyBinding("]", [.command, .shift])
        let data = try JSONEncoder().encode(binding)
        #expect(try JSONDecoder().decode(KeyBinding.self, from: data) == binding)
    }
}

@Suite("Command registry")
struct RelayCommandTests {
    @Test("Every command has a title and a category")
    func metadataIsComplete() {
        for command in RelayCommand.allCases {
            #expect(!command.title.isEmpty)
            #expect(ShortcutCategory.allCases.contains(command.category))
        }
    }

    @Test("Default bindings are all actually usable")
    func defaultsAreUsable() {
        for command in RelayCommand.allCases {
            guard let binding = command.defaultBinding else { continue }
            #expect(binding.isUsable, "\(command.rawValue) has an unusable default")
        }
    }

    @Test("No two commands ship with the same default")
    func defaultsDoNotCollide() {
        let conflicts = ShortcutResolver.conflicts(settings: ShortcutSettings())
        #expect(conflicts.isEmpty, "colliding defaults: \(conflicts)")
    }

    @Test("The shortcuts the user asked for are the defaults")
    func requestedDefaults() {
        #expect(RelayCommand.newShell.defaultBinding == KeyBinding("t", .command))
        #expect(RelayCommand.closeSession.defaultBinding == KeyBinding("w", .command))
        #expect(RelayCommand.commandPalette.defaultBinding == KeyBinding("p", .command))
    }
}

@Suite("Shortcut resolution")
struct ShortcutResolverTests {
    @Test("With no changes, every command uses its default")
    func defaultsApply() {
        let settings = ShortcutSettings()
        for command in RelayCommand.allCases {
            #expect(ShortcutResolver.binding(for: command, settings: settings) == command.defaultBinding)
            #expect(!ShortcutResolver.isCustomised(command, settings: settings))
        }
    }

    @Test("An override replaces the default")
    func overrideApplies() {
        let settings = ShortcutResolver.rebind(.newShell, to: KeyBinding("n", .control), in: ShortcutSettings())
        #expect(ShortcutResolver.binding(for: .newShell, settings: settings) == KeyBinding("n", .control))
        #expect(ShortcutResolver.isCustomised(.newShell, settings: settings))
    }

    @Test("Rebinding back to the default stops storing an override")
    func returningToDefaultClearsOverride() {
        // Otherwise a user who experimented once would be frozen on today's
        // default forever.
        var settings = ShortcutResolver.rebind(.newShell, to: KeyBinding("n", .control), in: ShortcutSettings())
        settings = ShortcutResolver.rebind(.newShell, to: RelayCommand.newShell.defaultBinding, in: settings)
        #expect(settings.overrides.isEmpty)
        #expect(!ShortcutResolver.isCustomised(.newShell, settings: settings))
    }

    @Test("Unbinding is remembered and is not the same as never changing it")
    func unbinding() {
        let settings = ShortcutResolver.rebind(.newShell, to: nil, in: ShortcutSettings())
        #expect(ShortcutResolver.binding(for: .newShell, settings: settings) == nil)
        #expect(ShortcutResolver.isCustomised(.newShell, settings: settings))
    }

    @Test("Resetting restores the default")
    func resetting() {
        var settings = ShortcutResolver.rebind(.newShell, to: nil, in: ShortcutSettings())
        settings = ShortcutResolver.reset(.newShell, in: settings)
        #expect(ShortcutResolver.binding(for: .newShell, settings: settings) == RelayCommand.newShell.defaultBinding)
        #expect(settings.unbound.isEmpty)
    }

    @Test("Rebinding an unbound command binds it again")
    func rebindingAfterUnbinding() {
        var settings = ShortcutResolver.rebind(.newShell, to: nil, in: ShortcutSettings())
        settings = ShortcutResolver.rebind(.newShell, to: KeyBinding("j", .command), in: settings)
        #expect(settings.unbound.isEmpty)
        #expect(ShortcutResolver.binding(for: .newShell, settings: settings) == KeyBinding("j", .command))
    }

    @Test("A clash is reported rather than silently refused")
    func conflictsAreDetected() {
        let settings = ShortcutResolver.rebind(.newShell, to: KeyBinding("p", .command), in: ShortcutSettings())
        let conflicts = ShortcutResolver.conflicts(settings: settings)
        #expect(conflicts[KeyBinding("p", .command)]?.contains(.newShell) == true)
        #expect(conflicts[KeyBinding("p", .command)]?.contains(.commandPalette) == true)
    }

    @Test("The recorder can ask what a keystroke would collide with")
    func conflictLookupForOneCommand() {
        let settings = ShortcutSettings()
        let clashes = ShortcutResolver.conflictingCommands(
            with: KeyBinding("t", .command),
            excluding: .newClaude,
            settings: settings
        )
        #expect(clashes == [.newShell])
        // A command never conflicts with itself.
        #expect(
            ShortcutResolver.conflictingCommands(
                with: KeyBinding("t", .command),
                excluding: .newShell,
                settings: settings
            ).isEmpty
        )
    }

    @Test("Settings survive persistence, defaulting for older files")
    func settingsPersist() throws {
        let settings = ShortcutResolver.rebind(.newShell, to: KeyBinding("j", .command), in: ShortcutSettings())
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ShortcutSettings.self, from: data)
        #expect(decoded == settings)

        let legacy = try JSONDecoder().decode(ShortcutSettings.self, from: Data("{}".utf8))
        #expect(legacy.overrides.isEmpty)
        #expect(legacy.indexShortcutsEnabled)
    }
}

@Suite("Session display names")
struct SessionDisplayNameTests {
    private func snapshot(
        name: String,
        title: String? = nil,
        isNameUserDefined: Bool = false
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: .generate(),
            projectID: .generate(),
            kind: .claude,
            name: name,
            workingDirectory: "/tmp",
            command: ["claude"],
            status: .working,
            pid: 1,
            exitCode: nil,
            startedAt: Date(),
            lastActivityAt: Date(),
            columns: 80,
            rows: 24,
            title: title,
            isNameUserDefined: isNameUserDefined
        )
    }

    @Test("Without a reported title the assigned name is used")
    func fallsBackToAssignedName() {
        #expect(snapshot(name: "Claude").displayName == "Claude")
    }

    @Test("A title reported by the program replaces the default name")
    func titleWinsOverDefault() {
        // This is how an agent names its own session: it sets the terminal
        // title, and Relay listens rather than guessing.
        #expect(snapshot(name: "Claude", title: "fix failing tests").displayName == "fix failing tests")
    }

    @Test("A name the user chose is never overridden by a title")
    func userNameWins() {
        let session = snapshot(name: "auth work", title: "some other title", isNameUserDefined: true)
        #expect(session.displayName == "auth work")
    }

    @Test("An empty title does not blank the name")
    func emptyTitleIgnored() {
        #expect(snapshot(name: "Claude", title: "").displayName == "Claude")
    }

    @Test("A plain terminal is called Terminal")
    func shellIsCalledTerminal() {
        #expect(SessionKind.shell.displayName == "Terminal")
        #expect(SessionNaming.nextName(for: .shell, existing: []) == "Terminal")
    }
}
