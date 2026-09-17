import Foundation

/// Reads and changes the working copy through the system `git`.
///
/// Everything here spawns a process and blocks, so it belongs on a detached
/// task; the model calls it from one and keeps the result.
enum GitWorkingCopyReader {
    static let executable = "/usr/bin/git"

    /// A diff larger than this is not read. Somewhere above it a "diff" stops
    /// being something a person reads and becomes something that makes the
    /// window stop responding while it is laid out.
    static let diffSizeLimit = 1_500_000

    /// What the working copy holds, with the size of each change.
    static func changes(at root: String) -> GitWorkingCopy? {
        guard GitProbe.isRepository(at: root) else { return nil }
        guard let status = Shell.capture(
            executable,
            arguments: ["-C", root, "status", "--porcelain=v2", "-z"],
            timeout: 8
        ), status.succeeded else { return nil }

        var copy = GitStatusParser.parse(porcelainV2: status.output)

        // One call for every tracked file, rather than one per file: the
        // difference is a process per review instead of a process per row.
        let counts = Shell.capture(
            executable,
            arguments: ["-C", root, "diff", "HEAD", "--numstat", "-z"],
            timeout: 8
        ).map { GitNumstatParser.parse(numstat: $0.output) } ?? [:]

        copy.changes = copy.changes.map { change in
            var change = change
            if let count = counts[change.path] {
                change.insertions = count.insertions
                change.deletions = count.deletions
            } else if change.worktree == .untracked {
                // Nothing to diff it against, so the whole file is the addition.
                change.insertions = lineCount(of: root, path: change.path)
            }
            return change
        }
        return copy
    }

    /// A new file's length, which is how many lines it adds.
    private static func lineCount(of root: String, path: String) -> Int {
        let url = URL(fileURLWithPath: root).appendingPathComponent(path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= diffSizeLimit
        else { return 0 }
        return data.reduce(into: 0) { total, byte in
            if byte == 0x0A { total += 1 }
        }
    }

    /// Every branch worth switching to, local and remote in one call.
    static func branches(at root: String) -> [GitBranch] {
        guard let result = Shell.capture(
            executable,
            arguments: [
                "-C", root, "for-each-ref",
                "--format=" + GitBranchParser.format,
                "--sort=-committerdate",
                "refs/heads", "refs/remotes",
            ],
            timeout: 8
        ), result.succeeded else { return [] }
        return GitBranchParser.parse(result.output)
    }

    /// One file's diff against the last commit.
    ///
    /// Against `HEAD` rather than against the index, because the question being
    /// asked is what changed since the commit — whether half of it happens to
    /// be staged is a separate matter, and answering it here would show two
    /// half-diffs of one edit.
    ///
    /// `context` is how many unchanged lines git puts around each change; the
    /// panel asks for more of them when the reader wants to see further.
    static func diff(at root: String, change: GitChange, context: Int = 3) -> FileDiff? {
        let arguments: [String]
        if change.worktree == .untracked {
            arguments = ["-C", root, "diff", "--no-index", "-U\(context)", "--", "/dev/null", change.path]
        } else {
            arguments = ["-C", root, "diff", "HEAD", "-U\(context)", "--", change.path]
        }

        // `--no-index` exits 1 when the files differ, which is the only case
        // it is ever asked about, so the status is not what says it worked.
        guard let result = Shell.capture(executable, arguments: arguments, timeout: 20) else { return nil }
        guard result.output.count <= diffSizeLimit else {
            return FileDiff(hunks: [], isBinary: false, isTooLarge: true)
        }
        return DiffParser.parse(unified: result.output)
    }
}

/// What the Git panel can do to the repository.
///
/// Each returns the message git printed when it refused, and nothing when it
/// did as it was told — an action that silently does nothing is the one thing
/// none of these may be.
enum GitActions {
    static func stage(_ paths: [String], at root: String) -> String? {
        run(["-C", root, "add", "--"] + paths, at: root)
    }

