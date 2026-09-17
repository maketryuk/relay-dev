import CoreGraphics
import Foundation
import Testing

@testable import RelayAppKit

@Suite("Where a dragged row lands")
struct ColumnReorderTests {
    /// Three rows sixty points tall with two points between them.
    private let midpoints: [CGFloat] = [30, 92, 154]

    @Test("One row of travel moves one place")
    func oneRowMovesOnePlace() {
        #expect(ColumnReorder.targetIndex(sourceIndex: 0, pointer: 20, midpoints: midpoints) == 0)
        #expect(ColumnReorder.targetIndex(sourceIndex: 0, pointer: 100, midpoints: midpoints) == 1)
        #expect(ColumnReorder.targetIndex(sourceIndex: 0, pointer: 160, midpoints: midpoints) == 2)
    }

    @Test("The middle is reachable from either end")
    func middleIsReachable() {
        // With three rows this was the case that could not be expressed: the
        // held row's own centre was the nearest one to itself until the
        // pointer had travelled a whole row, so the first and the last could
        // only ever swap with their neighbour or go to the far end.
        #expect(ColumnReorder.targetIndex(sourceIndex: 0, pointer: 95, midpoints: midpoints) == 1)
        #expect(ColumnReorder.targetIndex(sourceIndex: 2, pointer: 60, midpoints: midpoints) == 1)
    }

    @Test("Dragging past the last row lands at the end, not beyond it")
    func clampedToTheList() {
        #expect(ColumnReorder.targetIndex(sourceIndex: 0, pointer: 9_000, midpoints: midpoints) == 2)
        #expect(ColumnReorder.targetIndex(sourceIndex: 2, pointer: -9_000, midpoints: midpoints) == 0)
    }

    @Test("A row held still stays where it is")
    func noMovementIsNoMove() {
        for (index, midpoint) in midpoints.enumerated() {
            #expect(ColumnReorder.targetIndex(sourceIndex: index, pointer: midpoint, midpoints: midpoints) == index)
        }
    }

    @Test("A list of one has nowhere to go")
    func singleRow() {
        #expect(ColumnReorder.targetIndex(sourceIndex: 0, pointer: 500, midpoints: [30]) == 0)
        #expect(ColumnReorder.targetIndex(sourceIndex: 0, pointer: 500, midpoints: []) == 0)
    }

    @Test("Rows of different heights are answered by their own middles")
    func unevenRows() {
        // The sidebar's rows are not all the same height: a session with a
        // branch under it is taller than one without.
        let uneven: [CGFloat] = [20, 90, 130]
        #expect(ColumnReorder.targetIndex(sourceIndex: 2, pointer: 40, midpoints: uneven) == 1)
        #expect(ColumnReorder.targetIndex(sourceIndex: 2, pointer: 15, midpoints: uneven) == 0)
        #expect(ColumnReorder.targetIndex(sourceIndex: 0, pointer: 95, midpoints: uneven) == 1)
    }
}
