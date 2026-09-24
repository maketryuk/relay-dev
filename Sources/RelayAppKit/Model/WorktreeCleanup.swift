import Foundation
import RelayProtocol

/// What an agent in a worktree is in the middle of, which is what makes
/// removing the worktree under it a mistake rather than a tidy-up.
enum WorktreeAgentActivity: Equatable, Sendable {
    case none
    case working
    case waiting

    /// Of the statuses of the agents in one worktree. A plain terminal is left
    /// out by the caller: what it prints is not a sign that anyone is in the
    /// middle of anything.
    init(_ statuses: some Sequence<RuntimeStatus>) {
        let statuses = Array(statuses)
        if statuses.contains(.waiting) {
            self = .waiting
        } else if statuses.contains(where: { $0 == .working || $0 == .starting }) {
            self = .working
        } else {
            self = .none
        }
    }
}

/// What git and the disk say about one worktree. Read off the main thread.
struct WorktreeDiskFacts: Equatable, Sendable {
    /// Files git reports as changed, staged or untracked.
    var uncommittedFiles: Int
    /// Commits that neither a remote nor the base has; nil when the repository
    /// has no remote, where "not pushed" describes every commit it holds.
    var unpushedCommits: Int?
    /// Commits reached by nothing but this worktree's detached `HEAD` — no
    /// branch, tag or remote. Always zero on a branch, which outlives its
    /// worktree.
    var strandedCommits: Int = 0
    var integration: BranchIntegration
    /// What the integration was measured against.
    var base: String?
    var lastActivity: Date?
}

enum WorktreeFactsReading: Equatable, Sendable {
    case reading
    case read(WorktreeDiskFacts)
    /// Git could not say, in its own words.
    case unreadable(String)
}

/// One row of the cleanup window: a worktree that may be removed, with what
/// was read about it and what is running in it.
struct WorktreeCleanupCandidate: Identifiable, Equatable, Sendable {
    var worktree: GitWorktree
    var reading: WorktreeFactsReading
    /// Sessions removing it would close.
    var sessions: Int
    var agent: WorktreeAgentActivity
    /// The newest output from a session in it.
    var sessionActivity: Date?

    var id: String { worktree.path }

    var facts: WorktreeDiskFacts? {
        guard case let .read(facts) = reading else { return nil }
        return facts
    }

    /// The newer of what the disk remembers and what a session printed: an
    /// agent thinking for an hour in a terminal has touched nothing git sees.
    var lastActivity: Date? {
        [facts?.lastActivity, sessionActivity].compactMap { $0 }.max()
    }
}

/// Why a row cannot be picked. Most pressing first, which is the order the
/// row lists them in.
enum WorktreeCleanupBlocker: Equatable, Sendable {
    case reading
    case unreadable(String)
    /// Git refuses a locked worktree, and the lock is somebody saying not to.
    case locked
    case agentWaiting
    case agentWorking
    /// Removing the worktree is removing the last thing that reaches them.
    case strandedCommits(Int)
    /// Lifted only by agreeing to discard exactly these.
    case uncommittedChanges(Int)
}

/// What narrows the list. Each is off until chosen, so a window opened with
/// nothing chosen shows every worktree there is.
struct WorktreeCleanupFilter: Equatable, Sendable {
    /// Merged into the base, or squashed or rebased into it.
    var integrated = false
    /// Nothing uncommitted.
    var clean = false
    var idle = false
    var idleDays = 14

    /// None of them is one: Russian says "более 1 дня" but "более 3 дней",
    /// and a list without a one needs no plural rules to say them all.
    static let idleChoices = [3, 7, 14, 30, 90]
}

/// What happened to one row of a removal.
struct WorktreeCleanupOutcome: Equatable, Sendable {
    var name: String
    var branch: String?
    /// Why it was not removed; nil when it was.
    var failure: String?
    var branchOutcome: GitWorktreeActions.BranchOutcome = .untouched
}

/// What a removal of several worktrees has to say once it is over.
struct WorktreeCleanupSummary: Equatable, Sendable {
    struct Failure: Equatable, Sendable {
        var name: String
        var message: String
    }

