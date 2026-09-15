import SwiftUI
import Testing

@testable import RelayUI

@Suite("Vendor marks")
struct VendorMarkTests {
    private let frame = CGRect(x: 0, y: 0, width: 100, height: 100)

    @Test("Every mark produces a drawable path")
    func pathsAreNotEmpty() {
        #expect(!ClaudeMarkShape().path(in: frame).isEmpty)
        #expect(!CodexMarkShape().path(in: frame).isEmpty)
        #expect(!GeminiMarkShape().path(in: frame).isEmpty)
    }

    @Test("Marks stay inside the frame they are given")
    func pathsRespectTheirFrame() {
        // A mark that overflows would collide with the text beside it in a row.
        for path in [
            ClaudeMarkShape().path(in: frame),
            CodexMarkShape().path(in: frame),
            GeminiMarkShape().path(in: frame),
        ] {
            let bounds = path.boundingRect
            #expect(bounds.minX >= -0.5)
            #expect(bounds.minY >= -0.5)
            #expect(bounds.maxX <= frame.width + 0.5)
            #expect(bounds.maxY <= frame.height + 0.5)
        }
    }

    @Test("Marks fill most of their frame rather than floating in it")
    func marksAreCentredAndFill() {
        for path in [
            ClaudeMarkShape().path(in: frame),
            CodexMarkShape().path(in: frame),
            GeminiMarkShape().path(in: frame),
        ] {
            let bounds = path.boundingRect
            #expect(bounds.width > frame.width * 0.9)
            #expect(bounds.height > frame.height * 0.9)
            #expect(abs(bounds.midX - frame.midX) < 1)
            #expect(abs(bounds.midY - frame.midY) < 1)
        }
    }

    @Test("A non-square frame still yields a square mark")
    func marksStaySquare() {
        let wide = CGRect(x: 0, y: 0, width: 200, height: 60)
        for path in [
            ClaudeMarkShape().path(in: wide),
            CodexMarkShape().path(in: wide),
            GeminiMarkShape().path(in: wide),
        ] {
            let bounds = path.boundingRect
            #expect(abs(bounds.width - bounds.height) < 1)
            #expect(bounds.height <= wide.height + 0.5)
            // Centred horizontally in the wider box.
            #expect(abs(bounds.midX - wide.midX) < 1)
        }
    }

    @Test("Scaling is linear, so one definition serves every glyph size")
    func scalesLinearly() {
        let small = ClaudeMarkShape().path(in: CGRect(x: 0, y: 0, width: 10, height: 10)).boundingRect
        let large = ClaudeMarkShape().path(in: CGRect(x: 0, y: 0, width: 100, height: 100)).boundingRect
        #expect(abs(large.width / small.width - 10) < 0.1)
    }

    @Test("The Codex knot encloses counter-shapes, which is why it needs even-odd")
    func codexHasInteriorSubpaths() {
        // A single outline would fill solid; the holes are what make it read.
        var subpaths = 0
        CodexMarkShape().path(in: frame).forEach { element in
            if case .move = element { subpaths += 1 }
        }
        #expect(subpaths > 1)
    }
}

@Suite("Relay mark")
struct RelayMarkTests {
    private let frame = CGRect(x: 0, y: 0, width: 120, height: 120)

    @Test("The ring is drawn and stays inside its frame")
    func ringFitsItsFrame() {
        let path = RelayMarkShape().path(in: frame)
        #expect(!path.isEmpty)
        let bounds = path.boundingRect
        #expect(bounds.minX >= -0.5)
        #expect(bounds.maxX <= frame.width + 0.5)
        #expect(bounds.maxY <= frame.height + 0.5)
    }

    @Test("The ring is open at the top, where the dot sits")
    func ringIsOpenAtTheTop() {
        // The gap is the idea: the app can be closed, the process stays.
        let bounds = RelayMarkShape().path(in: frame).boundingRect
        let dotCentre = RelayMarkShape.dotCentre(forSide: frame.width)
        #expect(dotCentre.y < bounds.minY)
    }

    @Test("A non-square frame still yields a square mark")
    func staysSquare() {
        let wide = CGRect(x: 0, y: 0, width: 300, height: 100)
        let bounds = RelayMarkShape().path(in: wide).boundingRect
        #expect(bounds.height <= wide.height + 0.5)
        #expect(abs(bounds.midX - wide.midX) < 1)
    }

    @Test("Stroke and dot scale with the mark")
    func proportionsScale() {
        #expect(RelayMarkShape.strokeWidth(forSide: 1024) == 112)
        #expect(RelayMarkShape.dotDiameter(forSide: 1024) == 128)
        #expect(RelayMarkShape.strokeWidth(forSide: 512) == 56)
        // Linear, so one definition serves a 16 pt glyph and a 1024 pt icon.
        #expect(RelayMarkShape.dotCentre(forSide: 1024) == CGPoint(x: 512, y: 224))
    }
}
