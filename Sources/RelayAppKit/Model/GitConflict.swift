import Foundation

/// Which side of a conflict is being kept.
enum GitConflictChoice: String, Equatable, Sendable {
    case ours
    case theirs
    /// Both, in the order the file has them.
    case both
}

/// One conflict in a file, as git left it between its markers.
///
/// The labels are git's own — `HEAD`, a commit's hash and subject — and are
/// shown rather than translated into "yours" and "theirs" on purpose. Which
/// side is which reverses between a merge and a rebase: rebasing replays your
/// commits onto theirs, so "ours" is the upstream and "theirs" is your own
/// work, and an interface that decides to call them mine and theirs is wrong
/// half the time.
struct GitConflictHunk: Equatable, Sendable, Identifiable {
    var id: Int
    var ourLabel: String
    var theirLabel: String
    var ours: [String]
    /// The common ancestor, when the file was written in `diff3` style.
    var base: [String]?
    var theirs: [String]

    func lines(for choice: GitConflictChoice) -> [String] {
        switch choice {
        case .ours: ours
        case .theirs: theirs
        case .both: ours + theirs
        }
    }
}

/// A file with conflict markers in it, split into what is settled and what is
/// not.
///
/// Parsing rather than shelling out to `git checkout --ours`: those replace a
/// whole file with one side, which is only ever the right answer when the file
/// has a single conflict in it. What a person wants is this hunk from here and
/// that one from there, and the markers already say where each is.
struct GitConflictFile: Equatable, Sendable {
    /// The file in order, with each conflict standing where it was found.
    enum Segment: Equatable, Sendable {
        case settled([String])
        case conflict(GitConflictHunk)
    }

    var segments: [Segment]

    var hunks: [GitConflictHunk] {
        segments.compactMap { segment in
            guard case let .conflict(hunk) = segment else { return nil }
            return hunk
        }
    }

    var hasConflicts: Bool { !hunks.isEmpty }

    static let ourMarker = "<<<<<<<"
    static let baseMarker = "|||||||"
    static let theirMarker = ">>>>>>>"
    static let separator = "======="

    /// Splits a file at its markers.
    ///
    /// A block that is never closed is left as ordinary text: a file that is
    /// half a conflict is more likely to be a file *about* conflict markers —
    /// this parser's own tests, for one — than a broken merge, and guessing
    /// would rewrite it.
    static func parse(_ contents: String) -> GitConflictFile {
        let lines = contents.components(separatedBy: "\n")
        var segments: [Segment] = []
        var settled: [String] = []
        var index = 0
        var nextID = 0

        while index < lines.count {
            let line = lines[index]
            guard line.hasPrefix(ourMarker) else {
                settled.append(line)
                index += 1
                continue
            }

            guard let hunk = parseHunk(lines, from: index, id: nextID) else {
                settled.append(line)
                index += 1
                continue
            }

            if !settled.isEmpty {
                segments.append(.settled(settled))
                settled = []
            }
            segments.append(.conflict(hunk.hunk))
            nextID += 1
            index = hunk.end
        }

        if !settled.isEmpty { segments.append(.settled(settled)) }
        return GitConflictFile(segments: segments)
    }

    private static func parseHunk(
        _ lines: [String],
        from start: Int,
        id: Int
    ) -> (hunk: GitConflictHunk, end: Int)? {
        var ours: [String] = []
        var base: [String]?
        var theirs: [String] = []
        var side = 0 // 0 ours, 1 base, 2 theirs
        var index = start + 1

        while index < lines.count {
            let line = lines[index]
            if line.hasPrefix(baseMarker) {
                base = []
                side = 1
            } else if line == separator || line.hasPrefix(separator) {
                side = 2
            } else if line.hasPrefix(theirMarker) {
                return (
                    GitConflictHunk(
                        id: id,
                        ourLabel: label(from: lines[start], marker: ourMarker),
                        theirLabel: label(from: line, marker: theirMarker),
                        ours: ours,
                        base: base,
                        theirs: theirs
                    ),
                    index + 1
                )
            } else {
                switch side {
                case 0: ours.append(line)
                case 1: base?.append(line)
                default: theirs.append(line)
                }
            }
            index += 1
        }
        return nil
    }

