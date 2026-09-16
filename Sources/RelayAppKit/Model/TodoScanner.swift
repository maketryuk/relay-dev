import Foundation

/// One note a project has left itself, and where it was left.
struct TodoItem: Identifiable, Equatable, Sendable {
    /// Relative to the project root, which is how both searches report it and
    /// how an agent is told to find it.
    var path: String
    var line: Int
    /// As written, upper-cased. Which words count is the project's to decide,
    /// so this is a word rather than a case.
    var marker: String
    /// What the comment says after the marker, which is the point of it.
    var text: String

    /// Place and marker together. A list re-read after an edit has to line up
    /// with the picks made on the last one, and nothing else about a note is
    /// stable enough to line up by.
    var id: String { "\(path):\(line):\(marker)" }

    /// The last component, which is what a narrow list has room for.
    var name: String { (path as NSString).lastPathComponent }
    var directory: String { (path as NSString).deletingLastPathComponent }
}

/// What one sweep of a project found.
struct TodoScan: Equatable, Sendable {
    var items: [TodoItem] = []
    /// Whether the sweep stopped short. A count that quietly caps reads as the
    /// truth about the project, which at that size it is not.
    var isTruncated = false

    var isEmpty: Bool { items.isEmpty }

    /// How many of each marker, in the order the markers were asked for, and
    /// only the ones that found something: a filter offering `HACK 0` is
    /// offering to show nothing.
    func counts(for markers: [String]) -> [TodoCount] {
        var tally: [String: Int] = [:]
        for item in items {
            tally[item.marker, default: 0] += 1
        }
        return markers.compactMap { marker in
            tally[marker].map { TodoCount(marker: marker, count: $0) }
        }
    }
}

/// How many notes carry one marker.
struct TodoCount: Identifiable, Equatable, Sendable {
    var marker: String
    var count: Int

    var id: String { marker }
}

/// Finds the notes a project has left itself.
///
/// Two searches rather than one, because a repository already knows which
/// files are the project's: `git grep` skips what `.gitignore` names, which is
/// the difference between a hundred results and a hundred thousand in any
/// project with its dependencies checked in. A directory that is not a
/// repository gets `grep` with the usual suspects excluded by hand.
enum TodoScanner {
    /// What almost every codebase leaves behind. A project that marks its work
    /// some other way can say so; this is what it finds until it does.
    static let defaultMarkers = ["TODO", "FIXME", "HACK", "XXX", "BUG"]

    /// The ones worth offering in a list to tick, beyond the ones on by
    /// default. Not a closed set — a project can be told to look for a word
    /// nobody else uses — but a list to pick from beats an empty field.
    static let suggestedMarkers = defaultMarkers + ["NOTE", "OPTIMIZE", "REVIEW", "WIP", "DEPRECATED"]

    /// What to store for a list somebody chose or typed.
    ///
    /// An emptied set means "the usual ones" rather than "find nothing": a
    /// panel that lists nothing whatever the project contains reads as broken
    /// rather than as configured. Stored already resolved, so what is saved is
    /// always what is searched for.
    static func markers(from chosen: [String]) -> [String] {
        let normalised = normalise(chosen)
        return normalised.isEmpty ? defaultMarkers : normalised
    }

    /// Beyond this a list is not read, it is measured — and the measuring is
    /// what the count is for.
    static let limit = 2000

    /// Directories no search of a project's own code should descend into.
    /// Consulted outside a repository only; inside one `.gitignore` already
    /// says all of this, and says it better.
    private static let skippedDirectories = [
        ".git", ".build", ".next", ".venv", ".yarn", "DerivedData", "Pods",
        "__pycache__", "build", "dist", "node_modules", "target", "vendor", "venv",
    ]

