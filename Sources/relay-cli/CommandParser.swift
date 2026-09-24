import Foundation
import RelayProtocol

/// What the words on the command line come to.
enum Invocation {
    case help(String)
    case version
    case run(Run)
    case usage(UsageError, json: Bool)

    struct Run {
        let spec: CommandSpec
        let command: ControlCommand
        let json: Bool
    }
}

/// Hand-rolled rather than a package: the grammar is `group command
/// [argument] [--option value]`, and the command must start in milliseconds and
/// link nothing but the protocol.
enum CommandParser {
    static func parse(_ words: [String], groups: [CommandGroup] = CommandTable.groups) -> Invocation {
        let json = words.prefix { $0 != "--" }.contains("--json")
        guard let first = words.first else { return .help(Help.root(groups)) }
        switch first {
        case "help":
            return help(for: Array(words.dropFirst()), in: groups)
        case "--help", "-h":
            return .help(Help.root(groups))
        case "--version", "version":
            return .version
        default:
            break
        }

        guard let group = groups.first(where: { $0.name == first }) else {
            return .usage(UsageError(message: "There is no command called \(first).", help: "relay help"), json: json)
        }
        let rest = Array(words.dropFirst())
        guard let name = rest.first, name != "--json" else {
            let names = group.commands.map(\.name).joined(separator: ", ")
            return .usage(
                UsageError(message: "relay \(group.name) needs a command: \(names).", help: "relay \(group.name) --help"),
                json: json
            )
        }
        if name == "--help" || name == "-h" { return .help(Help.group(group)) }
        guard let spec = group.commands.first(where: { $0.answers(to: name) }) else {
            let names = group.commands.map(\.name).joined(separator: ", ")
            return .usage(
                UsageError(
                    message: "relay \(group.name) has no command called \(name). It has: \(names).",
                    help: "relay \(group.name) --help"
                ),
                json: json
            )
        }

        let tail = Array(rest.dropFirst())
        if tail.prefix(while: { $0 != "--" }).contains(where: { $0 == "--help" || $0 == "-h" }) {
            return .help(Help.command(spec))
        }
        do {
            let parsed = try arguments(tail, for: spec)
            return .run(Invocation.Run(spec: spec, command: try spec.request(parsed), json: parsed.json))
        } catch let error as UsageError {
            return .usage(error, json: json)
        } catch {
            return .usage(UsageError(message: "\(error)", help: "\(spec.path) --help"), json: json)
        }
    }

    /// `--name value`, `--name=value`, switches, one positional argument, and
    /// `--` before an argument that starts with a dash.
    ///
    /// The word after an option that takes a value is its value whatever it
    /// looks like, so `--comment "-"` and `--prompt "--help me"` say what they
    /// say; a value that is missing altogether is refused.
    static func arguments(_ words: [String], for spec: CommandSpec) throws -> ParsedArguments {
        let help = "\(spec.path) --help"
        var parsed = ParsedArguments()
        var index = words.startIndex
        var optionsEnded = false
        while index < words.endIndex {
            let word = words[index]
            index += 1
            if !optionsEnded, word == "--" {
                optionsEnded = true
                continue
            }
            if !optionsEnded, word.hasPrefix("--") {
                var name = String(word.dropFirst(2))
                var inline: String?
                if let equals = name.firstIndex(of: "=") {
                    inline = String(name[name.index(after: equals)...])
                    name = String(name[..<equals])
                }
                if name == "json" {
                    guard inline == nil else { throw UsageError(message: "--json takes no value.", help: help) }
                    parsed.json = true
                    continue
                }
                guard let option = spec.options.first(where: { $0.name == name }) else {
                    throw UsageError(message: "\(spec.path) has no option --\(name).", help: help)
                }
                guard option.value != nil else {
                    guard inline == nil else {
                        throw UsageError(message: "--\(name) takes no value.", help: help)
                    }
                    parsed.switches.insert(name)
                    continue
                }
                let value: String
                if let inline {
                    value = inline
                } else {
                    guard index < words.endIndex else {
                        throw UsageError(message: "--\(name) needs a value.", help: help)
                    }
                    value = words[index]
                    index += 1
                }
                guard parsed.values[name] == nil else {
                    throw UsageError(message: "--\(name) is given twice.", help: help)
                }
                parsed.values[name] = value
                continue
            }
            if !optionsEnded, word.hasPrefix("-"), word.count > 1 {
                throw UsageError(message: "\(spec.path) has no option \(word).", help: help)
            }
            guard let argument = spec.argument else {
                throw UsageError(message: "\(spec.path) takes no argument, and was given \(word).", help: help)
            }
            if let earlier = parsed.argument {
                throw UsageError(
                    message: "\(spec.path) takes one \(argument.name), and was given \(earlier) and \(word).",
                    help: help
                )
            }
            parsed.argument = word
        }
        if let argument = spec.argument, argument.isRequired, parsed.argument == nil {
            throw UsageError(message: "\(spec.path) needs a \(argument.name).", help: help)
        }
        return parsed
    }

    private static func help(for topic: [String], in groups: [CommandGroup]) -> Invocation {
        guard let name = topic.first else { return .help(Help.root(groups)) }
        guard let group = groups.first(where: { $0.name == name }) else {
            return .usage(UsageError(message: "There is no command called \(name).", help: "relay help"), json: false)
        }
        guard let command = topic.dropFirst().first else { return .help(Help.group(group)) }
        guard let spec = group.commands.first(where: { $0.answers(to: command) }) else {
            return .usage(
                UsageError(message: "relay \(group.name) has no command called \(command).", help: "relay \(group.name) --help"),
                json: false
            )
        }
        return .help(Help.command(spec))
    }
}
