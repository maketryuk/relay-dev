import Foundation
import RelayProtocol

/// One checkout of a repository, as `git worktree list` reports it.
///
/// Read from git every time rather than remembered: a worktree made by hand,
/// by `claude --worktree` or by `codex --worktree` is as real as one Relay
/// made, and one removed from a terminal is gone however Relay feels about it.
struct GitWorktree: Equatable, Hashable, Identifiable, Sendable {
    var path: String
    /// Short name; nil when `HEAD` is detached.
    var branch: String?
    var head: String?
    /// The checkout the repository lives in. Git keeps the shared history
    /// there, so it is the one that can never be removed.
    var isMain: Bool
    var isLocked: Bool
    /// Still registered, but the directory is gone.
    var isPrunable: Bool

    var id: String { path }

    /// What the worktree is called on screen: the branch, which is what the
    /// work is about, or the folder when there is no branch to name it by.
    var name: String {
        branch ?? URL(fileURLWithPath: path).lastPathComponent
    }
}

/// Pure parser for `git worktree list --porcelain`, kept apart from running
/// git so it can be tested against captured output.
enum GitWorktreeParser {
    static func parse(porcelain output: String) -> [GitWorktree] {
        var worktrees: [GitWorktree] = []
        var current: GitWorktree?
        var isBare = false
        var entries = 0

        func finish() {
            // A bare repository has no files to work in.
            if let current, !isBare { worktrees.append(current) }
            current = nil
            isBare = false
        }

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") {
                finish()
                entries += 1
                current = GitWorktree(
                    path: String(line.dropFirst("worktree ".count)),
                    branch: nil,
                    head: nil,
                    // Git lists the main worktree first; when that is a bare
                    // repository, none of the others is main.
                    isMain: entries == 1,
                    isLocked: false,
                    isPrunable: false
                )
            } else if line.hasPrefix("HEAD ") {
                current?.head = String(line.dropFirst("HEAD ".count))
            } else if line.hasPrefix("branch ") {
                let reference = line.dropFirst("branch ".count)
                current?.branch = reference.hasPrefix("refs/heads/")
                    ? String(reference.dropFirst("refs/heads/".count))
                    : String(reference)
            } else if line == "bare" {
                isBare = true
            } else if line == "locked" || line.hasPrefix("locked ") {
                current?.isLocked = true
            } else if line == "prunable" || line.hasPrefix("prunable ") {
                current?.isPrunable = true
            }
        }
        finish()
        return worktrees
    }
}

/// Which worktree a session belongs to, and the sidebar's grouping by it.
///
/// Decided by the directory the session was started in, which the daemon
/// already reports. That keeps worktrees out of the protocol entirely: nothing
/// the daemon stores or sends had to change for a session to know where it is.
enum WorktreeMembership {
    /// The deepest worktree containing the directory. Deepest, because one
    /// worktree can sit inside another's folder — Claude Code keeps its own in
    /// `.claude/worktrees` — and the session is in the inner one.
    ///
    /// Git reports where a worktree really is, and a project added through a
    /// symlink starts its sessions somewhere spelled differently; the
    /// directory is resolved only when it matches nothing as it is, which
    /// spares a look at the disk for every session Relay started in a
    /// worktree git named.
    static func worktree(containing directory: String, among worktrees: [GitWorktree]) -> GitWorktree? {
        func deepest(_ path: String) -> GitWorktree? {
            worktrees
                .filter { DirectoryContainment.contains(path, in: $0.path) }
                .max { $0.path.count < $1.path.count }
        }
        if let match = deepest(directory) { return match }
        let resolved = canonical(directory)
        return resolved == directory ? nil : deepest(resolved)
    }

    /// The path with its symlinks followed, which is how git reports a
    /// worktree. `URL.resolvingSymlinksInPath` will not do: it takes
    /// `/private` back off, and git keeps it. A path that does not exist is
    /// returned as it is.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The project's own checkout first, then the rest in git's order, each
    /// with the sessions started in it.
    ///
    /// A session whose directory is in none of them — a worktree removed
    /// behind Relay's back, a terminal started somewhere else — is listed with
    /// the project's own checkout rather than dropped from the sidebar.
    static func groups(
        of sessions: [SessionSnapshot],
        among worktrees: [GitWorktree],
        home: String
    ) -> [WorktreeGroup] {
        let listed = worktrees.filter { !$0.isPrunable }
        // Some group has to take the sessions that are in none: dropping them
        // would hide a running process with no way back to it.
        let homeWorktree = worktree(containing: home, among: listed)
            ?? listed.first(where: \.isMain)
            ?? listed.first
        let ordered = (homeWorktree.map { [$0] } ?? []) + listed.filter { $0 != homeWorktree }

        var groups = ordered.map { WorktreeGroup(worktree: $0, sessions: []) }
        for session in sessions {
            let owner = worktree(containing: session.workingDirectory, among: listed) ?? homeWorktree
            guard let index = groups.firstIndex(where: { $0.worktree == owner }) else { continue }
            groups[index].sessions.append(session)
        }
        return groups
    }
}

struct WorktreeGroup: Identifiable, Equatable {
    var worktree: GitWorktree
    var sessions: [SessionSnapshot]

    var id: String { worktree.path }
}

