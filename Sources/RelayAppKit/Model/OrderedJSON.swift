import Foundation

/// JSON that keeps what it was given: the order of every object's keys, and
/// every value exactly as it was spelled.
///
/// For editing files that belong to someone else. `JSONSerialization` would
/// hand `~/.claude/settings.json` back with its keys shuffled and its slashes
/// escaped, which is a diff of the whole file for the sake of one entry.
/// Written back, it is in the shape `JSON.stringify(value, null, 2)` gives —
/// the shape Claude Code and every tool beside it write these files in — so a
/// file that was already in it changes only where something was added.
indirect enum OrderedJSON: Equatable {
    case object([(key: String, value: OrderedJSON)])
    case array([OrderedJSON])
    /// A string, number, `true`, `false` or `null`, as its source text.
    case scalar(String)

    static func == (lhs: OrderedJSON, rhs: OrderedJSON) -> Bool {
        switch (lhs, rhs) {
        case let (.object(left), .object(right)):
            left.count == right.count && zip(left, right).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        case let (.array(left), .array(right)):
            left == right
        case let (.scalar(left), .scalar(right)):
            left == right
        default:
            false
        }
    }

    // MARK: - Building

    static func string(_ value: String) -> OrderedJSON {
        .scalar(quoted(value))
    }

    static func number(_ value: Int) -> OrderedJSON {
        .scalar(String(value))
    }

    /// Escaped the way `JSON.stringify` escapes, and no further.
    static func quoted(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\u{08}": result += "\\b"
            case "\u{0C}": result += "\\f"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case let control where control.value < 0x20:
                result += String(format: "\\u%04x", control.value)
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// The value of a string, or nil for anything else.
    var stringValue: String? {
        guard case let .scalar(token) = self, token.hasPrefix("\"") else { return nil }
        return try? JSONDecoder().decode(String.self, from: Data(token.utf8))
    }

    subscript(key: String) -> OrderedJSON? {
        guard case let .object(members) = self else { return nil }
        return members.last { $0.key == key }?.value
    }

    /// Replaces a member, keeping its place, or adds it at the end.
    func setting(_ key: String, to value: OrderedJSON) -> OrderedJSON {
        guard case var .object(members) = self else { return self }
        if let index = members.lastIndex(where: { $0.key == key }) {
            members[index].value = value
        } else {
            members.append((key, value))
        }
        return .object(members)
    }

    // MARK: - Writing

    func serialized(indent: Int = 0) -> String {
        let padding = String(repeating: "  ", count: indent + 1)
        let closing = String(repeating: "  ", count: indent)
        switch self {
        case let .scalar(token):
            return token
        case let .array(elements):
            guard !elements.isEmpty else { return "[]" }
            let lines = elements.map { padding + $0.serialized(indent: indent + 1) }
            return "[\n" + lines.joined(separator: ",\n") + "\n" + closing + "]"
        case let .object(members):
            guard !members.isEmpty else { return "{}" }
            let lines = members.map { padding + Self.quoted($0.key) + ": " + $0.value.serialized(indent: indent + 1) }
            return "{\n" + lines.joined(separator: ",\n") + "\n" + closing + "}"
        }
    }

    // MARK: - Reading

    struct ParseError: Error {}

    static func parse(_ text: String) throws -> OrderedJSON {
        var parser = Parser(scalars: Array(text.unicodeScalars))
        let value = try parser.value()
        parser.skipWhitespace()
        guard parser.isAtEnd else { throw ParseError() }
        return value
    }

    private struct Parser {
        let scalars: [Unicode.Scalar]
        var position = 0

        var isAtEnd: Bool { position >= scalars.count }

        mutating func skipWhitespace() {
            while !isAtEnd, [" ", "\n", "\r", "\t"].contains(scalars[position]) { position += 1 }
        }

        mutating func value() throws -> OrderedJSON {
            skipWhitespace()
            guard !isAtEnd else { throw ParseError() }
            switch scalars[position] {
            case "{": return try object()
            case "[": return try array()
            case "\"": return .scalar(try stringToken())
            default: return .scalar(try bareToken())
            }
        }

        mutating func object() throws -> OrderedJSON {
            position += 1
            var members: [(key: String, value: OrderedJSON)] = []
            skipWhitespace()
            if !isAtEnd, scalars[position] == "}" {
                position += 1
                return .object(members)
            }
            while true {
                skipWhitespace()
                guard !isAtEnd, scalars[position] == "\"" else { throw ParseError() }
                let token = try stringToken()
                guard let key = try? JSONDecoder().decode(String.self, from: Data(token.utf8)) else { throw ParseError() }
                skipWhitespace()
                guard !isAtEnd, scalars[position] == ":" else { throw ParseError() }
                position += 1
                members.append((key, try value()))
                skipWhitespace()
                guard !isAtEnd else { throw ParseError() }
                if scalars[position] == "," {
                    position += 1
                } else if scalars[position] == "}" {
                    position += 1
                    return .object(members)
                } else {
                    throw ParseError()
                }
            }
        }

        mutating func array() throws -> OrderedJSON {
            position += 1
            var elements: [OrderedJSON] = []
            skipWhitespace()
            if !isAtEnd, scalars[position] == "]" {
                position += 1
                return .array(elements)
            }
            while true {
                elements.append(try value())
                skipWhitespace()
                guard !isAtEnd else { throw ParseError() }
                if scalars[position] == "," {
                    position += 1
                } else if scalars[position] == "]" {
                    position += 1
                    return .array(elements)
                } else {
                    throw ParseError()
                }
            }
        }

        mutating func stringToken() throws -> String {
            let start = position
            position += 1
            while !isAtEnd {
                let scalar = scalars[position]
                if scalar == "\\" {
                    position += 2
                    continue
                }
                position += 1
                if scalar == "\"" {
                    var token = ""
                    token.unicodeScalars.append(contentsOf: scalars[start ..< position])
                    return token
                }
                guard scalar.value >= 0x20 else { throw ParseError() }
            }
            throw ParseError()
        }

        /// A number or a literal, checked by the one parser that knows the rules.
        mutating func bareToken() throws -> String {
            let start = position
            while !isAtEnd, !([",", "}", "]", " ", "\n", "\r", "\t"].contains(scalars[position])) {
                position += 1
            }
            var token = ""
            token.unicodeScalars.append(contentsOf: scalars[start ..< position])
            guard !token.isEmpty,
                  (try? JSONSerialization.jsonObject(with: Data(token.utf8), options: .fragmentsAllowed)) != nil
            else { throw ParseError() }
            return token
        }
    }
}
