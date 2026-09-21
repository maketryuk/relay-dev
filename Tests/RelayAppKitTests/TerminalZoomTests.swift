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

    @Test("A size can be typed rather than stepped to")
    func readsATypedSize() {
        #expect(TerminalZoom.parsed("13") == 13)
        #expect(TerminalZoom.parsed(" 13.5 ") == 13.5)
        // The unit is printed beside the field, so it is the obvious thing to
        // type into it.
        #expect(TerminalZoom.parsed("14 pt") == 14)
    }

    @Test("A comma is a decimal point, because a Russian keyboard offers one")
    func readsAComma() {
        // The window asks for the number in Russian; refusing the separator
        // that language writes would be refusing the number.
        #expect(TerminalZoom.parsed("13,5") == 13.5)
    }

    @Test("A number past the end of the range comes back as the end of it")
    func clampsTypedSizes() {
        // Legible intent, answered rather than refused: a field that silently
        // ignores "40" reads as broken.
        #expect(TerminalZoom.parsed("40") == TerminalZoom.range.upperBound)
        #expect(TerminalZoom.parsed("1") == TerminalZoom.range.lowerBound)
    }

    @Test("What is not a size is not a size")
    func refusesEverythingElse() {
        #expect(TerminalZoom.parsed("") == nil)
        #expect(TerminalZoom.parsed("pt") == nil)
        #expect(TerminalZoom.parsed("0") == nil)
        #expect(TerminalZoom.parsed("1.2.3") == nil)
    }
}
