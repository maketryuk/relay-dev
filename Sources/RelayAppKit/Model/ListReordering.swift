import CoreGraphics
import Foundation
import RelayProtocol

/// Which side of a row a dragged item is asking to land on.
enum RowDropSide: Hashable, Sendable {
    case before
    case after
}

/// Where a pointer over a row in a vertical list is asking the dragged row to
/// go, and what the list looks like afterwards.
///
/// Pure, so the rule is stated once and tested rather than re-derived from
/// pixel arithmetic in two views — the project rail and the session sidebar
/// reorder by the same gesture and must agree about what it means.
enum ListReordering {
    /// The upper half means "above this one", the lower half "below it".
    ///
    /// No dead band in the middle: a row is small, and a gesture that does
    /// nothing because the pointer was near the centre reads as a broken drag
    /// rather than as a refusal.
    static func side(at offset: Double, in extent: Double) -> RowDropSide {
        guard extent > 0 else { return .before }
        return offset < extent / 2 ? .before : .after
    }

    static func side(at point: CGPoint, in size: CGSize) -> RowDropSide {
        side(at: point.y, in: size.height)
    }

    /// The list with `moved` taken out and put back beside `target`.
    ///
    /// Taken out first, so the index the item lands at is read from the list it
    /// is landing in: inserting before removing makes every move past the
    /// original position land one place short.
    static func moving<Item: Equatable>(
        _ moved: Item,
        beside target: Item,
        side: RowDropSide,
        in items: [Item]
    ) -> [Item] {
        guard moved != target, items.contains(moved), items.contains(target) else { return items }

        var result = items
        result.removeAll { $0 == moved }
        guard let anchor = result.firstIndex(of: target) else { return items }
        result.insert(moved, at: side == .before ? anchor : anchor + 1)
        return result
    }
}

/// The order sessions are listed in.
///
/// The daemon lists them in the order it started them, which is the right
/// default and the wrong answer once someone has dragged one into place. So the
/// remembered order wins where it applies, and anything the daemon knows about
/// that it does not mention — a session started by another window, or by an
/// older build — keeps its place at the end rather than disappearing.
enum SessionOrdering {
    static func applying(_ remembered: [SessionID], to live: [SessionID]) -> [SessionID] {
        let known = Set(live)
        let rememberedSet = Set(remembered)
        return remembered.filter(known.contains) + live.filter { !rememberedSet.contains($0) }
    }
}
