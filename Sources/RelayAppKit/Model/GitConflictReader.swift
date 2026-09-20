import Foundation

/// Reads a conflicted file as the three versions of itself it really is.
///
/// From the index rather than from the working copy, and merged again here
/// rather than taken as git left it. Two reasons, both about the ancestor:
///
/// - Unless the repository is set to `merge.conflictStyle = diff3`, the markers
///   git writes say what each side has and not what both had before — and the
///   ancestor is exactly what the result pane shows while a conflict is
///   unanswered. Stages 1, 2 and 3 are in the index whatever the configuration
///   says, and nobody's settings need changing to read them.
/// - `git merge-file` also applies everything only one side changed, so what
///   comes back is a file where the only passages left are the ones that
///   genuinely need a person. git's own merge does that; approximating it with
///   a diff written here would be a second answer to a question already
///   answered correctly.
enum GitConflictReader {
    /// The file split three ways, or — if the index cannot say — as git left
    /// it in the working copy, ancestor unknown.
    static func read(_ path: String, at root: String) -> GitConflictFile? {
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        let contents = try? String(contentsOf: url, encoding: .utf8)
        if let merged = threeWay(path, at: root) {
            // Named from what git wrote in the working copy. Merging again
            // here puts our own labels in the markers, and the pane headers
            // want the commit being replayed, not the word "theirs".
            let named = contents.map { GitConflictFile.parse($0).hunks.first }
            return labelled(merged, like: named ?? nil)
        }
        guard let contents else { return nil }
        return GitConflictFile.parse(contents)
    }

    private static func labelled(_ file: GitConflictFile, like hunk: GitConflictHunk?) -> GitConflictFile {
        guard let hunk else { return file }
        var file = file
        file.segments = file.segments.map { segment in
            guard case var .conflict(conflict) = segment else { return segment }
            conflict.ourLabel = hunk.ourLabel
            conflict.theirLabel = hunk.theirLabel
            return .conflict(conflict)
        }
        return file
    }

    private static func threeWay(_ path: String, at root: String) -> GitConflictFile? {
        guard let directory = try? FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: root),
            create: true
        ) else { return nil }
        defer { try? FileManager.default.removeItem(at: directory) }

        var stages: [Int: URL] = [:]
        for stage in 1 ... 3 {
            let file = directory.appendingPathComponent("\(stage)")
            let shown = Shell.capture(
                GitWorkingCopyReader.executable,
                arguments: ["-C", root, "show", ":\(stage):\(path)"],
                timeout: 8
            )
            // An ancestor is allowed to be missing — a file both sides added
            // has none — but a side is not: without both there is nothing to
            // merge and the working copy is all there is to go on.
            guard let shown, shown.succeeded || stage == 1 else { return nil }
            let text = shown.succeeded ? shown.output : ""
            guard !text.contains("\0") else { return nil }
            guard (try? text.write(to: file, atomically: true, encoding: .utf8)) != nil else { return nil }
            stages[stage] = file
        }

        guard let ours = stages[2], let base = stages[1], let theirs = stages[3] else { return nil }
        // The labels are replaced because they go into the markers, and the
        // markers here are read back by our own parser: a temporary directory's
        // name has no business being one.
        guard let merged = Shell.capture(
            GitWorkingCopyReader.executable,
            arguments: [
                "merge-file", "-p", "--diff3",
                "-L", "ours", "-L", "base", "-L", "theirs",
                ours.path, base.path, theirs.path,
            ],
            timeout: 8
        ) else { return nil }
        // A positive status is the number of conflicts left, which is the
        // normal answer here; only a negative one means it could not be done.
        guard merged.status >= 0, !merged.output.contains("\0") else { return nil }

        return GitConflictFile.parse(merged.output)
    }
}