    var attempted: Int
    var removed: Int
    /// Branches Relay made and kept, because they hold work merged nowhere.
    var keptBranches: [String]
    var failures: [Failure]
}

/// The decisions the cleanup window makes, kept apart from reading git and
/// from drawing so they can be tested on facts made up for the purpose.
enum WorktreeCleanup {
    /// How long a worktree has to have been left alone before it is picked
    /// without being asked. "Merged" is also what a worktree started a minute
    /// ago is: a branch with nothing on it yet has all of it in the base.
    static let quietPeriod: TimeInterval = 24 * 60 * 60

    /// Unpushed commits are not here, and that is deliberate. Removing a
    /// worktree deletes its folder, not its commits: a branch goes with it only
    /// when Relay made it and git agrees everything on it is merged, so work
    /// that is on a branch and nowhere else survives on that branch. The row
    /// says so rather than refusing. What does not survive is a detached
    /// `HEAD`'s commits that no ref reaches, and uncommitted files — those
    /// block.
    static func blockers(
        of candidate: WorktreeCleanupCandidate,
        discardConsent: Int? = nil
    ) -> [WorktreeCleanupBlocker] {
        var blockers: [WorktreeCleanupBlocker] = []
        switch candidate.reading {
        case .reading: blockers.append(.reading)
        case let .unreadable(message): blockers.append(.unreadable(message))
        case .read: break
        }
        if candidate.worktree.isLocked { blockers.append(.locked) }
        switch candidate.agent {
        case .waiting: blockers.append(.agentWaiting)
        case .working: blockers.append(.agentWorking)
        case .none: break
        }
        if let facts = candidate.facts {
            if facts.strandedCommits > 0 { blockers.append(.strandedCommits(facts.strandedCommits)) }
            if facts.uncommittedFiles > 0, discardConsent != facts.uncommittedFiles {
                blockers.append(.uncommittedChanges(facts.uncommittedFiles))
            }
        }
        return blockers
    }

    static func canPick(_ candidate: WorktreeCleanupCandidate, discardConsent: Int? = nil) -> Bool {
        blockers(of: candidate, discardConsent: discardConsent).isEmpty
    }

    /// Whether removing it throws uncommitted files away. Only ever with
    /// consent to that very number of them.
    static func discardsChanges(_ candidate: WorktreeCleanupCandidate, discardConsent: Int?) -> Bool {
        guard let files = candidate.facts?.uncommittedFiles, files > 0 else { return false }
        return discardConsent == files
    }

    /// Whether it has work on it that no remote has and the base does not
    /// either: not a reason to keep the folder, but the reason its branch
    /// will be.
    static func unpushedWork(of candidate: WorktreeCleanupCandidate) -> Int? {
        guard let facts = candidate.facts, !facts.integration.isIntegrated,
              let unpushed = facts.unpushedCommits, unpushed > 0 else { return nil }
        return unpushed
    }

    static func matches(_ candidate: WorktreeCleanupCandidate, _ filter: WorktreeCleanupFilter, now: Date) -> Bool {
        if filter.integrated, candidate.facts?.integration.isIntegrated != true { return false }
        if filter.clean, candidate.facts?.uncommittedFiles != 0 { return false }
        if filter.idle {
            // Nothing known is not evidence of nothing done.
            guard let last = candidate.lastActivity else { return false }
            if now.timeIntervalSince(last) < TimeInterval(filter.idleDays) * 24 * 60 * 60 { return false }
        }
        return true
    }

    static func shown(
        _ candidates: [WorktreeCleanupCandidate],
        filter: WorktreeCleanupFilter,
        now: Date
    ) -> [WorktreeCleanupCandidate] {
        candidates.filter { matches($0, filter, now: now) }
    }

    /// What is picked before anyone has picked anything: finished, clean and
    /// left alone — merged, nothing uncommitted, nothing running, quiet for a
    /// day. Everything else is one click away, and none of it is a guess.
    static func isSuggested(_ candidate: WorktreeCleanupCandidate, now: Date) -> Bool {
        guard canPick(candidate), let facts = candidate.facts,
              facts.integration.isIntegrated, facts.uncommittedFiles == 0,
              candidate.sessions == 0,
              let last = candidate.lastActivity else { return false }
        return now.timeIntervalSince(last) >= quietPeriod
    }

