import Foundation

/// A pull or a push, as it stands before it is run.
///
/// The panel edits one of these and the command line is derived from it, so
/// what is shown and what runs cannot disagree — the whole reason for asking
/// rather than doing is that the person can see which branch of which remote is
/// about to be written to.
struct GitTransfer: Equatable, Sendable {
    enum Direction: String, Identifiable, Sendable {
        case pull
        case push

        var id: String { rawValue }
    }

    /// The flags worth offering.
    ///
    /// The set git's own interfaces settle on, which is a reasonable answer to
    /// "what does someone actually reach for": the four ways a merge can be
    /// made to behave, the two ways a push can, and the hooks. Everything else
    /// git takes belongs in a terminal, which this app is full of.
    enum Option: String, CaseIterable, Identifiable, Sendable {
        /// Replay local commits on top of what came down, rather than merging.
        case rebase
        /// Refuse rather than create a merge commit.
        case fastForwardOnly
        /// Make a merge commit even where a fast-forward would do.
        case noFastForward
        /// Bring everything down as one commit.
        case squash
        /// Merge, and leave the result staged rather than committed.
        case noCommit
        /// Put the dirty tree aside for the duration and bring it back after.
        case autostash
        /// Overwrite the remote branch, but refuse if it moved since it was
        /// last fetched.
        case forceWithLease
        case tags
        /// Make the local branch follow what it is being pushed to.
        case setUpstream
        /// Skip the hooks that would otherwise run first.
        case noVerify

        var id: String { rawValue }

        /// Which commands the flag belongs to. `--no-verify` belongs to both,
        /// which is why this is a set rather than one direction.
        var directions: Set<Direction> {
            switch self {
            case .rebase, .fastForwardOnly, .noFastForward, .squash, .noCommit, .autostash: [.pull]
            case .forceWithLease, .tags, .setUpstream: [.push]
            case .noVerify: [.pull, .push]
            }
        }

        var flag: String {
            switch self {
            case .rebase: "--rebase"
            case .fastForwardOnly: "--ff-only"
            case .noFastForward: "--no-ff"
            case .squash: "--squash"
            case .noCommit: "--no-commit"
            case .autostash: "--autostash"
            case .forceWithLease: "--force-with-lease"
            case .tags: "--tags"
            case .setUpstream: "--set-upstream"
            case .noVerify: "--no-verify"
            }
        }

        /// What this one cannot be combined with, as git itself refuses them.
        ///
        /// Stated in both directions rather than derived, so the rule reads
        /// the same wherever it is asked from; `GitTransferTests` pins the
        /// symmetry that costs.
        var excludes: Set<Option> {
            switch self {
            case .rebase: [.fastForwardOnly, .noFastForward, .squash, .noCommit]
            case .fastForwardOnly: [.rebase, .noFastForward, .squash]
            case .noFastForward: [.rebase, .fastForwardOnly]
            case .squash: [.rebase, .fastForwardOnly]
            case .noCommit: [.rebase]
            case .autostash, .forceWithLease, .tags, .setUpstream, .noVerify: []
            }
        }

        var isDestructive: Bool { self == .forceWithLease }

        static func all(for direction: Direction) -> [Option] {
            allCases.filter { $0.directions.contains(direction) }
        }
    }

    var direction: Direction
    var remote: String
    /// The branch on the remote: pulled from, or pushed to.
    var branch: String
    /// The branch the commits come from. Not a choice — it is the branch you
    /// are on, which is what pushing means everywhere else.
    var localBranch: String
    var options: Set<Option>

    /// Turns an option on, dropping whatever it contradicts.
    mutating func set(_ option: Option, _ isOn: Bool) {
        if isOn {
            options.subtract(option.excludes)
            options.insert(option)
        } else {
            options.remove(option)
        }
    }

    /// Whether something already chosen rules this one out.
    ///
    /// Shown as unavailable rather than silently unticked when something else
    /// is chosen: `--squash` going grey the moment `--rebase` is ticked says
    /// which of them is in the way, and a box that quietly clears itself does
    /// not.
    func isAvailable(_ option: Option) -> Bool {
        !options.contains { $0 != option && $0.excludes.contains(option) }
    }

    var arguments: [String] {
        let flags = Option.all(for: direction).filter(options.contains).map(\.flag)
        switch direction {
        case .pull:
            return ["pull"] + flags + [remote, branch]
        case .push:
            // Spelled out only when the two names differ: `origin master` is
            // the same request as `origin master:master` and reads as what it
            // is, while `feature:main` says something worth seeing.
            let refspec = localBranch == branch ? branch : "\(localBranch):\(branch)"
            return ["push"] + flags + [remote, refspec]
        }
    }

    /// What the panel shows it is about to run.
    var commandLine: String {
        (["git"] + arguments).joined(separator: " ")
    }

    /// The ref the remote branch is named by locally, for working out what is
    /// about to be sent.
    var remoteRef: String { "\(remote)/\(branch)" }

