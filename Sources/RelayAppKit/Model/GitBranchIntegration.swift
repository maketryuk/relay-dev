import Foundation

/// How much of a branch's work has already reached another branch.
enum BranchIntegration: Equatable, Sendable {
    /// Every commit on it is reachable from the base.
    case merged
    /// Its commits are not in the base, but what they changed is: it was
    /// squashed or rebased in.
    case squashMerged
    /// It holds work the base does not have.
    case unmerged
    /// Git could not say: there is no base to compare with, or it failed.
    case unknown

    var isIntegrated: Bool { self == .merged || self == .squashMerged }
}

/// Whether a branch's work is already in the branch finished work goes to,
/// proved by git from commits and trees.
///
/// `git branch -d` asks whether the branch's commits are ancestors of HEAD,
/// and a forge that squashes or rebases a pull request lands the same changes
/// as commits of its own: the work is in, and git still calls the branch
/// unmerged. What is asked here is the question `-d` stands in for — would
/// anything be lost without the branch — and `.merged` and `.squashMerged`
/// are only ever answered with a proof, never read off a commit message or a
/// pull request's state.
///
/// Never call from the main thread.
enum GitBranchIntegration {
    /// What finished work in `root`'s repository is measured against, as a
    /// ref git accepts, or nil when there is nothing to measure against.
    ///
    /// The remote's default branch first — `origin/HEAD`, which `git clone`
    /// points at the branch pull requests land on — because that is where a
    /// merge made on the forge arrives, and it arrives with any fetch. The
    /// local `main` moves only when somebody pulls it, so a branch merged on
    /// the forge is in `origin/main` long before it is in `main`, and measuring
    /// against `main` would keep finished branches for as long as nobody
    /// pulls. A remote added with `git remote add` has no `origin/HEAD`, so
    /// its `main` and `master` are tried by name; a repository with no
    /// remote keeps its finished work in its own `main` or `master`.
    static func defaultBase(in root: String) -> String? {
        var candidates: [String] = []
        if let remote = preferredRemote(in: root) {
            if let head = output(["symbolic-ref", "--quiet", "refs/remotes/\(remote)/HEAD"], in: root) {
                candidates.append(head)
            }
            candidates += ["main", "master"].map { "refs/remotes/\(remote)/\($0)" }
        }
        candidates += ["refs/heads/main", "refs/heads/master"]
        return candidates.first { commit($0, in: root) != nil }
    }

    /// `branch` is a branch's name, or any commit git can name; `base` is a
    /// ref such as `defaultBase` gives.
    ///
    /// Both are read once and the rest is asked of the commits they named,
    /// so a branch that moves while it is being measured is measured as it
    /// was rather than as a mixture.
    static func integration(of branch: String, into base: String, in root: String) -> BranchIntegration {
        guard let tip = commit("refs/heads/\(branch)", in: root) ?? commit(branch, in: root),
              let target = commit(base, in: root)
        else { return .unknown }

        switch isAncestor(tip, of: target, in: root) {
        case true?: return .merged
        case nil: return .unknown
        case false?: break
        }

        // Merging the branch into the base changing nothing is the whole
        // proof: every change on it is there already, however it arrived —
        // squashed, rebased, cherry-picked, or written again by hand.
        let changesNothing = merge(target, tip, in: root).map { $0 == tree(of: target, in: root) }
        if changesNothing == true || containsSquash(of: tip, in: target, root: root) {
            return .squashMerged
        }
        // A git that cannot merge without a working tree (before 2.38) has
        // proved nothing either way.
        return changesNothing == nil ? .unknown : .unmerged
    }

    /// Brings a remote-tracking base up to date with its remote, and says
    /// whether that moved it.
    ///
    /// Removing a worktree is what usually follows merging its pull request,
    /// and until something fetches, that merge exists only on the forge.
    /// Only the base's own branch is fetched, without tags, and without
    /// stopping to ask for a password there is nobody to type: a remote that
    /// cannot be reached leaves the answer what it was.
    static func refresh(_ base: String, in root: String) -> Bool {
        let prefix = "refs/remotes/"
        guard base.hasPrefix(prefix) else { return false }
        let tracked = base.dropFirst(prefix.count)
        guard let remote = lines(output(["remote"], in: root))
            .filter({ tracked.hasPrefix($0 + "/") })
            .max(by: { $0.count < $1.count })
        else { return false }
        let branch = String(tracked.dropFirst(remote.count + 1))
        let before = commit(base, in: root)
        guard GitActions.run(
            ["-C", root, "fetch", "--no-tags", remote, branch],
            at: root,
            timeout: 30,
            interactive: false
        ) == nil else { return false }
        return commit(base, in: root) != before
    }

    /// The commit `revision` names, in full, or nil when it names none.
    static func commit(_ revision: String, in root: String) -> String? {
        // A revision that starts with a dash would be read as an option.
        guard !revision.hasPrefix("-") else { return nil }
        return output(["rev-parse", "--verify", "--quiet", "\(revision)^{commit}"], in: root)
    }

