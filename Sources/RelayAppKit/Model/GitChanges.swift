import Foundation

/// What happened to one path, on one side of the index.
///
/// Git reports two letters per file — what the index has against the commit,
/// and what the working tree has against the index — and the pair is the whole
/// reason a file can be listed as both staged and not.
enum GitFileState: String, Equatable, Sendable {
    case unmodified
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case conflicted

    init(porcelainCode code: Character) {
        self = switch code {
        case "M", "T": .modified
        case "A": .added
        case "D": .deleted
        case "R": .renamed
        case "C": .copied
        case "U": .conflicted
        case "?": .untracked
        default: .unmodified
        }
    }

    /// The single letter shown in the list, as every other git interface writes
    /// it: recognisable at a glance and narrow enough to align.
    var letter: String {
        switch self {
        case .unmodified: " "
        case .modified: "M"
        case .added: "A"
        case .deleted: "D"
        case .renamed: "R"
        case .copied: "C"
        case .untracked: "?"
        case .conflicted: "!"
        }
    }
}

/// One changed path.
struct GitChange: Equatable, Sendable, Identifiable {
    var path: String
    /// Where a rename came from, which is the only way to read one.
    var originalPath: String?
    /// The index against `HEAD` — what a commit would carry.
    var index: GitFileState
    /// The working tree against the index — what a commit would leave behind.
    var worktree: GitFileState
    /// Lines added and removed against the last commit, both sides of the index
    /// together: the question a review asks is what changed since the commit,
    /// not which half of it has been staged.
    var insertions = 0
    var deletions = 0

    var id: String { path }

    var isConflicted: Bool { index == .conflicted || worktree == .conflicted }
    /// A conflict is neither: half of one cannot be committed, and offering to
    /// stage it is offering to lose the other half.
    var isStaged: Bool { !isConflicted && index != .unmodified && index != .untracked }
    var isUnstaged: Bool { !isConflicted && worktree != .unmodified }

    /// The last component, which is what a narrow list has room for.
    var name: String { (path as NSString).lastPathComponent }
    /// The rest of it, dimmed beside the name.
    var directory: String { (path as NSString).deletingLastPathComponent }
}

/// Everything `git status` has to say about the working copy.
struct GitWorkingCopy: Equatable, Sendable {
    var changes: [GitChange] = []

    /// A file edited, staged and then edited again belongs in both lists, which
    /// is exactly what the two states are for.
    var staged: [GitChange] { changes.filter(\.isStaged) }
    var unstaged: [GitChange] { changes.filter(\.isUnstaged) }
    var conflicted: [GitChange] { changes.filter(\.isConflicted) }

    var isEmpty: Bool { changes.isEmpty }
}

/// Reads `git diff --numstat -z`, which is how many lines each file moved by.
///
/// A separate call from the status, because porcelain v2 says which files
/// changed and nothing about how much — and a review that cannot see the size
/// of a change before opening it is a list of file names.
enum GitNumstatParser {
    static func parse(numstat output: String) -> [String: (insertions: Int, deletions: Int)] {
        var counts: [String: (insertions: Int, deletions: Int)] = [:]
        for record in output.split(separator: "\0", omittingEmptySubsequences: true) {
            let fields = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            // A binary file is reported as `-` on both sides rather than as a
            // count, which is git saying there is nothing to count.
            let path = String(fields[2])
            guard !path.isEmpty else { continue }
            counts[path] = (Int(fields[0]) ?? 0, Int(fields[1]) ?? 0)
        }
        return counts
    }
}

/// Reads `git status --porcelain=v2 -z`.
///
/// `-z` rather than newline-separated output, because a path may contain a
/// newline; git then quotes it in the plain format and the quoting has to be
/// undone, which is a second parser to get wrong.
enum GitStatusParser {
    static func parse(porcelainV2 output: String) -> GitWorkingCopy {
        // Trailing NUL leaves an empty final record.
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [GitChange] = []

        var index = 0
        while index < records.count {
            let record = records[index]
            index += 1
            guard let kind = record.first else { continue }

            switch kind {
            case "#":
                continue
            case "?":
                changes.append(GitChange(
                    path: String(record.dropFirst(2)),
                    originalPath: nil,
                    index: .unmodified,
                    worktree: .untracked
                ))
            case "1", "2", "u":
                // How many fields stand between the record's kind and its path,
                // which differs per kind: a rename carries a similarity score
                // and an unmerged entry carries three modes and three hashes.
                // Splitting on the wrong count leaves those fields glued to the
                // front of the path, which then matches no file on disk.
                let fieldsBeforePath = switch kind {
                case "1": 8
                case "2": 9
                default: 10
                }
                let fields = record.split(
                    separator: " ",
                    maxSplits: fieldsBeforePath,
                    omittingEmptySubsequences: false
                )
                guard fields.count > fieldsBeforePath, fields[1].count >= 2 else { continue }
                let codes = Array(fields[1])
                // A rename's source is a record of its own, immediately after.
                var original: String?
                if kind == "2", index < records.count {
                    original = records[index]
                    index += 1
                }
                let path = String(fields[fieldsBeforePath])
                changes.append(GitChange(
                    path: path,
                    originalPath: original,
                    index: kind == "u" ? .conflicted : GitFileState(porcelainCode: codes[0]),
                    worktree: kind == "u" ? .conflicted : GitFileState(porcelainCode: codes[1])
                ))
            default:
                // `!` is an ignored file, which is only listed when asked for.
                continue
            }
        }

        return GitWorkingCopy(changes: changes)
    }

    /// A rename record's path field is the destination; for type 2 the source
    /// follows in the next record, and the score (`R100`) sits in the field
    /// before the path. Only the destination is addressable by `git add`, which
    /// is why the source is kept for display alone.
    static func paths(in change: GitChange) -> String {
        guard let original = change.originalPath else { return change.path }
        return "\(original) → \(change.path)"
    }
}