    /// Whether there is a command here to run at all.
    ///
    /// A repository with no remote, and a `HEAD` that is not on a branch, are
    /// both states git would refuse from — and refusing here says so before
    /// the fact rather than as a failure afterwards.
    var isRunnable: Bool {
        !remote.isEmpty && !branch.isEmpty && !localBranch.isEmpty && !isDetached
    }

    /// Whether running this would send anything at all.
    ///
    /// Answered from the count of `remote..HEAD` rather than from how far
    /// ahead git says the branch is, because the two disagree exactly where it
    /// matters: after an amend or a rebase the counts can match while the
    /// commits are different objects, and only the log knows.
    ///
    /// `outgoing` is nil while that log is still being read, and then the
    /// answer is yes — a button that flickers from live to dead a moment after
    /// the panel opens is worse than a push that turns out to have been a
    /// no-op.
    func sends(outgoing: Int?, isNewBranch: Bool) -> Bool {
        guard direction == .push else { return true }
        // A branch the remote has never heard of is created by the push, and
        // `--tags` sends tags whether or not any commits go with them.
        if isNewBranch || options.contains(.tags) { return true }
        guard let outgoing else { return true }
        return outgoing > 0
    }

    /// `git status` names a detached head `(detached)`, and a branch name
    /// cannot contain a bracket.
    var isDetached: Bool { localBranch.hasPrefix("(") }

    /// Where the panel starts from.
    ///
    /// The upstream if the branch has one, since that is the answer the person
    /// means nine times in ten, and the first remote otherwise. A branch with
    /// no upstream is offered `--set-upstream`, because pushing it once and
    /// then having to say where it lives is the same request twice.
    static func initial(
        direction: Direction,
        status: GitStatus?,
        remotes: [String]
    ) -> GitTransfer {
        let local = status?.branch ?? ""
        let upstream = status?.upstream.flatMap(split(upstream:))
        // No fallback to `origin`: a repository that has no remote of that
        // name would show one that does not exist, and the panel would offer
        // to push to it.
        let remote = upstream?.remote.flatMap { name in remotes.contains(name) ? name : nil }
            ?? remotes.first
            ?? ""
        let branch = upstream?.branch ?? local

        var options: Set<Option> = []
        switch direction {
        case .pull:
            // `--autostash` as well as `--rebase`, because without it a pull
            // with anything uncommitted in the tree does not happen at all:
            // git refuses with "cannot pull with rebase: You have unstaged
            // changes", which is a refusal to do the thing that was asked for
            // on the grounds of something nobody was asked about. Every other
            // client stashes and puts it back; git can do it in one flag, and
            // it keeps the staged half staged.
            options = [.rebase, .autostash]
        case .push:
            if status?.upstream == nil { options = [.setUpstream] }
        }

        return GitTransfer(
            direction: direction,
            remote: remote,
            branch: branch,
            localBranch: local,
            options: options
        )
    }

    /// Splits `origin/feature/x` into its remote and its branch.
    ///
    /// The first component only: a branch name is allowed to contain slashes
    /// and a remote name is the part git matched before the first one.
    static func split(upstream: String) -> (remote: String?, branch: String)? {
        guard let slash = upstream.firstIndex(of: "/") else { return (nil, upstream) }
        let remote = String(upstream[upstream.startIndex ..< slash])
        let branch = String(upstream[upstream.index(after: slash)...])
        guard !remote.isEmpty, !branch.isEmpty else { return nil }
        return (remote, branch)
    }
}

/// One commit, as a list of what is about to be pushed needs it.
struct GitCommitSummary: Identifiable, Equatable, Sendable {
    var sha: String
    var subject: String

    var id: String { sha }
}

/// The remotes and the commits the transfer panel reads.
enum GitTransferReader {
    /// `git remote` in the order git lists them, which is alphabetical and
    /// therefore stable.
    static func remotes(at root: String) -> [String] {
        guard let output = Shell.run(
            GitWorkingCopyReader.executable,
            arguments: ["-C", root, "remote"],
            timeout: 4
        ) else { return [] }
        return parse(remotes: output)
    }

    static func parse(remotes output: String) -> [String] {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Enough of a list to see what is going out without reading a history.
    static let limit = 50

    /// The commits `HEAD` has that the remote branch does not.
    ///
    /// Nil when the remote ref is not known locally, which is the difference
    /// between "nothing to push" and "this branch does not exist there yet" —
    /// and the panel says which.
    static func outgoing(at root: String, against ref: String) -> [GitCommitSummary]? {
        guard let result = Shell.capture(
            GitWorkingCopyReader.executable,
            arguments: [
                "-C", root,
                "log", "--format=%h%x09%s", "--max-count=\(limit)", "\(ref)..HEAD",
            ],
            timeout: 8
        ), result.succeeded else { return nil }
        return parse(log: result.output)
    }

    static func parse(log output: String) -> [GitCommitSummary] {
        output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard let sha = fields.first, !sha.isEmpty else { return nil }
            return GitCommitSummary(
                sha: String(sha),
                subject: fields.count > 1 ? String(fields[1]) : ""
            )
        }
    }
}
