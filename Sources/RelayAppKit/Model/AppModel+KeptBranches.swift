import Foundation
import RelayProtocol
import RelayUI

/// A branch that removing its worktree kept, and deleting it anyway.
///
/// Relay keeps a branch it cannot prove is finished, and it cannot prove
/// every finished one: a squash of more than the local branch has, a forge
/// that does something new. The person usually knows, and the toast that
/// says the branch was kept is where they find out, so that is where it can
/// go — held to the commit Relay judged, so that what they agree to lose is
/// what they were told about.
extension AppModel {
    /// Says a branch was kept, with a button that deletes it.
    ///
    /// It stays until it is dismissed: deleting commits merged nowhere is a
    /// decision, and five seconds is not long enough to make it in.
    func presentKeptBranch(_ branch: String, at head: String, in projectID: ProjectID) {
        present(ToastContent(
            kind: .info,
            title: String(format: relayLocalized("Kept branch %@"), branch),
            message: relayLocalized("It has commits that are not merged anywhere yet."),
            duration: nil,
            key: "kept-branch:\(projectID.rawValue):\(branch)",
            action: ToastAction(title: relayLocalized("Delete Branch")) { [weak self] in
                self?.deleteKeptBranch(branch, at: head, in: projectID)
            }
        ))
    }

    /// Deletes a kept branch as long as it still points at `head`, and says
    /// how that went without showing anything.
    func performKeptBranchDeletion(
        _ branch: String,
        at head: String,
        in projectID: ProjectID
    ) async -> GitWorktreeActions.BranchDeletion {
        guard let root = project(projectID)?.rootPath else {
            return .failed(relayLocalized("There is no such project."))
        }
        return await Task.detached(priority: .userInitiated) { () -> GitWorktreeActions.BranchDeletion in
            GitWorktreeActions.deleteBranch(branch, at: head, in: root)
        }.value
    }

    /// The toast's button: deletes the branch, and says what happened either
    /// way — with the commit it was at when it went, which is all it takes
    /// to bring it back.
    func deleteKeptBranch(_ branch: String, at head: String, in projectID: ProjectID) {
        Task { [weak self] in
            guard let self else { return }
            let deletion = await self.performKeptBranchDeletion(branch, at: head, in: projectID)
            self.present(Self.toast(for: deletion, of: branch, at: head))
        }
    }

    static func toast(
        for deletion: GitWorktreeActions.BranchDeletion,
        of branch: String,
        at head: String
    ) -> ToastContent {
        let kept = String(format: relayLocalized("Kept branch %@"), branch)
        switch deletion {
        case .deleted:
            return ToastContent(
                kind: .success,
                title: String(format: relayLocalized("Deleted branch %@"), branch),
                message: String(format: relayLocalized("It was at %@."), String(head.prefix(7)))
            )
        case .moved:
            return ToastContent(
                kind: .warning,
                title: kept,
                message: relayLocalized(
                    "It has changed since its worktree was removed. Look at what is on it before deleting it."
                )
            )
        case .checkedOut(let path):
            return ToastContent(
                kind: .warning,
                title: kept,
                message: String(
                    format: relayLocalized("It is checked out in %@."),
                    HomeRelativePath.abbreviating(path)
                )
            )
        case .failed(let reason):
            return ToastContent(
                kind: .error,
                title: String(format: relayLocalized("Could not delete branch %@"), branch),
                message: summarised(reason)
            )
        }
    }
}