    static func scan(at root: String, markers: [String]) -> TodoScan {
        let markers = normalise(markers)
        guard !markers.isEmpty else { return TodoScan() }
        let pattern = expression(for: markers)

        let result: Shell.Result? = if GitProbe.isRepository(at: root) {
            Shell.capture("/usr/bin/git", arguments: [
                "-C", root, "grep", "--no-color", "-I", "-n", "-E", "--untracked", "-e", pattern,
            ], timeout: 20)
        } else {
            Shell.capture(
                "/usr/bin/grep",
                arguments: ["-rnI", "-E"]
                    + skippedDirectories.map { "--exclude-dir=\($0)" }
                    + [pattern, root],
                timeout: 20
            )
        }

        // Both exit 1 on "found nothing", which is an answer rather than a
        // failure; anything above that is the search itself going wrong.
        guard let result, result.status <= 1 else { return TodoScan() }
        return parse(result.output, markers: markers, strippingPrefix: root)
    }

    /// Upper-cased, letters only, no repeats.
    ///
    /// Case-sensitive by design — "todo" in a sentence of prose is not a note
    /// to self — and letters only because these are pasted into an expression:
    /// a marker typed as `.*` would otherwise match every line in the project.
    static func normalise(_ markers: [String]) -> [String] {
        var seen = Set<String>()
        return markers
            .map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
            .filter { !$0.isEmpty && $0.allSatisfy(\.isLetter) && seen.insert($0).inserted }
    }

    /// A marker has to be a whole word: `AUTODOC` is not a note to anybody.
    private static func expression(for markers: [String]) -> String {
        "(^|[^A-Za-z0-9_])(" + markers.joined(separator: "|") + ")([^A-Za-z0-9_]|$)"
    }

    /// Turns `path:line:text` records into notes, keeping only what was
    /// written in a comment.
    ///
    /// The search cannot tell a comment from a string literal — every language
    /// writes comments differently and neither `grep` reads any of them — so
    /// it is asked for a superset and the judgement is made here, where it can
    /// be tested.
    static func parse(
        _ output: String,
        markers: [String],
        strippingPrefix prefix: String = ""
    ) -> TodoScan {
        var items: [TodoItem] = []
        var isTruncated = false

        for record in output.split(separator: "\n") {
            guard items.count < limit else {
                isTruncated = true
                break
            }
            guard let record = split(record: String(record)),
                  let note = note(in: record.content, markers: markers)
            else { continue }

            items.append(TodoItem(
                path: relative(record.path, to: prefix),
                line: record.line,
                marker: note.marker,
                text: note.text
            ))
        }

        // File then line: the order the work would be done in, and the order a
        // reader scrolling the list expects to find it in.
        items.sort { $0.path == $1.path ? $0.line < $1.line : $0.path < $1.path }
        return TodoScan(items: items, isTruncated: isTruncated)
    }

    /// `path:line:text`, where the path is allowed to contain a colon of its
    /// own: the line number is the first run of digits sitting between two
    /// colons, and the name is everything before it.
    static func split(record: String) -> (path: String, line: Int, content: String)? {
        var start = record.startIndex
        while let colon = record[start...].firstIndex(of: ":") {
            let afterColon = record.index(after: colon)
            guard let next = record[afterColon...].firstIndex(of: ":") else { return nil }
            if let line = Int(record[afterColon ..< next]) {
                return (
                    String(record[record.startIndex ..< colon]),
                    line,
                    String(record[record.index(after: next)...])
                )
            }
            start = afterColon
        }
        return nil
    }

    /// The note a line carries, or nothing when the word is there but not as
    /// one. The earliest marker on the line wins, because that is the one the
    /// comment is about.
    static func note(in content: String, markers: [String]) -> (marker: String, text: String)? {
        let structure = structure(of: content)
        let found = markers
            .compactMap { marker -> (marker: String, range: Range<String.Index>)? in
                wordRange(of: marker, in: content).map { (marker, $0) }
            }
            .filter { isNote(at: $0.range, in: content, structure: structure) }
            .min { $0.range.lowerBound < $1.range.lowerBound }

        guard let found else { return nil }

        let text = message(after: found.range.upperBound, in: content)
        // A bare marker with nothing after it still has to say something in a
        // list, and the line it sits on is the only thing left to say.
        return (found.marker, text.isEmpty ? content.trimmingCharacters(in: .whitespaces) : text)
    }

