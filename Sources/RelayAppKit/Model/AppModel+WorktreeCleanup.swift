import Foundation
import RelayProtocol
import RelayUI

/// The Clean Up Worktrees window: every worktree of a project that could be
/// removed, what stands in the way of each, and removing the chosen ones in
/// one go. Nothing here removes anything the person did not pick.
extension AppModel {
    /// Whether the project has a worktree to offer: one besides its own
    /// folder and the main checkout, which are never removed here.
    func offersWorktreeCleanup(in projectID: ProjectID) -> Bool {
        (worktrees[projectID] ?? []).contains { canRemoveWorktree($0, in: projectID) }
    }

    /// Opens the window with nothing read and nothing picked, unless a removal
    /// is still going, in which case it opens on that.
    func beginWorktreeCleanup(in projectID: ProjectID) {
        guard offersWorktreeCleanup(in: projectID) else { return }
        if worktreeCleanups[projectID]?.progress == nil {
            var fresh = WorktreeCleanupState()
            // A read still going fills the fresh state in as well as it would
            // have the old one; starting a second beside it reads it all twice.
            fresh.isReading = worktreeCleanups[projectID]?.isReading ?? false
            worktreeCleanups[projectID] = fresh
        }
        presentModal(.worktreeCleanup(projectID))
    }

    func worktreeCleanupCandidates(in projectID: ProjectID) -> [WorktreeCleanupCandidate] {
        let readings = worktreeCleanups[projectID]?.readings ?? [:]
        return (worktrees[projectID] ?? []).filter { canRemoveWorktree($0, in: projectID) }.map { worktree in
            let inside = sessions(in: worktree, of: projectID)
            return WorktreeCleanupCandidate(
                worktree: worktree,
                reading: readings[worktree.path] ?? .reading,
                sessions: inside.count,
                agent: WorktreeAgentActivity(inside.filter(\.reportsStatus).map(\.status)),
                sessionActivity: inside.map(\.lastActivityAt).max()
            )
        }
    }

    /// Reads every worktree again, one at a time, each row filling in as its
    /// answer arrives.
    ///
    /// The list is asked for afresh rather than taken from the sidebar's, which
    /// can be a tick behind: a worktree made a moment ago would otherwise sit
    /// unread until the next pass. The sidebar is told to look too, so the two
    /// agree about which ones exist.
    func readWorktreeCleanupFacts(in projectID: ProjectID) {
        guard let home = project(projectID)?.rootPath else { return }
        let state = worktreeCleanups[projectID] ?? WorktreeCleanupState()
        guard !state.isReading, state.progress == nil else { return }
        worktreeCleanups[projectID] = state
        worktreeCleanups[projectID]?.isReading = true
        refreshGit(for: projectID)
        Task { [weak self] in
            let (repository, listed) = await Task.detached(priority: .utility) {
                () -> (WorktreeFactsReader.Repository, [GitWorktree]) in
                (WorktreeFactsReader.repository(at: home), GitWorktreeActions.list(at: home) ?? [])
            }.value
            for worktree in listed where !worktree.isMain {
                let reading = await Task.detached(priority: .utility) {
                    WorktreeFactsReader.facts(of: worktree, in: repository)
                }.value
                guard let self else { return }
                self.worktreeCleanups[projectID]?.record(reading, for: worktree.path)
                self.worktreeCleanups[projectID]?.suggest(
                    among: self.worktreeCleanupCandidates(in: projectID),
                    now: Date()
                )
            }
            self?.worktreeCleanups[projectID]?.isReading = false
        }
    }

