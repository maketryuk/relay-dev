import Foundation

/// Which file the review window is showing.
///
/// The side is part of the identity, not a detail: a file staged and then
/// edited again has two different diffs, and they are both worth reading.
struct GitDiffSelection: Equatable, Sendable {
    var path: String
    var isStaged: Bool
}

/// One line of a diff, with the numbers it had on each side.
///
/// Line numbers are carried rather than derived at draw time: a hunk header
/// states where it starts, and counting from it is the only way to put a number
/// beside a line that was deleted.
struct DiffLine: Equatable, Sendable, Identifiable {
    enum Kind: Equatable, Sendable {
        case context
        case added
        case removed
        /// `\ No newline at end of file`, which belongs to the line above it.
        case note
    }

    var kind: Kind
    var text: String
    var oldNumber: Int?
    var newNumber: Int?
    /// Position in the file's diff, since nothing else about a line is unique.
    var id: Int

    /// The number to show, and the one a remark is filed under: where a line
    /// exists in the working copy that is the number a person would quote, and
    /// a deleted line keeps the number it had.
    var number: Int? { newNumber ?? oldNumber }
}

/// A run of changed lines with its surrounding context.
struct DiffHunk: Equatable, Sendable, Identifiable {
    /// The `@@ … @@` line, including whatever git put after it.
    var header: String
    var lines: [DiffLine]
    /// Where the hunk sits in the file it came from. Kept because the gap
    /// between two hunks — the lines nobody touched — can only be worked out
    /// from these, and a diff that does not say how much it is hiding reads as
    /// a file with pieces missing.
    var oldStart = 1
    var oldCount = 0
    var newStart = 1
    var newCount = 0

    var id: String { header }

    /// The first line after this hunk, on the side the file already had.
    var oldEnd: Int { oldStart + oldCount }
}

/// One file's diff, as the app needs to draw it.
struct FileDiff: Equatable, Sendable {
    var hunks: [DiffHunk] = []
    /// Git says so rather than showing it; there is nothing to render.
    var isBinary = false
    /// Read but not parsed: past a certain size a diff is no longer something
    /// a person reads, and laying it out is what stops the window responding.
    var isTooLarge = false

    var isEmpty: Bool { hunks.isEmpty && !isBinary && !isTooLarge }

    var insertions: Int {
        hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .added } }
    }

    var deletions: Int {
        hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .removed } }
    }
}

/// Reads the unified diff `git diff` prints.
///
/// Only what is between the hunks is parsed: the `diff --git`, `index`, `---`
/// and `+++` preamble says what the caller already asked for, and repeating it
/// on screen would be noise above every file.
enum DiffParser {
    static func parse(unified output: String) -> FileDiff {
        var diff = FileDiff()
        var hunk: DiffHunk?
        var oldNumber = 0
        var newNumber = 0
        var position = 0

        func close() {
            if let hunk { diff.hunks.append(hunk) }
            hunk = nil
        }

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)

            if line.hasPrefix("@@") {
                close()
                let range = hunkRange(in: line)
                oldNumber = range.old.start
                newNumber = range.new.start
                hunk = DiffHunk(
                    header: line,
                    lines: [],
                    oldStart: range.old.start,
                    oldCount: range.old.count,
                    newStart: range.new.start,
                    newCount: range.new.count
                )
                continue
            }

            if hunk == nil {
                // Git reports a binary difference instead of one, and says so
                // in the preamble where the first hunk would have been.
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") {
                    diff.isBinary = true
                }
                continue
            }

            position += 1
            switch line.first {
            case "+":
                hunk?.lines.append(DiffLine(
                    kind: .added, text: String(line.dropFirst()),
                    oldNumber: nil, newNumber: newNumber, id: position
                ))
                newNumber += 1
            case "-":
                hunk?.lines.append(DiffLine(
                    kind: .removed, text: String(line.dropFirst()),
                    oldNumber: oldNumber, newNumber: nil, id: position
                ))
                oldNumber += 1
            case "\\":
                hunk?.lines.append(DiffLine(
                    kind: .note, text: String(line.dropFirst(2)),
                    oldNumber: nil, newNumber: nil, id: position
                ))
            case " ":
                hunk?.lines.append(DiffLine(
                    kind: .context, text: String(line.dropFirst()),
                    oldNumber: oldNumber, newNumber: newNumber, id: position
                ))
                oldNumber += 1
                newNumber += 1
            default:
                // An empty line inside a hunk is a context line whose single
                // leading space git omitted — some tools produce that, and
                // dropping it would silently shift every number below it.
                if line.isEmpty {
                    hunk?.lines.append(DiffLine(
                        kind: .context, text: "",
                        oldNumber: oldNumber, newNumber: newNumber, id: position
                    ))
                    oldNumber += 1
                    newNumber += 1
                }
            }
        }

        close()
        return diff
    }

    /// Reads the two starting line numbers out of `@@ -12,7 +12,9 @@`.
    static func hunkStart(in header: String) -> (old: Int, new: Int) {
        let range = hunkRange(in: header)
        return (range.old.start, range.new.start)
    }

    /// Both sides of the header, with their lengths.
    ///
    /// A missing count means one line — `@@ -1 +1 @@` — which is the form git
    /// uses often enough that reading it as zero puts every gap out.
    static func hunkRange(in header: String) -> (old: (start: Int, count: Int), new: (start: Int, count: Int)) {
        var old = (start: 1, count: 1)
        var new = (start: 1, count: 1)
        for field in header.split(separator: " ") {
            guard let sign = field.first, sign == "-" || sign == "+" else { continue }
            let parts = field.dropFirst().split(separator: ",")
            let start = Int(parts.first ?? "") ?? 1
            let count = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
            if sign == "-" { old = (start, count) } else { new = (start, count) }
        }
        return (old, new)
    }
}
