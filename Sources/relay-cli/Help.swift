import Foundation

/// Help is read by agents more often than by people, so it is short, says
/// what a command acts on when nothing is named, and ends with examples to
/// copy.
enum Help {
    static func root(_ groups: [CommandGroup]) -> String {
        let width = groups.map(\.name.count).max() ?? 0
        var lines = [
            "relay: work with the Relay app from inside its terminals.",
            "",
            "Usage: relay <group> <command> [<argument>] [options] [--json]",
            "",
        ]
        lines += groups.map { "  " + padded($0.name, to: width) + "   " + $0.summary }
        lines += [
            "",
            "Run in a Relay terminal, a command acts on the project and the worktree it is run in,",
            "and what it does shows in Relay's sidebar at once. Add --json for an answer a program",
            "can read, errors included.",
            "",
            "Examples:",
            "  relay worktree list",
            "  relay worktree create fix-login --agent claude --prompt \"Fix the redirect after login\"",
            "  relay worktree set --status in-review --comment \"Ready: the tests pass\"",
            "",
            "relay help <group> [<command>] says more; relay --version prints the version.",
            "Exit status: 0 done, 1 refused or failed, 2 not a command.",
        ]
        return lines.joined(separator: "\n")
    }

    static func group(_ group: CommandGroup) -> String {
        let width = group.commands.map(\.name.count).max() ?? 0
        var lines = ["relay \(group.name): \(lowercasedFirst(group.summary))", "", "Commands:"]
        lines += group.commands.map { "  " + padded($0.name, to: width) + "   " + $0.summary }
        lines += ["", "Examples:"]
        lines += group.commands.compactMap(\.examples.first).map { "  " + $0 }
        lines += ["", "relay \(group.name) <command> --help shows a command's options."]
        return lines.joined(separator: "\n")
    }

    static func command(_ spec: CommandSpec) -> String {
        var lines = ["\(spec.path): \(lowercasedFirst(spec.summary))", "", "Usage: \(spec.usage)"]
        if !spec.aliases.isEmpty {
            lines.append("Also: " + spec.aliases.map { "relay \(spec.group) \($0)" }.joined(separator: ", "))
        }
        let options = spec.options.map { option in
            ("--\(option.name)" + (option.value.map { " <\($0)>" } ?? ""), option.summary)
        } + [("--json", "Print the answer as JSON, errors included.")]
        let width = options.map(\.0.count).max() ?? 0
        lines += ["", "Options:"]
        lines += options.map { "  " + padded($0.0, to: width) + "   " + $0.1 }
        if !spec.notes.isEmpty {
            lines += [""] + spec.notes.map { "- " + $0 }
        }
        lines += ["", "Examples:"] + spec.examples.map { "  " + $0 }
        return lines.joined(separator: "\n")
    }

    private static func padded(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
    }
}
