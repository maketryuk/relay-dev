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
}
