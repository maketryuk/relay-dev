import Foundation
import RelayUI

/// What to call the two sides of a conflict on screen.
///
/// Neither "yours" nor "theirs" is safe to say. Rebasing replays your commits
/// onto someone else's, so git's `ours` is the upstream you are landing on and
/// git's `theirs` is your own work — a header that decided to say "mine" would
/// be wrong every rebase, which is most of them here. And git's own labels are
/// no better on their own: `HEAD` names a side without saying anything about
/// it, and a bare hash says less.
///
/// What is true in every case is the operation, so the operation is what the
/// headers say — and the label goes with the side that has one worth reading.
@MainActor
enum GitMergeNaming {
    static func ours(operation: GitMergeState.Operation?, label: String) -> String {
        switch operation {
        // The side already in the branch: during a rebase that is the commits
        // replayed before this one, which is why it cannot be called a branch.
        case .rebase: relayLocalized("Already rebased")
        case .merge, .cherryPick, .revert: relayLocalized("Current branch")
        case nil: fallback(label, or: relayLocalized("ours"))
        }
    }

    static func theirs(operation: GitMergeState.Operation?, label: String) -> String {
        let name = fallback(label, or: relayLocalized("theirs"))
        switch operation {
        case .rebase: return String(format: relayLocalized("Being rebased: %@"), name)
        case .merge: return String(format: relayLocalized("Merging in: %@"), name)
        case .cherryPick: return String(format: relayLocalized("Applying: %@"), name)
        case .revert: return String(format: relayLocalized("Reverting: %@"), name)
        case nil: return name
        }
    }

    /// A conflict re-emitted by the app carries bare markers, so the label is
    /// empty by the time a resolved file is read back.
    private static func fallback(_ label: String, or substitute: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? substitute : trimmed
    }
}
