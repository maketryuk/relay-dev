import CoreGraphics
import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("Reordering a list by dragging")
struct ListReorderingTests {
    @Test("The half of a row the pointer is in decides which side")
    func sideFollowsThePointer() {
        #expect(ListReordering.side(at: 4, in: 28) == .before)
        #expect(ListReordering.side(at: 24, in: 28) == .after)
        // Exactly halfway counts as below, so the two halves together cover the
        // row with no gap in the middle.
        #expect(ListReordering.side(at: 14, in: 28) == .after)
    }

    @Test("A row with no height cannot be aimed at")
    func zeroHeightHasNoLowerHalf() {
        #expect(ListReordering.side(at: 0, in: 0) == .before)
    }

    @Test("Dropping above a row puts the dragged one in front of it")
    func beforeInsertsInFront() {
        #expect(ListReordering.moving("c", beside: "a", side: .before, in: ["a", "b", "c"]) == ["c", "a", "b"])
    }

    @Test("Dropping below a row puts the dragged one after it")
    func afterInsertsBehind() {
        #expect(ListReordering.moving("a", beside: "c", side: .after, in: ["a", "b", "c"]) == ["b", "c", "a"])
    }

    @Test("The index is read from the list the item is landing in")
    func removesBeforeInserting() {
        // Inserting first and removing afterwards lands every downward move one
        // place short, which is the bug this ordering exists to avoid.
        #expect(ListReordering.moving("a", beside: "b", side: .after, in: ["a", "b", "c"]) == ["b", "a", "c"])
    }

    @Test("Dropping a row on itself changes nothing")
    func selfDropIsANoop() {
        #expect(ListReordering.moving("a", beside: "a", side: .after, in: ["a", "b"]) == ["a", "b"])
    }

    @Test("A row the list does not hold is not inserted into it")
    func strangersAreRefused() {
        // Reordering moves what is already there; anything else is a drag from
        // somewhere this list knows nothing about.
        #expect(ListReordering.moving("z", beside: "a", side: .before, in: ["a", "b"]) == ["a", "b"])
        #expect(ListReordering.moving("a", beside: "z", side: .before, in: ["a", "b"]) == ["a", "b"])
    }
}

@Suite("Remembered session order")
struct SessionOrderingTests {
    private let a = SessionID(rawValue: "a")
    private let b = SessionID(rawValue: "b")
    private let c = SessionID(rawValue: "c")

    @Test("The arrangement survives a relaunch")
    func rememberedOrderWins() {
        // The daemon lists sessions in the order it started them; the sidebar
        // shows them in the order they were dragged into.
        #expect(SessionOrdering.applying([c, a, b], to: [a, b, c]) == [c, a, b])
    }

    @Test("A session nobody arranged keeps its place at the end")
    func newcomersFollow() {
        #expect(SessionOrdering.applying([c, a], to: [a, b, c]) == [c, a, b])
    }

    @Test("A session that has ended is dropped from the order")
    func goneSessionsAreForgotten() {
        #expect(SessionOrdering.applying([c, a, b], to: [a, c]) == [c, a])
    }

    @Test("Nothing remembered leaves the daemon's order alone")
    func noMemoryIsNoChange() {
        #expect(SessionOrdering.applying([], to: [a, b, c]) == [a, b, c])
    }
}
