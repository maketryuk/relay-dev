import Foundation
import RelayProtocol

extension AppModel {
    /// Keyed by the worktree's path as git reports it (`GitWorktree.path`).
    func worktreeNote(at path: String) -> WorktreeNote? {
        worktreeNotes.note(at: path)
    }

    /// nil clears it.
    func setWorktreeStatus(_ status: WorktreeWorkStatus?, at path: String) {
        reviseWorktreeNote(at: path) { $0.status = status }
    }

    /// nil or blank clears it.
    func setWorktreeComment(_ comment: String?, at path: String) {
        reviseWorktreeNote(at: path) { $0.comment = WorktreeNotes.comment(from: comment) }
    }

    /// Whether a note can be kept for the worktree at `path`: one git has
    /// listed for some project. Anything else would be shown nowhere, and no
    /// list would ever come to take it away again.
    func canNoteWorktree(at path: String) -> Bool {
        !projectsListingWorktree(at: path).isEmpty
    }

    /// Given every fresh list of a project's worktrees. A list that could not
    /// be read never gets here — `adopt` is only called with an answer — and
    /// that is what keeps a slow or failing `git` from wiping the notes.
    func keepWorktreeNotes(listedIn found: [GitWorktree], in projectID: ProjectID) {
        guard worktreeNotes.keep(only: found, in: projectID) else { return }
        persist()
    }

    private func reviseWorktreeNote(at path: String, _ change: (inout WorktreeNote) -> Void) {
        guard worktreeNotes.revise(at: path, listedBy: projectsListingWorktree(at: path), change) else { return }
        persist()
    }

    private func projectsListingWorktree(at path: String) -> [ProjectID] {
        projects.map(\.id).filter { id in
            worktrees[id]?.contains { $0.path == path } ?? false
        }
    }
}
