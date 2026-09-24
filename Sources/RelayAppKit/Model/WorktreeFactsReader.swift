import Foundation

/// Reads what the cleanup window needs to know about a worktree, through the
/// system `git`.
///
/// Never call from the main thread.
enum WorktreeFactsReader {
    /// What every worktree of one repository is measured against, read once
    /// for all of them rather than once per row.
    struct Repository: Equatable, Sendable {
        var root: String
        var base: String?
        var hasRemote: Bool
    }

    /// Where `HEAD` is and when it got there.
    struct Head: Equatable, Sendable {
        var hash: String
        var committed: Date
        /// When the reflog last recorded it moving; nil without a reflog.
        var moved: Date?
    }

    /// Enough of the uncommitted files for the newest of them to be the
    /// newest, without a stat per file of a checkout nobody ignored properly.
    static let statLimit = 200

    static func repository(at root: String) -> Repository {
        let remotes = Shell.run(
            GitWorkingCopyReader.executable,
            arguments: ["-C", root, "remote"],
            timeout: 4
        ) ?? ""
        return Repository(
            root: root,
            base: GitBranchIntegration.defaultBase(in: root),
            hasRemote: !remotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        )
    }

    static func facts(of worktree: GitWorktree, in repository: Repository) -> WorktreeFactsReading {
        do {
            return .read(try read(worktree, in: repository))
        } catch let failure as GitFailure {
            return .unreadable(failure.message)
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    private static func read(_ worktree: GitWorktree, in repository: Repository) throws -> WorktreeDiskFacts {
        // A worktree whose folder is gone has nothing uncommitted left to
        // lose, and nothing to run git in: what can still be asked is about
        // its commits, from the repository, by the hash git last listed.
        let place = worktree.isPrunable ? repository.root : worktree.path
        var tip: String?
        if worktree.isPrunable {
            guard let listed = worktree.head else { throw GitFailure(message: "git lists no HEAD for it") }
            tip = listed
        }
        // `--no-optional-locks`, so that looking does not rewrite the index
        // and leave the worktree seeming touched a moment ago.
        let changes: [GitChange] = try worktree.isPrunable ? [] : GitStatusParser.parse(
            porcelainV2: capture(["--no-optional-locks", "-C", place, "status", "--porcelain=v2", "-z"])
        ).changes
        let head = try readHead(at: place, tip: tip)

        // The base too, when it is a local branch: a commit merged into `main`
        // and not pushed yet is not this branch's to lose.
        let unpushed: Int? = try repository.hasRemote
            ? count([head.hash, "--not", "--remotes"] + (repository.base.map { [$0] } ?? []), at: place)
            : nil
        let stranded: Int = try worktree.branch == nil
            ? count([head.hash, "--not", "--branches", "--tags", "--remotes"], at: place)
            : 0
        let integration = repository.base.map {
            GitBranchIntegration.integration(of: worktree.branch ?? head.hash, into: $0, in: repository.root)
        } ?? .unknown

        return WorktreeDiskFacts(
            uncommittedFiles: changes.count,
            unpushedCommits: unpushed,
            strandedCommits: stranded,
            integration: integration,
            base: repository.base,
            lastActivity: lastActivity(of: head, changes: changes, in: worktree.path)
        )
    }

    /// The newest of: when `HEAD` last moved in this worktree, when its commit
    /// was made, and when an uncommitted file was last written.
    ///
    /// Each of these moves only when somebody did something. What is left out
    /// moves on its own: the index is rewritten by `git status`, which Relay
    /// runs on every worktree every few seconds, and a folder's own date
    /// changes whenever Finder or Spotlight leaves a file in it. Output from a
    /// session is the model's to add, since it was the daemon that saw it.
    static func lastActivity(of head: Head, changes: [GitChange], in directory: String) -> Date {
        let written = changes.prefix(statLimit).compactMap { change -> Date? in
            let path = (directory as NSString).appendingPathComponent(change.path)
            return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
        return ([head.committed] + [head.moved].compactMap { $0 } + written).max() ?? head.committed
    }

    /// From the reflog, which records a checkout, a commit and a reset alike,
    /// and so says when a worktree was made even when nothing has been
    /// committed in it since.
    ///
    /// `tip` names the commit when there is no worktree left to ask about its
    /// own `HEAD`, and so no reflog of it either.
    private static func readHead(at place: String, tip: String?) throws -> Head {
        if tip == nil,
           let reflog = try? capture(["-C", place, "log", "-g", "-1", "--date=unix", "--format=%gd %ct %H"]),
           let head = parseReflogEntry(reflog) {
            return head
        }
        // An expired reflog is an empty one, and says nothing about the commit.
        let fields = try capture(["-C", place, "log", "-1", "--format=%ct %H", tip ?? "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
        guard fields.count == 2, let seconds = TimeInterval(fields[0]) else {
            throw GitFailure(message: "git could not read HEAD")
        }
        return Head(hash: String(fields[1]), committed: Date(timeIntervalSince1970: seconds), moved: nil)
    }

    /// Reads `HEAD@{1790277874} 1790277443 <hash>`: when the entry was
    /// written, then the date and hash of the commit it moved to.
    static func parseReflogEntry(_ line: String) -> Head? {
        let fields = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard fields.count == 3,
              let open = fields[0].firstIndex(of: "{"),
              let close = fields[0].lastIndex(of: "}"),
              open < close,
              let moved = TimeInterval(fields[0][fields[0].index(after: open) ..< close]),
              let committed = TimeInterval(fields[1]) else { return nil }
        return Head(
            hash: String(fields[2]),
            committed: Date(timeIntervalSince1970: committed),
            moved: Date(timeIntervalSince1970: moved)
        )
    }

    private static func count(_ revisions: [String], at place: String) throws -> Int {
        let output = try capture(["-C", place, "rev-list", "--count"] + revisions)
        guard let value = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw GitFailure(message: "git could not count commits")
        }
        return value
    }

    /// What git printed, or why it printed nothing, in its words.
    private static func capture(_ arguments: [String]) throws -> String {
        guard let result = Shell.capture(GitWorkingCopyReader.executable, arguments: arguments, timeout: 8) else {
            throw GitFailure(message: "git did not answer")
        }
        guard result.succeeded else {
            throw GitFailure(message: result.error.isEmpty ? "git exited with \(result.status)" : result.error)
        }
        return result.output
    }

    private struct GitFailure: Error {
        var message: String
    }
}