/// What a worktree Relay creates is called, and where it goes.
enum WorktreeNaming {
    /// Turns what was typed into something git accepts as a branch name.
    ///
    /// Only what git refuses is taken out. Letters in any alphabet, dots and
    /// slashes are kept, so `fix/логин` stays what the person meant; the rules
    /// are `git check-ref-format`'s, and git has the last word when the
    /// branch is made.
    static func branchName(from typed: String) -> String {
        let forbidden = Set<Character>(["~", "^", ":", "?", "*", "[", "\\", "\u{7F}"])
        var name = ""
        var previous: Character?
        for character in typed.trimmingCharacters(in: .whitespacesAndNewlines) {
            let replaced: Character
            if character.isWhitespace {
                replaced = "-"
            } else if forbidden.contains(character) || character.unicodeScalars.contains(where: {
                $0.properties.generalCategory == .control
            }) {
                continue
            } else {
                replaced = character
            }
            // Runs collapse: `a  b` is `a-b`, and git refuses `a//b` and `a..b`.
            if replaced == previous, replaced == "-" || replaced == "/" || replaced == "." { continue }
            name.append(replaced)
            previous = replaced
        }
        name = name.replacingOccurrences(of: "@{", with: "@")

        let trimmable = CharacterSet(charactersIn: "-./")
        while true {
            let before = name
            name = name.trimmingCharacters(in: trimmable)
            if name.hasSuffix(".lock") { name.removeLast(".lock".count) }
            if name == before { break }
        }
        return name == "@" ? "" : name
    }

    /// `~/.relay/worktrees/<repository>/<branch>`, with a number added until
    /// the folder is free.
    ///
    /// Outside the repository rather than inside it, so the main checkout's
    /// file tree, search and TODO list never walk into a second copy of
    /// themselves; and under Relay's own directory rather than beside the
    /// repository, so a folder of projects does not fill up with siblings.
    /// A branch with a slash in it becomes one folder, not two.
    static func directory(
        for branch: String,
        repository: String,
        in base: URL,
        exists: (String) -> Bool
    ) -> String {
        let folder = branch.replacingOccurrences(of: "/", with: "-")
        let parent = base.appendingPathComponent(repository, isDirectory: true)
        var candidate = parent.appendingPathComponent(folder, isDirectory: true).path
        var suffix = 2
        while exists(candidate) {
            candidate = parent.appendingPathComponent("\(folder)-\(suffix)", isDirectory: true).path
            suffix += 1
        }
        return candidate
    }

    /// What the repository's worktrees are filed under: the name of the
    /// folder it lives in, which is what the person already calls it.
    static func repositoryName(mainWorktree path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

/// Creating and removing worktrees through the system `git`.
///
/// Each returns what git said when it refused, or nil. Never call from the
/// main thread.
enum GitWorktreeActions {
    static func list(at root: String) -> [GitWorktree]? {
        guard let output = Shell.run(
            GitWorkingCopyReader.executable,
            arguments: ["-C", root, "worktree", "list", "--porcelain"],
            timeout: 4
        ) else { return nil }
        return GitWorktreeParser.parse(porcelain: output)
    }

    /// Starts `branch` from `base` in a new folder, or opens it there when the
    /// branch already exists.
    ///
    /// `--no-track`, because a branch started from `origin/main` would
    /// otherwise follow it, and the first push would go to `main`.
    static func add(branch: String, from base: String?, at directory: String, in root: String) -> String? {
        if let refusal = GitActions.run(["check-ref-format", "--branch", branch], at: root) {
            return refusal
        }
        do {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: directory).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            return error.localizedDescription
        }
        if branchExists(branch, in: root) {
            return GitActions.run(["worktree", "add", directory, branch], at: root)
        }
        if let refusal = GitActions.run(
            ["worktree", "add", "--no-track", "-b", branch, directory] + (base.map { [$0] } ?? []),
            at: root
        ) {
            return refusal
        }
        // Remembered by the repository rather than by Relay, and forgotten by
        // git along with the branch.
        _ = GitActions.run(["config", "--local", createdMarker(for: branch), "true"], at: root)
        return nil
    }

    /// Whether Relay started the branch, which is what makes it Relay's to
    /// delete: a branch someone else made is theirs, merged or not.
    static func createdBranch(_ branch: String, in root: String) -> Bool {
        Shell.run(
            GitWorkingCopyReader.executable,
            arguments: ["-C", root, "config", "--local", "--get", createdMarker(for: branch)],
            timeout: 4
        )?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    private static func createdMarker(for branch: String) -> String {
        "branch.\(branch).relayCreated"
    }

    static func branchExists(_ branch: String, in root: String) -> Bool {
        Shell.run(
            GitWorkingCopyReader.executable,
            arguments: ["-C", root, "show-ref", "--verify", "--quiet", "refs/heads/\(branch)"],
            timeout: 4
        ) != nil
    }

    /// `force` is what throws away uncommitted work; without it git refuses a
    /// worktree that has any, which is the question the caller asked first.
    static func remove(_ worktree: GitWorktree, force: Bool, in root: String) -> String? {
        GitActions.run(["worktree", "remove"] + (force ? ["--force"] : []) + [worktree.path], at: root)
    }

    /// `-d` rather than `-D`: git deletes a branch only once what is on it is
    /// somewhere else, so work that was never merged is kept rather than lost.
    /// Returns whether it went.
    static func deleteBranchIfMerged(_ branch: String, in root: String) -> Bool {
        GitActions.run(["branch", "-d", branch], at: root) == nil
    }

    /// What removing a worktree does to its branch.
    enum BranchOutcome: Equatable, Sendable {
        /// Relay made it and its work was merged, squashed or rebased in.
        case deleted
        /// Relay made it, and it has work that exists nowhere else.
        case keptUnmerged
        /// Somebody else's branch, one still checked out in another
        /// worktree, or no branch at all.
        case untouched
    }

    /// `settleBranch`, for a caller that only wants to know what became of it.
    static func removeBranch(of worktree: GitWorktree, in root: String) -> BranchOutcome {
        settleBranch(of: worktree, in: root).outcome
    }
}
