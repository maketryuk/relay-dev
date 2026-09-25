import Foundation

/// A Swift file as the tests that read the source need it: its string literals,
/// and which of its characters are code rather than comment or string.
///
/// Read the way the compiler reads it rather than by pattern, because patterns
/// are wrong in exactly the places that matter: a quote inside a comment is not
/// a string, a parenthesis inside a string closes nothing, and an interpolation
/// is code again, with literals of its own.
struct SwiftSourceFile {
    struct Literal {
        /// The text between the quotes, with escapes as written — the way the
        /// string tables write them too — and each interpolation as `\(…)`.
        var text: String
        /// The opening quote, as an index into `characters`.
        var start: Int
        var isInterpolated: Bool
    }

    let path: String
    let characters: [Character]
    private(set) var literals: [Literal] = []
    /// True where a character is code: outside every comment and literal.
    private(set) var isCode: [Bool]
    private let lineStarts: [Int]
    /// Where each called name's argument list opens: `Text` for `Text(`, and
    /// `.help` for a modifier written `.help(`.
    private var openingParentheses: [String: [Int]] = [:]

    init(path: String, contents: String) {
        let characters = Array(contents)
        self.path = path
        self.characters = characters
        isCode = Array(repeating: false, count: characters.count)
        lineStarts = [0] + characters.indices.filter { characters[$0] == "\n" }.map { $0 + 1 }
        _ = scanCode(from: 0, closingInterpolation: false)
        indexCalls()
    }

    private mutating func indexCalls() {
        var index = 0
        while index < characters.count {
            guard isCode[index], Self.isIdentifier(characters[index]),
                  index == 0 || !Self.isIdentifier(characters[index - 1])
            else {
                index += 1
                continue
            }
            var end = index
            while end < characters.count, isCode[end], Self.isIdentifier(characters[end]) { end += 1 }
            if end < characters.count, isCode[end], characters[end] == "(" {
                var name = String(characters[index ..< end])
                if index > 0, characters[index - 1] == "." { name = "." + name }
                openingParentheses[name, default: []].append(end)
            }
            index = end
        }
    }

    /// `file.swift:42`, for a failure to point at.
    func location(of index: Int) -> String {
        let line = lineStarts.lastIndex { $0 <= index } ?? 0
        return "\((path as NSString).lastPathComponent):\(line + 1)"
    }

    // MARK: - Calls

    /// The argument list of every call to `name`, from just after its opening
    /// parenthesis to just before its closing one.
    ///
    /// `name` is matched as a whole identifier, so `Button` is not found inside
    /// `RelayButton`; a name starting with a dot is a modifier, and matches only
    /// where it is written after one.
    func arguments(ofCallsTo name: String) -> [Range<Int>] {
        (openingParentheses[name] ?? []).map { $0 + 1 ..< closingParenthesis(after: $0) }
    }

    /// The first argument inside an argument list: up to the first comma that
    /// belongs to the list itself rather than to something nested in it.
    func firstArgument(of arguments: Range<Int>) -> Range<Int> {
        var depth = 0
        for index in arguments where isCode[index] {
            switch characters[index] {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            case "," where depth == 0: return arguments.lowerBound ..< index
            default: break
            }
        }
        return arguments
    }

    /// Whether a literal inside `range` stands at its top level — the value of
    /// the expression, or one arm of a ternary — rather than inside a call or a
    /// closure nested within it.
    func isTopLevel(_ literal: Literal, in range: Range<Int>) -> Bool {
        var depth = 0
        for index in range.lowerBound ..< literal.start where isCode[index] {
            switch characters[index] {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            default: break
            }
        }
        return depth == 0
    }

    func literals(in range: Range<Int>) -> [Literal] {
        literals.filter { range.contains($0.start) }
    }

    /// The code just before a literal, ignoring the whitespace in between:
    /// `titleKey:` for a palette entry, `case .x:` for a switch arm.
    func codeBefore(_ literal: Literal, length: Int) -> String {
        var end = literal.start
        while end > 0, characters[end - 1].isWhitespace { end -= 1 }
        return String(characters[max(0, end - length) ..< end])
    }

