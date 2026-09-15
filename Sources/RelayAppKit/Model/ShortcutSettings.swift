import Foundation

/// User changes to the default key map.
///
/// Only differences are stored, so a later change to a default reaches users who
/// never touched that command.
struct ShortcutSettings: Codable, Hashable, Sendable {
    var overrides: [String: KeyBinding]
    /// Commands the user deliberately unbound, which is different from never
    /// having changed them.
    var unbound: [String]
    /// `⌘1…⌘9` for sessions and `⌥⌘1…⌥⌘9` for projects.
    var indexShortcutsEnabled: Bool

    init(
        overrides: [String: KeyBinding] = [:],
        unbound: [String] = [],
        indexShortcutsEnabled: Bool = true
    ) {
        self.overrides = overrides
        self.unbound = unbound
        self.indexShortcutsEnabled = indexShortcutsEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overrides = try container.decodeIfPresent([String: KeyBinding].self, forKey: .overrides) ?? [:]
        unbound = try container.decodeIfPresent([String].self, forKey: .unbound) ?? []
        indexShortcutsEnabled = try container.decodeIfPresent(Bool.self, forKey: .indexShortcutsEnabled) ?? true
    }
}

/// Resolves commands to the keystroke that currently triggers them.
enum ShortcutResolver {
    static func binding(for command: RelayCommand, settings: ShortcutSettings) -> KeyBinding? {
        if settings.unbound.contains(command.rawValue) { return nil }
        return settings.overrides[command.rawValue] ?? command.defaultBinding
    }

    static func allBindings(settings: ShortcutSettings) -> [RelayCommand: KeyBinding] {
        var result: [RelayCommand: KeyBinding] = [:]
        for command in RelayCommand.allCases {
            result[command] = binding(for: command, settings: settings)
        }
        return result
    }

    /// Commands that would fire on the same keystroke.
    ///
    /// Conflicts are surfaced rather than prevented: silently refusing a binding
    /// the user asked for is worse than showing them what it collides with.
    static func conflicts(settings: ShortcutSettings) -> [KeyBinding: [RelayCommand]] {
        var byBinding: [KeyBinding: [RelayCommand]] = [:]
        for (command, binding) in allBindings(settings: settings) {
            byBinding[binding, default: []].append(command)
        }
        return byBinding
            .filter { $0.value.count > 1 }
            .mapValues { $0.sorted { $0.rawValue < $1.rawValue } }
    }

    static func conflictingCommands(
        with binding: KeyBinding,
        excluding command: RelayCommand,
        settings: ShortcutSettings
    ) -> [RelayCommand] {
        allBindings(settings: settings)
            .filter { $0.key != command && $0.value == binding }
            .keys
            .sorted { $0.rawValue < $1.rawValue }
    }

    static func rebind(
        _ command: RelayCommand,
        to binding: KeyBinding?,
        in settings: ShortcutSettings
    ) -> ShortcutSettings {
        var updated = settings
        updated.unbound.removeAll { $0 == command.rawValue }

        guard let binding else {
            updated.overrides.removeValue(forKey: command.rawValue)
            updated.unbound.append(command.rawValue)
            return updated
        }

        if binding == command.defaultBinding {
            // Back to the default: stop storing an override so future default
            // changes still reach this user.
            updated.overrides.removeValue(forKey: command.rawValue)
        } else {
            updated.overrides[command.rawValue] = binding
        }
        return updated
    }

    static func reset(_ command: RelayCommand, in settings: ShortcutSettings) -> ShortcutSettings {
        var updated = settings
        updated.overrides.removeValue(forKey: command.rawValue)
        updated.unbound.removeAll { $0 == command.rawValue }
        return updated
    }

    static func isCustomised(_ command: RelayCommand, settings: ShortcutSettings) -> Bool {
        settings.overrides[command.rawValue] != nil || settings.unbound.contains(command.rawValue)
    }
}
