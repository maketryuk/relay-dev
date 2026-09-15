import Foundation
import Testing

@testable import RelayAppKit

@Suite("List navigation")
struct ListNavigationTests {
    @Test("Arrows step through the list")
    func stepsThrough() {
        #expect(ListNavigation.moving(0, by: 1, count: 5) == 1)
        #expect(ListNavigation.moving(3, by: -1, count: 5) == 2)
    }

    @Test("The highlight stops at the ends instead of wrapping")
    func stopsAtTheEnds() {
        // Jumping from the last row back to the first hides how long the list
        // is, and makes holding the arrow key feel like nothing is happening.
        #expect(ListNavigation.moving(0, by: -1, count: 5) == 0)
        #expect(ListNavigation.moving(4, by: 1, count: 5) == 4)
    }

    @Test("An empty list has nowhere to go")
    func emptyListStaysAtZero() {
        #expect(ListNavigation.moving(0, by: 1, count: 0) == 0)
        #expect(ListNavigation.clamping(7, count: 0) == 0)
    }

    @Test("Filtering pulls the highlight back into the list")
    func clampsWhenTheListShrinks() {
        // Typing in the filter shortens the list under the highlight; left where
        // it was, Return would act on nothing for no visible reason.
        #expect(ListNavigation.clamping(9, count: 3) == 2)
        #expect(ListNavigation.clamping(1, count: 3) == 1)
    }
}