    /// `reset` rather than `restore --staged`, which refuses a path git has
    /// never heard of — and a path that was staged a moment ago and is not any
    /// more is exactly that. Two quick clicks on "unstage all" would otherwise
    /// end in a wall of errors about files that are simply already unstaged.
    static func unstage(_ paths: [String], at root: String) -> String? {
        run(["-C", root, "reset", "-q", "--"] + paths, at: root)
    }

    /// Everything at once, said to git as "everything" rather than as a list of
    /// paths read from the screen a moment ago.
    static func stageAll(at root: String) -> String? {
        run(["-C", root, "add", "-A"], at: root)
    }

    static func unstageAll(at root: String) -> String? {
        run(["-C", root, "reset", "-q"], at: root)
    }

    /// Throws away what has not been committed.
    ///
    /// An untracked file has no earlier version to be restored to, so it is
    /// deleted outright — which is what every other git interface means by
    /// discarding one, and why the caller has to ask first.
    static func discard(_ change: GitChange, at root: String) -> String? {
        guard change.worktree != .untracked else {
            let url = URL(fileURLWithPath: root).appendingPathComponent(change.path)
            do {
                try FileManager.default.removeItem(at: url)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        // Both sides: a file staged and then edited again would otherwise keep
        // the staged half, which is not what "discard my changes" means.
        if let failure = run(["-C", root, "restore", "--staged", "--worktree", "--", change.path], at: root) {
            return failure
        }
        return nil
    }

    /// Moves to another branch, or starts one here.
    ///
    /// `switch` rather than `checkout`: it does one thing, and it refuses
    /// rather than silently discarding work when the change would overwrite an
    /// edit. The refusal is what the caller shows.
    static func switchTo(_ branch: String, creating: Bool = false, at root: String) -> String? {
        run(["-C", root, "switch"] + (creating ? ["-c", branch] : [branch]), at: root)
    }

    static func commit(message: String, at root: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return run(["-C", root, "commit", "-m", trimmed], at: root)
    }

    /// The commands that talk to the remote, which is why each is slower and
    /// each can fail in a way worth reading.
    ///
    /// Only the two that need nothing said about them. A pull and a push are
    /// asked about first — which remote, which branch, and whether the remote
    /// branch is to be overwritten — and `GitTransfer` is what that question
    /// produces.
    enum Remote: String, CaseIterable, Identifiable, Sendable {
        case push
        case fetch

        var id: String { rawValue }

        var title: String {
            switch self {
            case .push: "Push"
            case .fetch: "Fetch"
            }
        }

        var symbolName: String {
            switch self {
            case .push: "arrow.up"
            case .fetch: "arrow.triangle.2.circlepath"
            }
        }

        var arguments: [String] {
            switch self {
            case .push: ["push"]
            case .fetch: ["fetch", "--prune"]
            }
        }
    }

    static func run(_ remote: Remote, at root: String) -> String? {
        run(remote.arguments, at: root)
    }

    /// One command against the remote, spelled out by the caller.
    ///
    /// The timeout is long enough for a fetch over a slow link and short
    /// enough that a prompt for a password — which cannot be answered here —
    /// does not hang the panel forever.
    static func run(_ arguments: [String], at root: String) -> String? {
        run(["-C", root] + arguments, at: root, timeout: 120, interactive: false)
    }

    private static func run(
        _ arguments: [String],
        at root: String,
        timeout: TimeInterval = 20,
        interactive: Bool = true
    ) -> String? {
        var arguments = arguments
        if !interactive {
            // A remote that wants credentials must fail rather than wait: there
            // is no terminal here to type them into.
            arguments = ["-c", "core.askPass=", "-c", "credential.interactive=never"] + arguments
        }
        guard let result = Shell.capture(
            GitWorkingCopyReader.executable,
            arguments: arguments,
            timeout: timeout
        ) else {
            return "git did not answer"
        }
        guard !result.succeeded else { return nil }
        // git says why on stderr; when it says nothing, the exit code is all
        // there is to report.
        return result.error.isEmpty ? "git exited with \(result.status)" : result.error
    }
}
