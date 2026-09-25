import Foundation
import RelayProtocol

/// A one-click way to start a session: a name, an agent, and the arguments it
/// should run with.
///
/// Presets exist because "start Claude" is not one action. Starting it with
/// approvals on and starting it in automatic mode are different enough to
/// deserve separate rows, and each CLI spells its automatic mode differently —
/// exactly the sort of thing nobody should be typing from memory.
///
/// Every preset is editable. The defaults are seeded into the user's list on
/// first run rather than living in code as an untouchable catalogue: a set of
/// starting points someone cannot rename or adjust is not a set of presets.
struct SessionPreset: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: SessionKind
    /// Appended to the kind's own command.
    var arguments: [String]
    /// Overrides the whole command.
    var customCommand: String?
    /// There has to be a way to open a plain terminal, so that one preset
    /// cannot be deleted. It can still be renamed and adjusted.
    var isProtected: Bool

    init(
        id: String = UUID().uuidString,
        name: String,
        kind: SessionKind,
        arguments: [String] = [],
        customCommand: String? = nil,
        isProtected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.arguments = arguments
        self.customCommand = customCommand
        self.isProtected = isProtected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .custom
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        customCommand = try container.decodeIfPresent(String.self, forKey: .customCommand)
        isProtected = try container.decodeIfPresent(Bool.self, forKey: .isProtected) ?? false
    }

    /// The argv handed to the daemon.
    var command: [String] {
        if let customCommand, !customCommand.isEmpty {
            return ["/bin/sh", "-c", customCommand]
        }
        return kind.defaultCommand + arguments
    }

    /// Shown under the name, so it is never a mystery what a preset will run.
    var subtitle: String {
        if let customCommand, !customCommand.isEmpty { return customCommand }
        let text = command.joined(separator: " ")
        return text.isEmpty ? "login shell" : text
    }

    /// Arguments as the user would type them, for the editor.
    var argumentText: String {
        get { arguments.joined(separator: " ") }
        set { arguments = newValue.split(whereSeparator: { $0 == " " }).map(String.init) }
    }
}

enum SessionPresets {
    /// Seeded on first run. Deliberately short: a menu listing every agent
    /// anyone might use is a menu nobody reads, and the rest are one click away
    /// in settings.
    static var defaultSet: [SessionPreset] {
        [
            SessionPreset(
                id: "preset.terminal",
                name: "Terminal",
                kind: .shell,
                isProtected: true
            ),
            SessionPreset(id: "preset.claude", name: "Claude", kind: .claude, arguments: autoArguments(for: .claude)),
            SessionPreset(id: "preset.codex", name: "Codex", kind: .codex, arguments: autoArguments(for: .codex)),
        ]
    }

    /// Each CLI's automatic-approval flag. They differ, and getting one wrong
    /// silently gives an agent either no autonomy or too much.
    static func autoArguments(for kind: SessionKind) -> [String] {
        switch kind {
        case .claude: ["--permission-mode", "auto"]
        case .codex: ["--approve-for-me"]
        case .gemini: ["--approval-mode", "auto_edit"]
        case .opencode, .shell, .ssh, .custom: []
        }
    }

    /// Offered when adding a preset, so the common ones need no typing.
    static var templates: [SessionPreset] {
        [
            SessionPreset(name: "Claude", kind: .claude, arguments: autoArguments(for: .claude)),
            SessionPreset(name: "Claude · ask first", kind: .claude),
            SessionPreset(name: "Codex", kind: .codex, arguments: autoArguments(for: .codex)),
            SessionPreset(name: "Codex · ask first", kind: .codex),
            SessionPreset(name: "Gemini", kind: .gemini, arguments: autoArguments(for: .gemini)),
            SessionPreset(name: "OpenCode", kind: .opencode),
            SessionPreset(name: "Terminal", kind: .shell),
            SessionPreset(name: "Custom command", kind: .custom, customCommand: ""),
        ]
    }

    /// The names Relay gives presets, as opposed to the ones people type.
    static var suppliedNames: [String] {
        (defaultSet + templates).map(\.name)
    }

    /// What a keyboard shortcut for a kind should launch.
    static func preferred(for kind: SessionKind, in presets: [SessionPreset]) -> SessionPreset {
        presets.first { $0.kind == kind } ?? SessionPreset(name: kind.displayName, kind: kind)
    }

    /// Migrates a workspace written before presets were editable.
    static func migrate(custom: [SessionPreset], enabledIDs: [String]?) -> [SessionPreset] {
        let legacyDefaults: [String: String] = [
            "builtin.terminal": "preset.terminal",
            "builtin.claude.auto": "preset.claude",
            "builtin.codex.auto": "preset.codex",
        ]
        let enabled = Set(enabledIDs ?? Array(legacyDefaults.keys))
        var result = defaultSet.filter { preset in
            guard let legacy = legacyDefaults.first(where: { $0.value == preset.id })?.key else { return true }
            return enabled.contains(legacy) || preset.isProtected
        }
        result.append(contentsOf: custom)
        return result
    }
}
