import Foundation
import Testing

@testable import RelayAppKit

@Suite("List navigation")
struct ListNavigationTests {
    @Test("Arrows step through the rows")
    func stepsThroughRows() {
        #expect(ListNavigation.movingRow(ListFocus(row: 0), by: 1, rowCount: 5).row == 1)
        #expect(ListNavigation.movingRow(ListFocus(row: 3), by: -1, rowCount: 5).row == 2)
    }

    @Test("The highlight stops at the ends instead of wrapping")
    func stopsAtTheEnds() {
        // Jumping from the last row back to the first hides how long the list
        // is, and makes holding the arrow key feel like nothing is happening.
        #expect(ListNavigation.movingRow(ListFocus(row: 0), by: -1, rowCount: 5).row == 0)
        #expect(ListNavigation.movingRow(ListFocus(row: 4), by: 1, rowCount: 5).row == 4)
    }

    @Test("Changing row starts that row's actions from the first")
    func movingRowResetsTheAction() {
        // Otherwise arriving on a new row leaves the keyboard pointing at its
        // third button, which for a port is the one that kills the process.
        let focus = ListFocus(row: 2, action: 2)
        #expect(ListNavigation.movingRow(focus, by: 1, rowCount: 5).action == 0)
    }

    @Test("Left and right walk the row's actions, and stop at its ends")
    func walksActions() {
        let focus = ListFocus(row: 1, action: 0)
        #expect(ListNavigation.movingAction(focus, by: 1, actionCount: 3).action == 1)
        #expect(ListNavigation.movingAction(focus, by: -1, actionCount: 3).action == 0)
        #expect(ListNavigation.movingAction(ListFocus(row: 1, action: 2), by: 1, actionCount: 3).action == 2)
    }

    @Test("Moving sideways stays on the same row")
    func actionMovementKeepsTheRow() {
        #expect(ListNavigation.movingAction(ListFocus(row: 4, action: 0), by: 1, actionCount: 2).row == 4)
    }

    @Test("An empty list has nowhere to go")
    func emptyListStaysAtZero() {
        #expect(ListNavigation.movingRow(ListFocus(row: 0), by: 1, rowCount: 0) == ListFocus())
        #expect(ListNavigation.clamping(ListFocus(row: 7, action: 3), rowCount: 0, actionCount: 0) == ListFocus())
    }

    @Test("Filtering pulls the highlight back into the list")
    func clampsWhenTheListShrinks() {
        // Typing in the filter shortens the list under the highlight; left where
        // it was, Return would act on nothing for no visible reason.
        #expect(ListNavigation.clamping(ListFocus(row: 9), rowCount: 3, actionCount: 2).row == 2)
        #expect(ListNavigation.clamping(ListFocus(row: 1), rowCount: 3, actionCount: 2).row == 1)
    }

    @Test("A row with fewer actions pulls the focus back too")
    func clampsTheAction() {
        // A port with no URL offers one action where the last one offered three.
        #expect(ListNavigation.clamping(ListFocus(row: 1, action: 2), rowCount: 5, actionCount: 1).action == 0)
    }
}