    /// The line a literal's value is chosen on, when the literal is the whole of
    /// what follows a colon: the `case` or `default` of a switch arm, whether
    /// the literal is on that line or the next.
    func lineEndingInColon(before literal: Literal) -> String? {
        var end = literal.start
        while end > 0, characters[end - 1].isWhitespace { end -= 1 }
        guard end > 0, characters[end - 1] == ":" else { return nil }
        let start = lineStarts.last { $0 < end } ?? 0
        return String(characters[start ..< end]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Reading

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private func closingParenthesis(after open: Int) -> Int {
        var depth = 0
        for index in open ..< characters.count where isCode[index] {
            if characters[index] == "(" { depth += 1 }
            if characters[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
        }
        return characters.count
    }

    private func matches(_ text: String, at index: Int) -> Bool {
        var cursor = index
        for character in text {
            guard cursor < characters.count, characters[cursor] == character else { return false }
            cursor += 1
        }
        return true
    }

    /// Code up to the end of the file, or, inside an interpolation, up to the
    /// parenthesis that closes it — returning the index just after it.
    private mutating func scanCode(from start: Int, closingInterpolation: Bool) -> Int {
        var index = start
        var depth = 0
        while index < characters.count {
            let character = characters[index]
            if matches("//", at: index) {
                while index < characters.count, characters[index] != "\n" { index += 1 }
                continue
            }
            if matches("/*", at: index) {
                index = endOfBlockComment(from: index)
                continue
            }
            if character == "\"" || (character == "#" && startsRawString(at: index)) {
                index = scanLiteral(from: index)
                continue
            }
            if closingInterpolation, character == ")", depth == 0 { return index + 1 }
            if character == "(" { depth += 1 }
            if character == ")" { depth -= 1 }
            isCode[index] = true
            index += 1
        }
        return index
    }

    /// Swift's block comments nest.
    private func endOfBlockComment(from start: Int) -> Int {
        var index = start
        var depth = 0
        while index < characters.count {
            if matches("/*", at: index) {
                depth += 1
                index += 2
            } else if matches("*/", at: index) {
                depth -= 1
                index += 2
                if depth == 0 { return index }
            } else {
                index += 1
            }
        }
        return index
    }

    private func startsRawString(at index: Int) -> Bool {
        var cursor = index
        while cursor < characters.count, characters[cursor] == "#" { cursor += 1 }
        return cursor < characters.count && characters[cursor] == "\""
    }

    private mutating func scanLiteral(from start: Int) -> Int {
        var index = start
        var hashes = 0
        while characters[index] == "#" {
            hashes += 1
            index += 1
        }
        let isMultiline = matches("\"\"\"", at: index)
        let quote = isMultiline ? "\"\"\"" : "\""
        let closing = quote + String(repeating: "#", count: hashes)
        let escape = "\\" + String(repeating: "#", count: hashes)
        index += quote.count

        var text = ""
        var isInterpolated = false
        while index < characters.count {
            if matches(closing, at: index) {
                index += closing.count
                break
            }
            if matches(escape, at: index) {
                let escaped = index + escape.count
                if escaped < characters.count, characters[escaped] == "(" {
                    index = scanCode(from: escaped + 1, closingInterpolation: true)
                    text += "\\(…)"
                    isInterpolated = true
                    continue
                }
                text += escape
                if escaped < characters.count { text.append(characters[escaped]) }
                index = escaped + 1
                continue
            }
            // An unterminated single-line literal ends with its line rather
            // than swallowing the rest of the file.
            if !isMultiline, characters[index] == "\n" { break }
            text.append(characters[index])
            index += 1
        }
        literals.append(Literal(text: text, start: start, isInterpolated: isInterpolated))
        return index
    }
}

extension SwiftSourceFile {
    /// Every Swift file under a directory.
    static func all(under directory: URL) throws -> [SwiftSourceFile] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        let urls = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        return try urls.map { url in
            try SwiftSourceFile(path: url.path, contents: String(contentsOf: url, encoding: .utf8))
        }
    }
}
