import Foundation
import RelayProtocol

/// Chooses the display name for a new session.
///
/// Names are derived from the sessions that currently exist rather than from a
/// counter that only ever climbs. Closing "Claude" and opening another one must
/// give "Claude" again — a lone session called "Claude 4" is just confusing.
enum SessionNaming {
    static func nextName(base: String, existing: some Sequence<String>) -> String {
        let taken = Set(existing)
        guard taken.contains(base) else { return base }

        var index = 2
        while taken.contains("\(base) \(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    static func nextName(for kind: SessionKind, existing: some Sequence<String>) -> String {
        nextName(base: kind.displayName, existing: existing)
    }

    /// How much of a name a header carries. An agent names itself after what
    /// it is doing, which is a sentence rather than a name.
    static let displayLimit = 40

    /// A name cut to what a row can carry, at a word boundary where there is
    /// one near enough to the end.
    ///
    /// The string is cut rather than the space it is given: a fixed width holds
    /// the full width open for `Terminal 2` as well, and everything after it on
    /// the row — the status, the pid, the controls — ends up a long way from
    /// the name it belongs to.
    static func shortened(_ name: String, limit: Int = displayLimit) -> String {
        guard name.count > limit else { return name }
        let head = name.prefix(limit)
        // Only where the boundary is near the end; cutting `a` off a
        // forty-character word is worse than cutting the word.
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= limit * 2 / 3 {
            return head[head.startIndex ..< space]
                .trimmingCharacters(in: .whitespaces) + "…"
        }
        return head.trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Labels for a set of sessions, each distinguishable from the others.
    ///
    /// A program names its own terminal, and every instance of it chooses the
    /// same name: two Claude sessions both report "Claude Code", and a list
    /// with the same row twice cannot be picked from. Where a reported title is
    /// shared, the session's own name is used instead — that one was made
    /// unique when the session was created — and anything still colliding after
    /// that is numbered in the order it appears.
    static func labels(for sessions: [SessionSnapshot]) -> [SessionID: String] {
        var shared: [String: Int] = [:]
        for session in sessions {
            shared[session.displayName, default: 0] += 1
        }

        var used: Set<String> = []
        var labels: [SessionID: String] = [:]
        for session in sessions {
            var label = session.displayName
            if shared[label, default: 0] > 1, !session.isNameUserDefined {
                label = session.name
            }
            if used.contains(label) {
                var index = 2
                while used.contains("\(label) \(index)") { index += 1 }
                label = "\(label) \(index)"
            }
            used.insert(label)
            labels[session.id] = label
        }
        return labels
    }
}