    private static func label(from line: String, marker: String) -> String {
        String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
    }

    /// The file as it would be written, with every conflict answered.
    ///
    /// A conflict with no answer keeps its markers, so a file that is half
    /// resolved is still a file git will not let anyone commit by accident.
    func resolved(with choices: [Int: GitConflictChoice]) -> String {
        var lines: [String] = []
        for segment in segments {
            switch segment {
            case let .settled(text):
                lines.append(contentsOf: text)
            case let .conflict(hunk):
                if let choice = choices[hunk.id] {
                    lines.append(contentsOf: hunk.lines(for: choice))
                } else {
                    lines.append("\(Self.ourMarker) \(hunk.ourLabel)")
                    lines.append(contentsOf: hunk.ours)
                    if let base = hunk.base {
                        lines.append("\(Self.baseMarker) base")
                        lines.append(contentsOf: base)
                    }
                    lines.append(Self.separator)
                    lines.append(contentsOf: hunk.theirs)
                    lines.append("\(Self.theirMarker) \(hunk.theirLabel)")
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// What the repository is in the middle of.
///
/// A conflict on its own says nothing about how to get out of it: the way out
/// of a rebase is `--continue`, the way out of a merge is a commit, and
/// offering the wrong one leaves the repository where it was.
struct GitMergeState: Equatable, Sendable {
    enum Operation: String, Equatable, Sendable {
        case rebase
        case merge
        case cherryPick
        case revert
    }

    var operation: Operation?

    var isInProgress: Bool { operation != nil }
}

enum GitMergeStateReader {
    /// Reads `.git` directly rather than asking git.
    ///
    /// This is checked on the same timer as the working copy, and four file
    /// lookups are worth having where a process spawn every few seconds is
    /// not.
    static func read(at root: String) -> GitMergeState {
        guard let directory = gitDirectory(at: root) else { return GitMergeState(operation: nil) }
        return classify(gitDirectory: directory) { path in
            FileManager.default.fileExists(atPath: path)
        }
    }

    /// The real `.git`, which in a worktree is a file pointing at it.
    static func gitDirectory(at root: String) -> String? {
        let candidate = (root as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory) else { return nil }
        guard !isDirectory.boolValue else { return candidate }

        guard let contents = try? String(contentsOfFile: candidate, encoding: .utf8) else { return nil }
        return pointedDirectory(inGitFile: contents, relativeTo: root)
    }

    /// `gitdir: /path/to/.git/worktrees/name`, absolute or relative to the
    /// working copy.
    static func pointedDirectory(inGitFile contents: String, relativeTo root: String) -> String? {
        for line in contents.split(separator: "\n") where line.hasPrefix("gitdir:") {
            let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty else { return nil }
            return path.hasPrefix("/") ? path : (root as NSString).appendingPathComponent(path)
        }
        return nil
    }

    /// Which operation the marker files in a git directory describe.
    static func classify(gitDirectory: String, exists: (String) -> Bool) -> GitMergeState {
        func has(_ name: String) -> Bool {
            exists((gitDirectory as NSString).appendingPathComponent(name))
        }
        // Rebase first: a rebase that stops on a conflict also leaves
        // `MERGE_MSG` behind, and answering "merge" there would offer a commit
        // where `--continue` is what finishes it.
        if has("rebase-merge") || has("rebase-apply") { return GitMergeState(operation: .rebase) }
        if has("MERGE_HEAD") { return GitMergeState(operation: .merge) }
        if has("CHERRY_PICK_HEAD") { return GitMergeState(operation: .cherryPick) }
        if has("REVERT_HEAD") { return GitMergeState(operation: .revert) }
        return GitMergeState(operation: nil)
    }
}
