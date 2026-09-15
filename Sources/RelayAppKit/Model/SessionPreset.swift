import Foundation
import RelayProtocol

/// A one-click way to start a session: a name, an agent, and the arguments it
/// should run with.
///
/// Presets exist because "start Claude" is not one action. Starting it with
/// approvals on and starting it in automatic mode are different enough to
/// deserve separate rows, and burying that behind a settings toggle would mean
/// the user cannot have both.
struct SessionPreset: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var kind: SessionKind
    /// Appended to the kind's own command.
    var arguments: [String]
    /// Built-ins live in code so improvements reach everyone; only user presets
    /// are persisted.
    var isBuiltIn: Bool
    /// Overrides the whole command for a custom preset.
    var customCommand: String?

    init(
        id: String = UUID().uuidString,
        name: String,
        kind: SessionKind,
        arguments: [String] = [],
        isBuiltIn: Bool = false,
        customCommand: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.arguments = arguments
        self.isBuiltIn = isBuiltIn
        self.customCommand = customCommand
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        kind = try container.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .custom
        arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
        isBuiltIn = try container.decodeIfPresent(Bool.self, forKey: .isBuiltIn) ?? false
        customCommand = try container.decodeIfPresent(String.self, forKey: .customCommand)
    }

    /// The argv handed to the daemon.
    var command: [String] {
        if let customCommand, !customCommand.isEmpty {
            return ["/bin/sh", "-c", customCommand]
        }
        return kind.defaultCommand + arguments
    }

    /// Shown under the name in the menu, so it is never a mystery what a preset
    /// will actually run.
    var subtitle: String {
        if let customCommand, !customCommand.isEmpty { return customCommand }
        return command.joined(separator: " ")
    }
}

enum SessionPresets {
    /// Shipped presets.
    ///
    /// Agents default to their automatic-approval mode: the flags differ per CLI
    /// and are easy to get wrong by hand, which is exactly what a preset is for.
    /// The supervised variant sits directly underneath, because handing an agent
    /// unattended write access is a choice that should stay one click away in
    /// both directions.
    static let builtIn: [SessionPreset] = [
        SessionPreset(
            id: "builtin.terminal",
            name: "Terminal",
            kind: .shell,
            isBuiltIn: true
        ),
        SessionPreset(
            id: "builtin.claude.auto",
            name: "Claude",
            kind: .claude,
            arguments: ["--permission-mode", "auto"],
            isBuiltIn: true
        ),
        SessionPreset(
            id: "builtin.claude",
            name: "Claude · ask first",
            kind: .claude,
            isBuiltIn: true
        ),
        SessionPreset(
            id: "builtin.codex.auto",
            name: "Codex",
            kind: .codex,
            arguments: ["--approve-for-me"],
            isBuiltIn: true
        ),
        SessionPreset(
            id: "builtin.codex",
            name: "Codex · ask first",
            kind: .codex,
            isBuiltIn: true
        ),
        SessionPreset(
            id: "builtin.gemini.auto",
            name: "Gemini",
            kind: .gemini,
            arguments: ["--approval-mode", "auto_edit"],
            isBuiltIn: true
        ),
        SessionPreset(
            id: "builtin.opencode",
            name: "OpenCode",
            kind: .opencode,
            isBuiltIn: true
        ),
    ]

    /// Shown in the new-session menu out of the box.
    ///
    /// The catalogue is deliberately larger than this: a menu that lists every
    /// agent anyone might use is a menu nobody reads. The rest are one toggle
    /// away in settings.
    static let defaultEnabledIDs: [String] = [
        "builtin.terminal",
        "builtin.claude.auto",
        "builtin.codex.auto",
    ]

    /// Every preset, whether or not it is currently offered.
    static func catalogue(custom: [SessionPreset]) -> [SessionPreset] {
        builtIn + custom
    }

    /// The presets the menu offers, in catalogue order.
    static func enabled(custom: [SessionPreset], enabledIDs: [String]?) -> [SessionPreset] {
        let allowed = Set(enabledIDs ?? defaultEnabledIDs)
        return catalogue(custom: custom).filter { preset in
            // A preset the user created is offered by virtue of existing;
            // hiding it would mean it could only be reached from settings.
            !preset.isBuiltIn || allowed.contains(preset.id)
        }
    }

    static func all(custom: [SessionPreset]) -> [SessionPreset] {
        catalogue(custom: custom)
    }

    /// The preset a keyboard shortcut for a kind should launch: the first one
    /// that targets it, which is the automatic variant for agents.
    /// What a keyboard shortcut for a kind should launch: the first enabled
    /// preset for it, falling back to the catalogue so a shortcut still works
    /// for an agent the user has hidden from the menu.
    static func preferred(
        for kind: SessionKind,
        custom: [SessionPreset] = [],
        enabledIDs: [String]? = nil
    ) -> SessionPreset {
        enabled(custom: custom, enabledIDs: enabledIDs).first { $0.kind == kind }
            ?? catalogue(custom: custom).first { $0.kind == kind }
            ?? SessionPreset(name: kind.displayName, kind: kind)
    }
}
