import Foundation
import RelayProtocol

/// `relay <group> …`. A new group is a file declaring one of these, listed in
/// `CommandTable.groups`; parsing, help and printing need nothing else.
struct CommandGroup: Sendable {
    let name: String
    let summary: String
    let commands: [CommandSpec]
}

/// One command: what it accepts, the request it becomes, and how its answer
/// reads to a person.
struct CommandSpec: Sendable {
    struct Argument: Sendable {
        let name: String
        let isRequired: Bool
    }

    struct Option: Sendable {
        let name: String
        /// What stands for the value in help; nil for a switch.
        let value: String?
        let summary: String
    }

    let group: String
    let name: String
    /// Other names it answers to, for the verb someone reaches for first.
    var aliases: [String] = []
    let summary: String
    var argument: Argument?
    var options: [Option] = []
    var notes: [String] = []
    let examples: [String]
    /// How long the app may take. Making or removing a checkout is git
    /// writing or deleting a whole tree; reading a list is not.
    var timeout: TimeInterval = 30
    let request: @Sendable (ParsedArguments) throws -> ControlCommand
    let describe: @Sendable (ControlResponse) -> String

    var path: String { "relay \(group) \(name)" }

    var usage: String {
        var parts = [path]
        if let argument {
            parts.append(argument.isRequired ? "<\(argument.name)>" : "[<\(argument.name)>]")
        }
        for option in options {
            parts.append(option.value.map { "[--\(option.name) <\($0)>]" } ?? "[--\(option.name)]")
        }
        parts.append("[--json]")
        return parts.joined(separator: " ")
    }

    func answers(to word: String) -> Bool {
        word == name || aliases.contains(word)
    }
}

/// What was typed after the command's name, taken apart.
struct ParsedArguments: Equatable, Sendable {
    var argument: String?
    var values: [String: String] = [:]
    var switches: Set<String> = []
    var json = false

    func value(_ name: String) -> String? { values[name] }
    func isOn(_ name: String) -> Bool { switches.contains(name) }
}

/// Something typed that is not a command. Says what, and where to look.
struct UsageError: Error, Equatable, Sendable {
    let message: String
    /// The command that shows the help to read.
    let help: String
}

enum CommandTable {
    static let groups: [CommandGroup] = [WorktreeCommands.group]
}