    static func suggestions(among candidates: [WorktreeCleanupCandidate], now: Date) -> Set<String> {
        Set(candidates.filter { isSuggested($0, now: now) }.map(\.id))
    }

    /// What a press of Remove removes: picked, pickable, and on screen. A row
    /// hidden by a filter is never removed on the strength of having been
    /// picked before it was hidden.
    static func removable(
        _ shown: [WorktreeCleanupCandidate],
        selection: Set<String>,
        discardConsent: [String: Int]
    ) -> [WorktreeCleanupCandidate] {
        shown.filter { selection.contains($0.id) && canPick($0, discardConsent: discardConsent[$0.id]) }
    }

    static func summary(of outcomes: [WorktreeCleanupOutcome]) -> WorktreeCleanupSummary {
        WorktreeCleanupSummary(
            attempted: outcomes.count,
            removed: outcomes.filter { $0.failure == nil }.count,
            keptBranches: outcomes.compactMap { outcome in
                outcome.failure == nil && outcome.branchOutcome == .keptUnmerged ? outcome.branch : nil
            },
            failures: outcomes.compactMap { outcome in
                outcome.failure.map { WorktreeCleanupSummary.Failure(name: outcome.name, message: $0) }
            }
        )
    }
}

/// What one project's cleanup window has read and been told.
///
/// Kept on the model rather than in the window, so a removal that is still
/// going when the window is closed has somewhere to report to, and opening it
/// again shows how far it has got.
struct WorktreeCleanupState: Equatable {
    var readings: [String: WorktreeFactsReading] = [:]
    var selection: Set<String> = []
    /// Until the person picks or unpicks a row, rows are picked for them as
    /// they are read; after that, nothing is picked that they did not pick.
    var hasChosen = false
    /// How many uncommitted files the person agreed to lose, per worktree.
    var discardConsent: [String: Int] = [:]
    var filter = WorktreeCleanupFilter()
    var isReading = false
    var progress: WorktreeCleanupProgress?
    /// Why each row was not removed the last time, in git's words.
    var failures: [String: String] = [:]

    mutating func record(_ reading: WorktreeFactsReading, for path: String) {
        // Agreeing to lose three files is not agreeing to lose four: a
        // different count is different work, and has to be agreed to again.
        if let consent = discardConsent[path], case let .read(facts) = reading, facts.uncommittedFiles != consent {
            discardConsent.removeValue(forKey: path)
        }
        readings[path] = reading
    }

    mutating func suggest(among candidates: [WorktreeCleanupCandidate], now: Date) {
        guard !hasChosen else { return }
        selection = WorktreeCleanup.suggestions(among: candidates, now: now)
    }

    mutating func toggle(_ path: String) {
        hasChosen = true
        if selection.contains(path) {
            selection.remove(path)
        } else {
            selection.insert(path)
        }
    }

    mutating func select(_ paths: Set<String>) {
        hasChosen = true
        selection = paths
    }

    /// Agreeing to discard is choosing the row: nobody agrees to lose files in
    /// a worktree they did not mean to remove.
    mutating func consentToDiscard(_ candidate: WorktreeCleanupCandidate) {
        guard let files = candidate.facts?.uncommittedFiles, files > 0 else { return }
        hasChosen = true
        discardConsent[candidate.id] = files
        selection.insert(candidate.id)
    }

    mutating func withdrawConsent(from path: String) {
        hasChosen = true
        discardConsent.removeValue(forKey: path)
        selection.remove(path)
    }

    /// Takes what a removal did into the rows it was about.
    mutating func settle(_ path: String, with outcome: WorktreeCleanupOutcome) {
        if let failure = outcome.failure {
            failures[path] = failure
        } else {
            failures.removeValue(forKey: path)
            readings.removeValue(forKey: path)
            selection.remove(path)
            discardConsent.removeValue(forKey: path)
        }
    }
}

struct WorktreeCleanupProgress: Equatable {
    var total: Int
    var finished = 0
    /// The worktree being removed right now, by path.
    var current: String?
}