    private static func wordRange(of marker: String, in content: String) -> Range<String.Index>? {
        var start = content.startIndex
        while let range = content.range(of: marker, range: start ..< content.endIndex) {
            let before = range.lowerBound == content.startIndex
                ? nil
                : content[content.index(before: range.lowerBound)]
            let after = range.upperBound == content.endIndex ? nil : content[range.upperBound]
            if !isWordCharacter(before), !isWordCharacter(after) { return range }
            start = range.upperBound
        }
        return nil
    }

    private static func isWordCharacter(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber || character == "_"
    }

    /// Every way a line can say "the rest of this is prose", in one list
    /// rather than one per language: which languages a project is written in
    /// is not knowable from here, and each of these introduces a comment
    /// somewhere. A lone `*` is in because that is how the middle of a block
    /// comment is written everywhere it exists.
    ///
    /// Longest first, so `<!--` is recognised as itself rather than as a `--`
    /// that happens to follow a `<`.
    private static let commentOpeners = ["<!--", "\"\"\"", "'''", "//", "/*", "--", "#", "*", ";", "%"]

    /// What can stand between the thing that opened a comment and its first
    /// word, so `///` and `/**` and `<!--` all read as an empty run-up.
    private static let openerCharacters: Set<Character> = ["/", "*", "#", "<", "!", "-", ";", "%", "\"", "'"]

    /// What a line is made of, as far as telling a remark from a value needs.
    struct LineStructure: Equatable {
        /// Comment openers that are not themselves inside a string.
        var commentStarts: [String.Index] = []
        /// The string literals on the line.
        var strings: [Range<String.Index>] = []

        func isQuoted(_ index: String.Index) -> Bool {
            strings.contains { $0.contains(index) }
        }

        /// The opener a marker at this position belongs to: the nearest one
        /// before it.
        ///
        /// Nearest rather than first, because a line can carry several and only
        /// one of them started the remark. A line that multiplies before it
        /// comments opens with a `*`, and read against that one instead of the
        /// `#` that actually started the remark, the remark is lost.
        func comment(before index: String.Index) -> String.Index? {
            commentStarts.last { $0 < index }
        }
    }

    /// Reads a line far enough to tell a remark from a value.
    ///
    /// Both answers come out of one walk because they are one question asked
    /// twice: a `//` inside quotes opens nothing, and a marker inside quotes is
    /// data rather than a note. A line of test data that quotes a comment is
    /// the obvious case, and it is what used to fill this list with the
    /// project's own fixtures.
    static func structure(of content: String) -> LineStructure {
        var result = LineStructure()
        var quote: (mark: Character, start: String.Index)?
        var index = content.startIndex

        while index < content.endIndex {
            let character = content[index]

            if character == "\\" {
                index = content.index(index, offsetBy: 2, limitedBy: content.endIndex) ?? content.endIndex
                continue
            }

            if let open = quote {
                if character == open.mark {
                    result.strings.append(open.start ..< content.index(after: index))
                    quote = nil
                }
            } else if character == "#", let raw = rawString(at: index, in: content) {
                result.strings.append(raw)
                index = raw.upperBound
                continue
            } else if let opener = commentOpeners.first(where: { content[index...].hasPrefix($0) }) {
                result.commentStarts.append(index)
                // Past the whole opener, so `<!--` is not also read as the `--`
                // inside it and `"""` does not then open a string.
                index = content.index(index, offsetBy: opener.count, limitedBy: content.endIndex)
                    ?? content.endIndex
                continue
            } else if character == "\"" || character == "'" {
                quote = (character, index)
            }

            index = content.index(after: index)
        }

        // A quote that never closes was not one — an apostrophe in prose,
        // usually — so nothing after it counts as quoted.
        return result
    }

