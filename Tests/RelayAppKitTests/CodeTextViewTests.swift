import AppKit
import Testing

@testable import RelayAppKit

@Suite("The editor lays text out")
@MainActor
struct CodeTextViewTests {
    /// The bug this exists for: the panes came up black with four line
    /// numbers floating in them. A text view with no frame and no container
    /// size lays nothing out and reports no trouble — the ruler goes on
    /// counting lines it is never asked to draw beside.
    @Test("Text put into the view occupies room on screen")
    func textIsLaidOut() throws {
        let made = CodeTextView.make(fontSize: 11.5)
        made.scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        made.scroll.layoutSubtreeIfNeeded()
        CodeTextView.setText("one\ntwo\nthree\nfour", in: made.text, fontSize: 11.5)

        // Asked of TextKit 2, deliberately: reaching for `layoutManager` is
        // what drops a text view back into TextKit 1, where it drew nothing at
        // all inside a hosting view.
        let layout = try #require(made.text.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        let used = layout.usageBoundsForTextContainer
        #expect(used.width > 0, Comment(rawValue: "used \(used)"))
        #expect(used.height > 0, Comment(rawValue: "used \(used)"))
    }

    @Test("The view grows with what is in it")
    func heightFollowsTheContent() throws {
        func height(of text: String) throws -> CGFloat {
            let made = CodeTextView.make(fontSize: 11.5)
            made.scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
            made.scroll.layoutSubtreeIfNeeded()
            CodeTextView.setText(text, in: made.text, fontSize: 11.5)
            let layout = try #require(made.text.textLayoutManager)
            layout.ensureLayout(for: layout.documentRange)
            return layout.usageBoundsForTextContainer.height
        }

        let short = try height(of: "one")
        let tall = try height(of: String(repeating: "line\n", count: 40))
        #expect(tall > short * 10, Comment(rawValue: "short \(short), tall \(tall)"))
    }

    @Test("What is put in the view is painted")
    func textIsPainted() throws {
        // The last question the merge panes left: the string is set, the
        // layout says it occupies room — is anything actually drawn? Asked of
        // the pixels, since nothing else will say.
        let made = CodeTextView.make(fontSize: 12)
        CodeTextView.setText(
            String(repeating: "wide line of text\n", count: 8),
            in: made.text,
            fontSize: 12
        )
        made.scroll.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        made.scroll.layoutSubtreeIfNeeded()

        let image = try #require(made.scroll.bitmapImageRepForCachingDisplay(in: made.scroll.bounds))
        made.scroll.cacheDisplay(in: made.scroll.bounds, to: image)

        // Light pixels, not merely several colours: counting colours passed
        // while the text was being drawn black on black, with the ruler's own
        // shade making up the second colour. The text is the only light thing
        // in this palette, so its presence is a question about brightness.
        var lightPixels = 0
        var brightest = 0.0
        var sampled = 0
        for x in stride(from: 40, to: 280, by: 2) {
            for y in stride(from: 10, to: 180, by: 2) {
                guard let colour = image.colorAt(x: x, y: y)?
                    .usingColorSpace(.deviceRGB) else { continue }
                sampled += 1
                let brightness = (colour.redComponent + colour.greenComponent + colour.blueComponent) / 3
                brightest = max(brightest, brightness)
                if brightness > 0.4 { lightPixels += 1 }
            }
        }
        let report = "\(lightPixels) light of \(sampled) sampled, brightest \(brightest), "
            + "text frame \(made.text.frame), visible \(made.scroll.documentVisibleRect)"
        #expect(lightPixels > 20, Comment(rawValue: report))
    }

    @Test("A tinted line is the one that gets the colour")
    func tintsLandOnTheirLines() throws {
        // What tells a conflict apart in the result pane. Painting the wrong
        // line is worse than painting none: it would say the disagreement is
        // somewhere it is not.
        let made = CodeTextView.make(fontSize: 11.5)
        made.text.string = "zero\none\ntwo"
        let coordinator = CodeTextView.Coordinator(text: .constant(made.text.string))
        coordinator.textView = made.text
        coordinator.applyTints([1: .red])

        let storage = try #require(made.text.textStorage)
        let text = made.text.string as NSString
        let second = text.lineRange(for: NSRange(location: text.range(of: "one").location, length: 0))

        #expect(storage.attribute(.backgroundColor, at: second.location, effectiveRange: nil) != nil)
        #expect(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    }
}
