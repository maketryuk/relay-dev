import AppKit
import RelayUI
import SwiftUI
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

    /// The failure this exists for was invisible from inside the code: the
    /// pointer tracking was written against a tracking area, macOS 26 stopped
    /// delivering moves to one, and nothing was ever underlined. What can be
    /// tested here is the decision — given a place in the text, which run is
    /// drawn as a link — with the events left to AppKit.
    @Test("A name at the pointer is drawn as a link, and taken back after")
    func linksTheNameUnderThePointer() throws {
        let source = "package main\n\nfunc handle() {}\n"
        let view = CodeTextView(text: .constant(source), onCommandClick: { _ in })
        let coordinator = view.makeCoordinator()
        let made = CodeTextView.make(fontSize: 11.5)
        CodeTextView.setText(source, in: made.text, fontSize: 11.5)
        coordinator.attach(to: made.text)
        defer { coordinator.detach() }

        // What the pane turns into a pointing hand: the underline alone says
        // a name can be clicked to half the people who would click it.
        var linking: [Bool] = []
        coordinator.onLink = { linking.append($0) }

        let name = (source as NSString).range(of: "handle")
        coordinator.link(at: name.location + 2)
        #expect(underlined(in: made.text) == name)

        // Off any name — the blank line between the two — and the link goes
        // with it rather than staying behind on the word the pointer left.
        coordinator.link(at: (source as NSString).range(of: "\n\n").location + 1)
        #expect(underlined(in: made.text) == nil)

        coordinator.link(at: name.location)
        #expect(underlined(in: made.text) == name)
        coordinator.link(at: nil)
        #expect(underlined(in: made.text) == nil)

        // Said once each way round rather than on every twitch of the mouse.
        #expect(linking == [true, false, true, false])
    }

    private func underlined(in textView: NSTextView) -> NSRange? {
        guard let storage = textView.textStorage else { return nil }
        var found: NSRange?
        storage.enumerateAttribute(.underlineStyle, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { found = range }
        }
        return found
    }

    /// The failure this exists for: the search panel's preview showed every
    /// file in plain white. Nothing tells a text view that its contents were
    /// swapped — `textDidChange` is for editing — so the colouring stayed
    /// with the text that had gone.
    @Test("Text put in from outside is coloured, not only text that was typed")
    func replacedTextIsColoured() async throws {
        func coloured(_ view: NSTextView) -> Bool {
            guard let storage = view.textStorage else { return false }
            var found = false
            storage.enumerateAttribute(
                .foregroundColor,
                in: NSRange(location: 0, length: storage.length)
            ) { value, _, _ in
                guard let colour = value as? NSColor else { return }
                if colour != NSColor(Theme.Code.plain) { found = true }
            }
            return found
        }

        func editor(_ text: String) -> some View {
            CodeTextView(
                text: .constant(text),
                isEditable: false,
                language: SourceLanguage.detect(path: "/p/a.swift", contents: text)
            )
            .frame(width: 400, height: 300)
        }

        let hosting = NSHostingView(rootView: AnyView(editor("struct First {}\n")))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))

        var found: [NSTextView] = []
        func textViews(in view: NSView) {
            if let text = view as? NSTextView { found.append(text) }
            for subview in view.subviews { textViews(in: subview) }
        }
        textViews(in: hosting)
        let textView = try #require(found.first)
        #expect(coloured(textView))

        // The same view, another file in it.
        hosting.rootView = AnyView(editor("enum Second { case a }\n"))
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(textView.string.contains("Second"))
        #expect(coloured(textView), "the replaced text came out in one colour")
    }

    /// The failure this exists for: ⌘+ moved the terminals and left the files
    /// where they were. A text view keeps the size it was built at — the font
    /// is in the view, in what it types with and on every character — and a
    /// changed value in SwiftUI reaches none of the three by itself.
    @Test("A changed size reaches the text that is already there")
    func resizing() async throws {
        // Without a language, deliberately: a file whose kind is not
        // recognised has no highlighter re-attributing it, and the size then
        // has nothing else to reach it by.
        func editor(_ size: CGFloat) -> some View {
            CodeTextView(text: .constant("plain text\n"), isEditable: false, fontSize: size)
                .frame(width: 400, height: 300)
        }

        let hosting = NSHostingView(rootView: AnyView(editor(12)))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))

        var found: [NSTextView] = []
        func textViews(in view: NSView) {
            if let text = view as? NSTextView { found.append(text) }
            for subview in view.subviews { textViews(in: subview) }
        }
        textViews(in: hosting)
        let textView = try #require(found.first)
        #expect(textView.font?.pointSize == 12)

        hosting.rootView = AnyView(editor(18))
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(textView.font?.pointSize == 18)
        // And the characters themselves, which is what is actually drawn.
        let storage = try #require(textView.textStorage)
        let drawn = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(drawn?.pointSize == 18)
    }

    /// The failure this exists for: an underline that flickered away for no
    /// reason. Replacing the text takes every attribute with it, and the
    /// coordinator went on believing it had already drawn the marks.
    @Test("A mark survives the text being replaced under it")
    func marksAreRedrawn() async throws {
        let problems = [CodeTextView.Problem(
            range: NSRange(location: 0, length: 6),
            isError: true,
            message: "unused"
        )]

        func editor(_ text: String) -> some View {
            CodeTextView(text: .constant(text), isEditable: false, problems: problems)
                .frame(width: 400, height: 300)
        }

        let hosting = NSHostingView(rootView: AnyView(editor("struct First {}\n")))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))

        var found: [NSTextView] = []
        func textViews(in view: NSView) {
            if let text = view as? NSTextView { found.append(text) }
            for subview in view.subviews { textViews(in: subview) }
        }
        textViews(in: hosting)
        let textView = try #require(found.first)

        func underlined() -> Bool {
            guard let storage = textView.textStorage else { return false }
            var marked = false
            storage.enumerateAttribute(
                .underlineStyle,
                in: NSRange(location: 0, length: storage.length)
            ) { value, _, _ in
                if value != nil { marked = true }
            }
            return marked
        }
        #expect(underlined())

        hosting.rootView = AnyView(editor("struct Second {}\n"))
        hosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(200))

        #expect(underlined(), "the mark went with the text it was drawn on")
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
        coordinator.decorate(tints: [1: .red], gaps: [:], fontSize: 11.5, lineSpacing: 0)

        let storage = try #require(made.text.textStorage)
        let text = made.text.string as NSString
        let second = text.lineRange(for: NSRange(location: text.range(of: "one").location, length: 0))

        #expect(storage.attribute(.backgroundColor, at: second.location, effectiveRange: nil) != nil)
        #expect(storage.attribute(.backgroundColor, at: 0, effectiveRange: nil) == nil)
    }

    @Test("Room asked for above a line is left above that line")
    func gapsLandWhereTheyAreAsked() throws {
        // What keeps the three panes of a merge level: a passage shorter in
        // the result than in the panes beside it has the difference left as
        // space, since blank lines would be written to the file.
        let made = CodeTextView.make(fontSize: 12)
        CodeTextView.setText("one\ntwo\nthree", in: made.text, fontSize: 12, lineSpacing: 4)
        let coordinator = CodeTextView.Coordinator(text: .constant(made.text.string))
        coordinator.textView = made.text
        coordinator.decorate(tints: [:], gaps: [2: 2], fontSize: 12, lineSpacing: 4)

        let storage = try #require(made.text.textStorage)
        let text = made.text.string as NSString
        let third = text.lineRange(for: NSRange(location: text.range(of: "three").location, length: 0))
        let style = try #require(
            storage.attribute(.paragraphStyle, at: third.location, effectiveRange: nil) as? NSParagraphStyle
        )
        let pitch = CodeTextView.pitch(fontSize: 12, lineSpacing: 4)
        #expect(style.paragraphSpacingBefore == pitch * 2)
        // And the ordinary room under a line is still there on the lines that
        // asked for nothing.
        let first = try #require(
            storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        )
        #expect(first.paragraphSpacingBefore == 0)
        #expect(first.paragraphSpacing == 4)
    }
}