    /// A Swift raw string — `#"…"#`, with any number of hashes.
    ///
    /// Worth knowing about because its entire purpose is that nothing inside it
    /// means anything, which is precisely what a line of test data holding a
    /// comment is. Without this the hashes read as a comment opener and the
    /// quoted comment read as a real one.
    private static func rawString(at index: String.Index, in content: String) -> Range<String.Index>? {
        var hashes = 0
        var cursor = index
        while cursor < content.endIndex, content[cursor] == "#" {
            hashes += 1
            cursor = content.index(after: cursor)
        }
        guard hashes > 0, cursor < content.endIndex, content[cursor] == "\"" else { return nil }

        let terminator = "\"" + String(repeating: "#", count: hashes)
        let body = content.index(after: cursor)
        guard body < content.endIndex,
              let end = content.range(of: terminator, range: body ..< content.endIndex)
        else { return nil }
        return index ..< end.upperBound
    }

    /// Whether a marker was written as a note rather than mentioned in one.
    ///
    /// It has to sit inside a comment, and then either open the remark or
    /// announce itself with the punctuation everyone writes these with.
    /// Without that, a comment *about* notes is indistinguishable from one, and
    /// the panel listing them fills with its own documentation.
    private static func isNote(
        at range: Range<String.Index>,
        in content: String,
        structure: LineStructure
    ) -> Bool {
        guard !structure.isQuoted(range.lowerBound) else { return false }
        guard let start = structure.comment(before: range.lowerBound) else { return false }

        if let next = content[range.upperBound...].first, next == ":" || next == "(" || next == "!" {
            return true
        }
        let leadIn = content[start ..< range.lowerBound]
        return leadIn.allSatisfy { $0.isWhitespace || openerCharacters.contains($0) }
    }

    /// What the remark says, with the punctuation that introduced it and
    /// whatever closes the comment taken off: a marker followed by an author
    /// in brackets, a colon, the sentence, and a `*/` comes back as the
    /// sentence alone.
    private static func message(after index: String.Index, in content: String) -> String {
        var text = String(content[index...])

        // Whose note it is does not change what has to be done.
        if text.hasPrefix("("), let close = text.firstIndex(of: ")") {
            text = String(text[text.index(after: close)...])
        }

        text = text.trimmingCharacters(in: .whitespaces)
        while let first = text.first, first == ":" || first == "-" {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        for closer in ["*/", "-->", "\"\"\"", "'''", "#}", "}}"] where text.hasSuffix(closer) {
            text = String(text.dropLast(closer.count))
            break
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func relative(_ path: String, to root: String) -> String {
        guard !root.isEmpty else { return path }
        let base = root.hasSuffix("/") ? root : root + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
    }
}

/// Turns picked notes into something worth pasting into an agent's prompt.
///
/// The same shape as a review's, because it is read by the same thing: the
/// file, the line, and what was written there. The instruction comes last and
/// once — it is what the notes are being handed over *for*, and repeating it
/// under each one reads as a different instruction each time.
enum TodoTranscript {
    static func compose(_ todos: [TodoItem], instruction: String) -> String {
        let ordered = todos.sorted {
            $0.path == $1.path ? $0.line < $1.line : $0.path < $1.path
        }
        var blocks = ordered.map(block(for:))

        let instruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !instruction.isEmpty {
            blocks.append("What to do: \(instruction)")
        }
        return blocks.joined(separator: "\n\n")
    }

    /// Flush left, because a terminal prompt indents what is typed into it and
    /// a second indent on top of that reads as formatting that went wrong.
    private static func block(for todo: TodoItem) -> String {
        """
        File: \(todo.path)
        Line: \(todo.line)
        \(todo.marker): \(todo.text)
        """
    }
}
