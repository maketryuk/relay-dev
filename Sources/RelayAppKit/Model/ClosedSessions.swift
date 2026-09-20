import Foundation
import RelayProtocol

/// The sessions ⌘⇧T brings back.
///
/// A stack rather than a list, newest first: pressing it again goes further
/// back, which is what the gesture means in every browser. It is an undo for a
/// slip of the hand — the cross is next to the split buttons and ⌘W is next to
/// ⌘T — and not a record of the day's work, which is what the history panel is
/// for. Hence the cap: ten is more than anybody reaches for in a row, and a
/// stack that grew without bound would be a second history nobody asked for.
enum ClosedSessions {
    static let limit = 10

    /// Remembers a session that was closed, unless it is one that should not
    /// come back this way.
    ///
    /// A service is left out: it is started and stopped by the buttons beside
    /// it, and bringing a dev server back with the shortcut for reopening a
    /// terminal would start a process nobody asked for.
    static func pushing(_ spec: SessionSpec, onto stack: [SessionSpec]) -> [SessionSpec] {
        guard !spec.role.isService else { return stack }
        return Array(([spec] + stack).prefix(limit))
    }

    /// The newest session worth reopening, and the stack without it.
    ///
    /// `isEligible` is asked because a stack entry can outlive what it needs:
    /// the project it belongs to may be gone, and reopening into nothing would
    /// eat the entry while doing nothing. Entries it refuses are left where
    /// they are rather than discarded — the shortcut is scoped to the project
    /// you are looking at, and the one you are not looking at still has its
    /// own to bring back.
    static func popping(
        _ stack: [SessionSpec],
        where isEligible: (SessionSpec) -> Bool
    ) -> (spec: SessionSpec, rest: [SessionSpec])? {
        guard let index = stack.firstIndex(where: isEligible) else { return nil }
        var rest = stack
        let spec = rest.remove(at: index)
        return (spec, rest)
    }
}