    /// Removes the given worktrees one after another, and says how it went
    /// once, at the end.
    ///
    /// One after another, because each removal settles its branch in the
    /// repository they all share, and git takes a lock on it to do that. Each
    /// is read again just before it goes: an agent may have started in it, or
    /// written a file, since the row was drawn. A refusal is recorded against
    /// its row and the rest carry on.
    func removeWorktrees(_ paths: [String], in projectID: ProjectID) {
        guard let home = project(projectID)?.rootPath,
              let state = worktreeCleanups[projectID],
              state.progress == nil, !paths.isEmpty else { return }
        worktreeCleanups[projectID]?.progress = WorktreeCleanupProgress(total: paths.count)
        // An edit still in the editor is uncommitted work as well. Written
        // out, it is a changed file the reading before each removal counts,
        // and a consent given for fewer files no longer covers it.
        editors.saveAll()
        Task { [weak self] in
            let repository = await Task.detached(priority: .userInitiated) {
                WorktreeFactsReader.repository(at: home)
            }.value
            var outcomes: [WorktreeCleanupOutcome] = []
            for path in paths {
                guard let self else { return }
                self.worktreeCleanups[projectID]?.progress?.current = path
                let outcome = await self.removeWorktreeForCleanup(at: path, measuredBy: repository, in: projectID)
                outcomes.append(outcome)
                self.worktreeCleanups[projectID]?.settle(path, with: outcome)
                self.worktreeCleanups[projectID]?.progress?.finished += 1
            }
            guard let self else { return }
            self.worktreeCleanups[projectID]?.progress = nil
            self.presentWorktreeCleanupSummary(WorktreeCleanup.summary(of: outcomes))
            self.readWorktreeCleanupFacts(in: projectID)
        }
    }

    private func removeWorktreeForCleanup(
        at path: String,
        measuredBy repository: WorktreeFactsReader.Repository,
        in projectID: ProjectID
    ) async -> WorktreeCleanupOutcome {
        guard let worktree = worktrees[projectID]?.first(where: { $0.path == path }) else {
            return WorktreeCleanupOutcome(
                name: URL(fileURLWithPath: path).lastPathComponent,
                failure: relayLocalized("Git no longer lists it.")
            )
        }
        let reading = await Task.detached(priority: .userInitiated) {
            WorktreeFactsReader.facts(of: worktree, in: repository)
        }.value
        worktreeCleanups[projectID]?.record(reading, for: path)
        let consent = worktreeCleanups[projectID]?.discardConsent[path]
        // No candidate is a worktree that is no longer removable here, which
        // `performWorktreeRemoval` refuses in words of its own.
        let candidate = worktreeCleanupCandidates(in: projectID).first { $0.id == path }
        if let candidate, let blocker = WorktreeCleanup.blockers(of: candidate, discardConsent: consent).first {
            return WorktreeCleanupOutcome(
                name: worktree.name,
                branch: worktree.branch,
                failure: blocker.reason
            )
        }
        let removal = await performWorktreeRemoval(
            worktree,
            discardingChanges: candidate.map { WorktreeCleanup.discardsChanges($0, discardConsent: consent) } ?? false,
            in: projectID
        )
        return WorktreeCleanupOutcome(
            name: worktree.name,
            branch: worktree.branch,
            failure: removal.failure.map { Self.summarised($0) },
            branchOutcome: removal.branch
        )
    }

    private func presentWorktreeCleanupSummary(_ summary: WorktreeCleanupSummary) {
        var lines: [String] = []
        if !summary.keptBranches.isEmpty {
            lines.append(String(
                format: relayLocalized("Branches kept, with commits not merged anywhere yet: %@."),
                summary.keptBranches.joined(separator: ", ")
            ))
        }
        lines += summary.failures.map { "\($0.name): \($0.message)" }

        let isComplete = summary.failures.isEmpty
        present(ToastContent(
            kind: isComplete ? .success : (summary.removed == 0 ? .error : .warning),
            title: isComplete
                ? String(format: relayLocalized("Worktrees removed: %d"), summary.removed)
                : String(format: relayLocalized("Worktrees removed: %d of %d"), summary.removed, summary.attempted),
            message: lines.isEmpty ? nil : lines.joined(separator: "\n"),
            // What git refused has to be read, which five seconds is not enough for.
            duration: isComplete ? .seconds(5) : nil
        ))
    }
}

@MainActor
extension WorktreeCleanupBlocker {
    /// Why a row cannot be picked, as its row says it.
    var reason: String {
        switch self {
        case .reading: relayLocalized("Reading…")
        case let .unreadable(message): String(format: relayLocalized("Git could not read it: %@"), message)
        case .locked: relayLocalized("Locked: git will not remove it until it is unlocked")
        case .agentWaiting: relayLocalized("An agent in it is waiting for you")
        case .agentWorking: relayLocalized("An agent in it is working")
        case let .strandedCommits(count):
            String(format: relayLocalized("Commits on no branch, lost with it: %d"), count)
        case let .uncommittedChanges(count):
            String(format: relayLocalized("Uncommitted files: %d"), count)
        }
    }
}
