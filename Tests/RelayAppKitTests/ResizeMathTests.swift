import CoreGraphics
import Foundation
import RelayUI
import Testing

@Suite("Resize arithmetic")
struct ResizeMathTests {
    private let limits: ClosedRange<Double> = 200 ... 380

    @Test("The divider follows the pointer, point for point")
    func tracksTheTranslation() {
        #expect(ResizeMath.length(from: 248, translation: 40, limits: limits) == 288)
        #expect(ResizeMath.length(from: 248, translation: -40, limits: limits) == 208)
    }

    @Test("The same drag always gives the same answer")
    func isIdempotent() {
        // A drag reports its translation cumulatively, so recomputing from the
        // value being updated compounds it and the divider outruns the pointer.
        // Every event in one drag starts from the same captured value.
        let start = 248.0
        var width = start
        for translation in [5.0, 12.0, 30.0, 30.0, 31.0] {
            width = ResizeMath.length(from: start, translation: translation, limits: limits)
        }
        #expect(width == 279)
    }

    @Test("A pane cannot be dragged out of existence")
    func clampsToTheLimits() {
        #expect(ResizeMath.length(from: 248, translation: -900, limits: limits) == 200)
        #expect(ResizeMath.length(from: 248, translation: 900, limits: limits) == 380)
    }

    @Test("Widths land on whole points")
    func roundsToWholePoints() {
        // A sub-point width re-lays-out a terminal for a change nobody can see.
        #expect(ResizeMath.length(from: 248.4, translation: 0.2, limits: limits) == 249)
        #expect(ResizeMath.length(from: 248.1, translation: 0.2, limits: limits) == 248)
    }

    @Test("A split fraction moves by the distance dragged")
    func fractionFollowsPoints() {
        // Half of 800 is 400; dragging 80 points right puts the divider at 480.
        let fraction = ResizeMath.fraction(
            from: 0.5,
            translation: 80,
            total: 800,
            limits: 0.15 ... 0.85
        )
        #expect(fraction == 0.6)
    }

    @Test("A split fraction is clamped like a width is")
    func fractionIsClamped() {
        #expect(ResizeMath.fraction(from: 0.5, translation: -10_000, total: 800, limits: 0.15 ... 0.85) == 0.15)
        #expect(ResizeMath.fraction(from: 0.5, translation: 10_000, total: 800, limits: 0.15 ... 0.85) == 0.85)
    }

    @Test("A split with no measured size does not move")
    func zeroSizedSplitHoldsStill() {
        #expect(ResizeMath.fraction(from: 0.5, translation: 50, total: 0, limits: 0.15 ... 0.85) == 0.5)
    }
}
