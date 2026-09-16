import Foundation
import Testing

@testable import RelayAppKit

@Suite("Terminal text size")
struct TerminalZoomTests {
    @Test("A step moves the size by the step")
    func steps() {
        #expect(TerminalZoom.stepped(12.5, by: 1) == 13.5)
        #expect(TerminalZoom.stepped(12.5, by: -1) == 11.5)
    }

    @Test("Held down, it stops at the ends rather than running off them")
    func clamps() {
        // The keys repeat, so the limits are reached constantly rather than
        // exceptionally: an unreadable terminal must not be one of the states
        // holding a key can leave the app in.
        #expect(TerminalZoom.stepped(TerminalZoom.range.lowerBound, by: -4) == TerminalZoom.range.lowerBound)
        #expect(TerminalZoom.stepped(TerminalZoom.range.upperBound, by: 4) == TerminalZoom.range.upperBound)
    }

    @Test("The default is inside the range it is stepped through")
    func defaultIsReachable() {
        #expect(TerminalZoom.range.contains(TerminalZoom.defaultSize))
    }
}