    // MARK: - Proofs

    /// How far back a squash is looked for, in commits on the base that
    /// touch what the branch touched, and how many of those that change
    /// exactly the same files are tried. Past either, the branch is kept:
    /// the answer is never a guess, and being slow to remove a worktree is
    /// the one other thing this may not be.
    private static let squashSearchDepth = 200
    private static let squashCandidates = 8

    /// Whether one commit on the base since the branch left it is the
    /// branch squashed.
    ///
    /// Merging into the base proves nothing once the base has changed the
    /// same lines again: the merge conflicts, though nothing on the branch
    /// is missing. Every pull request adding its line under the changelog's
    /// `Unreleased`, straight after the last one merged, does exactly that
    /// to the one before it. So the squash itself is found and checked where
    /// it landed: a commit on the base that changes the files the branch
    /// changes, and is what merging the branch into that commit's parent
    /// gives — which is how a forge makes a squash — or that merging the
    /// branch into changes nothing.
    private static func containsSquash(of tip: String, in target: String, root: String) -> Bool {
        guard let fork = output(["merge-base", target, tip], in: root),
              let diff = git(["diff", "--name-only", "-z", "--no-renames", "--no-color", fork, tip], in: root),
              diff.succeeded
        else { return false }
        let changed = Set(diff.output.split(separator: "\0").map(String.init))
        // The squash changes every one of these files, so the commits that
        // change any one of them are all that need reading.
        guard let probe = changed.min() else { return false }
        guard let log = git(
            [
                // One path given is what `log.follow` waits for, and following
                // a rename would list a file the branch never touched.
                "-c", "log.follow=false", "--literal-pathspecs",
                "log", "-z", "--no-merges", "--no-renames", "--no-color", "--no-show-signature",
                "--full-diff", "--name-only", "--format=%x01%H",
                "--max-count=\(squashSearchDepth)", "\(fork)..\(target)", "--", probe,
            ],
            in: root,
            timeout: 30
        ), log.succeeded else { return false }

        let candidates = changedFiles(log: log.output)
            .filter { $0.files == changed }
            .prefix(squashCandidates)
        return candidates.contains { candidate in
            guard let squashed = tree(of: candidate.commit, in: root) else { return false }
            return merge("\(candidate.commit)^", tip, in: root) == squashed
                || merge(candidate.commit, tip, in: root) == squashed
        }
    }

    /// Reads `git log -z --name-only --format=%x01%H`: each commit starts
    /// with a byte no path can hold, then its hash, then its files, the first
    /// of them after the newline git puts under the header.
    static func changedFiles(log: String) -> [(commit: String, files: Set<String>)] {
        log.split(separator: "\u{01}").compactMap { record in
            var fields = record.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard !fields.isEmpty else { return nil }
            let commit = fields.removeFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commit.isEmpty else { return nil }
            let files = fields.enumerated().map { index, field in
                index == 0 && field.hasPrefix("\n") ? String(field.dropFirst()) : field
            }
            return (commit, Set(files.filter { !$0.isEmpty }))
        }
    }

    /// Nil when git could not answer; exit status 1 is its "no".
    private static func isAncestor(_ commit: String, of target: String, in root: String) -> Bool? {
        guard let result = git(["merge-base", "--is-ancestor", commit, target], in: root) else { return nil }
        switch result.status {
        case 0: return true
        case 1: return false
        default: return nil
        }
    }

    /// The tree merging `theirs` into `ours` gives, without touching any
    /// checkout. A merge that conflicts has no tree worth comparing, and
    /// gives an empty one; nil when git could not merge at all.
    private static func merge(_ ours: String, _ theirs: String, in root: String) -> String? {
        guard let result = git(["merge-tree", "--write-tree", ours, theirs], in: root, timeout: 30) else {
            return nil
        }
        switch result.status {
        case 0:
            let tree = result.output.split(separator: "\n").first.map(String.init) ?? ""
            return tree.isEmpty ? nil : tree
        case 1: return ""
        default: return nil
        }
    }

    private static func tree(of commit: String, in root: String) -> String? {
        output(["rev-parse", "--verify", "--quiet", "\(commit)^{tree}"], in: root)
    }

    /// `origin`, or the one remote there is when it goes by another name.
    private static func preferredRemote(in root: String) -> String? {
        let remotes = lines(output(["remote"], in: root))
        if remotes.contains("origin") { return "origin" }
        return remotes.count == 1 ? remotes.first : nil
    }

    // MARK: - Running git

    private static func git(_ arguments: [String], in root: String, timeout: TimeInterval = 8) -> Shell.Result? {
        Shell.capture(GitWorkingCopyReader.executable, arguments: ["-C", root] + arguments, timeout: timeout)
    }

    /// What git printed when it succeeded, trimmed, or nil — for a question
    /// whose answer is one line.
    private static func output(_ arguments: [String], in root: String) -> String? {
        guard let result = git(arguments, in: root), result.succeeded else { return nil }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func lines(_ text: String?) -> [String] {
        (text ?? "").split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
