import AppKit
import Foundation
import Testing

@testable import RelayAppKit

@Suite("A description in the visual editor")
@MainActor
struct RichMarkdownTests {
    /// What the editor writes for a text it did not open, which is what an
    /// edited block is written as.
    private func rewritten(_ markdown: String) -> String {
        RichMarkdown.markdown(from: RichMarkdown.render(markdown).text)
    }

    private func range(of word: String, in text: NSAttributedString) -> NSRange {
        (text.string as NSString).range(of: word)
    }

    @Test("Opened and saved untouched, a description is what it was, byte for byte")
    func untouched() {
        let source = """
        Setext heading
        ==============

        Some __bold__ and _italic_, a [link](https://yt.example "with a title").

        * one
        * two

          loose

        | a | b |
        |---|---|
        | 1 | 2 |

        ![](Screenshot 2026-09-23 at 13.13.59.png){width=70%}

        [ref]: https://yt.example/ref
        """
        let document = RichMarkdown.render(source)
        #expect(RichMarkdown.markdown(from: document.text, keeping: document) == source)
    }

    @Test("What the editor draws it writes back in its own spelling", arguments: [
        ("# Title", "# Title"),
        ("Plain **bold** *italic* ~~gone~~ `code`", "Plain **bold** *italic* ~~gone~~ `code`"),
        ("A [link](https://yt.example/a) here", "A [link](https://yt.example/a) here"),
        ("Bare https://yt.example/a here", "Bare https://yt.example/a here"),
        ("- one\n- two\n  - nested", "- one\n- two\n  - nested"),
        ("3. three\n4. four", "3. three\n4. four"),
        ("> quoted\n> still", "> quoted\n> still"),
        ("```swift\nlet a = 1\n\nlet b = 2\n```", "```swift\nlet a = 1\n\nlet b = 2\n```"),
        ("line one\nline two", "line one\nline two"),
        ("***both***", "***both***"),
    ])
    func constructs(source: String, written: String) {
        #expect(rewritten(source) == written)
    }

    @Test("What it cannot draw it keeps as it was written, even in a block it rewrites")
    func rawIsKept() {
        #expect(rewritten("- [ ] a task\n- [x] done") == "- [ ] a task\n- [x] done")
        #expect(rewritten("| a | b |\n|---|---|\n| 1 | 2 |") == "| a | b |\n|---|---|\n| 1 | 2 |")
        #expect(rewritten("See ![](Screenshot 2026-09-23 at 13.13.59.png){width=70%} here")
            == "See ![](Screenshot 2026-09-23 at 13.13.59.png){width=70%} here")
        #expect(rewritten("Logo ![logo](logo.png){width=40} and <b>html</b>") == "Logo ![logo](logo.png){width=40} and <b>html</b>")
    }

    @Test("Only the block that was edited is written anew; the rest stay as written")
    func editedBlock() {
        let source = "Heading\n=======\n\nKeep __this__ as it is.\n\nChange _this_."
        let document = RichMarkdown.render(source)
        let text = NSMutableAttributedString(attributedString: document.text)
        let word = range(of: "Change", in: text)
        text.replaceCharacters(in: word, with: "Changed")

        #expect(RichMarkdown.markdown(from: text, keeping: document)
            == "Heading\n=======\n\nKeep __this__ as it is.\n\nChanged *this*.")
    }

    @Test("Text that looks like Markdown is escaped, and reads back as the same text", arguments: [
        "2*3*4 and a_b but _c_",
        "# not a heading",
        "- not an item",
        "1. not a number",
        "> not a quote",
        "a [b](c) link that is not",
        "`ticks` and \\backslash",
        "<div> is not html",
        "~~not struck~~",
        "---",
    ])
    func escaping(typed: String) {
        let text = NSMutableAttributedString(string: typed, attributes: [.richBlock: RichMarkdown.Block.paragraph.rawValue])
        let written = RichMarkdown.markdown(from: text)
        let read = RichMarkdown.render(written).text.string
        #expect(read == typed, "written as \(written)")
    }

    @Test("A word made bold, a word made a link, a line made a heading")
    func formattingByHand() {
        let document = RichMarkdown.render("Make this bold and that a link.\n\nTitle")
        let text = NSMutableAttributedString(attributedString: document.text)
        text.addAttribute(.richStrong, value: true, range: range(of: "this bold", in: text))
        text.addAttribute(.link, value: "https://yt.example", range: range(of: "that", in: text))
        text.addAttribute(.richBlock, value: RichMarkdown.Block.heading(2).rawValue, range: range(of: "Title", in: text))

        #expect(RichMarkdown.markdown(from: text, keeping: document)
            == "Make **this bold** and [that](https://yt.example) a link.\n\n## Title")
    }

    @Test("A quote's bar and a code block's box each cover the whole block, empty lines and all")
    func decorations() {
        // `> a` and `> b` on consecutive lines are one paragraph; the empty
        // quoted line between them makes two.
        let text = RichMarkdown.render("> a\n>\n> b\n\ntext\n\n```\nx\n\ny\n```").text
        let found = RichMarkdown.decorations(in: text).map { ($0.0, (text.string as NSString).substring(with: $0.1)) }
        #expect(found.count == 2)
        #expect(found.first?.0 == .quoteBar && found.first?.1 == "a\nb")
        #expect(found.last?.0 == .codeBox && found.last?.1 == "x\n\ny")
    }

    @Test("A code block is spaced from what is around it by its first and last lines, and a new last line takes that over")
    func codeSpacing() {
        func spacing(_ line: String, in text: NSAttributedString) -> (before: CGFloat, after: CGFloat) {
            let at = (text.string as NSString).range(of: line).location
            let style = text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
            return (style?.paragraphSpacingBefore ?? -1, style?.paragraphSpacing ?? -1)
        }
        let text = NSMutableAttributedString(attributedString: RichMarkdown.render("before\n\n```\nx1\nx2\n```").text)
        #expect(spacing("x1", in: text).before > RichMarkdown.codeBoxInset)
        #expect(spacing("x1", in: text).after == 0)
        #expect(spacing("x2", in: text).after > RichMarkdown.codeBoxInset)

        // Typed at the end, the new line comes with the look of the one before.
        let end = text.length
        text.append(NSAttributedString(string: "\nx3", attributes: text.attributes(at: end - 1, effectiveRange: nil)))
        RichMarkdown.present(text, in: NSRange(location: end, length: 3))
        #expect(spacing("x2", in: text).after == 0)
        #expect(spacing("x3", in: text).after > RichMarkdown.codeBoxInset)
    }

    @Test("A mark ends before the space after it and starts after the space before it")
    func marksHugText() {
        let text = NSMutableAttributedString(string: "a bold b", attributes: [.richBlock: "p"])
        text.addAttribute(.richStrong, value: true, range: NSRange(location: 1, length: 6))
        #expect(RichMarkdown.markdown(from: text) == "a **bold** b")
    }
}

@Suite("Typing in the visual editor")
@MainActor
struct RichTextTypingTests {
    /// A text view as the editor makes one, holding the description.
    private func editor(_ markdown: String) -> (NSTextView, RichMarkdown.Document) {
        let document = RichMarkdown.render(markdown)
        let view = NSTextView(usingTextLayoutManager: false)
        view.isRichText = true
        view.textStorage?.setAttributedString(document.text)
        return (view, document)
    }

    private func written(_ view: NSTextView, _ document: RichMarkdown.Document) -> String {
        RichMarkdown.markdown(from: view.textStorage ?? NSAttributedString(), keeping: document)
    }

    @Test("Return in a list makes the next item, and Tab nests it")
    func lists() {
        let (view, document) = editor("- one")
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertNewline(nil)
        view.insertText("two", replacementRange: view.selectedRange())
        #expect(written(view, document) == "- one\n- two")

        view.insertNewline(nil)
        view.insertTab(nil)
        view.insertText("nested", replacementRange: view.selectedRange())
        #expect(written(view, document) == "- one\n- two\n  - nested")
    }

    @Test("Return on an empty item ends the list")
    func endingAList() {
        let (view, document) = editor("1. one")
        view.setSelectedRange(NSRange(location: view.string.utf16.count, length: 0))
        view.insertNewline(nil)
        view.insertNewline(nil)
        view.insertText("after", replacementRange: view.selectedRange())
        #expect(written(view, document) == "1. one\n\nafter")
    }
}

@Suite("The visual editor's toolbar")
@MainActor
struct RichTextControllerTests {
    @MainActor
    private final class Harness {
        let view = NSTextView(usingTextLayoutManager: false)
        let controller = RichTextController()
        let document: RichMarkdown.Document

        init(_ markdown: String) {
            document = RichMarkdown.render(markdown)
            view.isRichText = true
            view.allowsUndo = true
            view.textStorage?.setAttributedString(document.text)
            controller.textView = view
        }

        var markdown: String {
            RichMarkdown.markdown(from: view.textStorage ?? NSAttributedString(), keeping: document)
        }

        func select(_ word: String) {
            view.setSelectedRange((view.string as NSString).range(of: word))
            controller.refreshSelection()
        }

        func caret(after word: String) {
            let found = (view.string as NSString).range(of: word)
            view.setSelectedRange(NSRange(location: NSMaxRange(found), length: 0))
            controller.refreshSelection()
        }

        func type(_ text: String) {
            view.insertText(text, replacementRange: view.selectedRange())
        }
    }

    @Test("Bold, italic and code go on the selection, and off it again")
    func marks() {
        let editor = Harness("Make this bold")
        editor.select("this")
        editor.controller.toggle(.richStrong)
        #expect(editor.markdown == "Make **this** bold")
        editor.controller.toggle(.richStrong)
        #expect(editor.markdown == "Make this bold")
        editor.select("bold")
        editor.controller.toggle(.richCode)
        #expect(editor.markdown == "Make this `bold`")
    }

    @Test("With nothing selected, a mark is for what is typed next")
    func typingMark() {
        let editor = Harness("Start")
        editor.caret(after: "Start")
        editor.type(" ")
        editor.controller.toggle(.richEmphasis)
        editor.type("slanted")
        #expect(editor.markdown == "Start *slanted*")
    }

    @Test("A paragraph becomes a heading, and after Return the next line is text")
    func headings() {
        let editor = Harness("Title")
        editor.caret(after: "Title")
        editor.controller.setBlock(.heading(2))
        #expect(editor.markdown == "## Title")
        #expect(editor.controller.handleReturn())
        editor.type("Body")
        #expect(editor.markdown == "## Title\n\nBody")
    }

    @Test("Paragraphs become a list and back, and a list changes kind")
    func lists() {
        let editor = Harness("one\n\ntwo")
        editor.view.setSelectedRange(NSRange(location: 0, length: editor.view.string.utf16.count))
        editor.controller.toggleList(ordered: false)
        #expect(editor.markdown == "- one\n- two")
        editor.controller.toggleList(ordered: true)
        #expect(editor.markdown == "1. one\n2. two")
        editor.controller.toggleList(ordered: true)
        #expect(editor.markdown == "one\n\ntwo")
    }

    @Test("Return on an empty line of a quote leaves the quote")
    func leavingAQuote() {
        let editor = Harness("> quoted")
        editor.caret(after: "quoted")
        #expect(!editor.controller.handleReturn())
        editor.view.insertNewline(nil)
        #expect(editor.controller.handleReturn())
        editor.type("after")
        #expect(editor.markdown == "> quoted\n\nafter")
    }

    @Test("A selection becomes a link, and a link loses it")
    func links() {
        let editor = Harness("See that page")
        editor.select("that")
        editor.controller.applyLink("https://yt.example")
        #expect(editor.markdown == "See [that](https://yt.example) page")
        editor.caret(after: "tha")
        editor.controller.applyLink(nil)
        #expect(editor.markdown == "See that page")
    }

    @Test("A line break stays inside the paragraph")
    func lineBreak() {
        let editor = Harness("one")
        editor.caret(after: "one")
        editor.view.insertLineBreak(nil)
        editor.type("two")
        #expect(editor.markdown == "one\ntwo")
    }

    @Test("Every change is one step back for Undo")
    func undo() {
        let editor = Harness("Make this bold")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [], backing: .buffered, defer: true)
        window.contentView = editor.view
        editor.select("this")
        editor.controller.toggle(.richStrong)
        #expect(editor.markdown == "Make **this** bold")
        editor.view.undoManager?.undo()
        #expect(editor.markdown == "Make this bold")
    }
}

@Suite("A description to read")
@MainActor
struct RichMarkdownTextTests {
    private func height(_ markdown: String, width: CGFloat) -> CGFloat {
        let view = DecoratedTextView(usingTextLayoutManager: false)
        view.textContainer?.lineFragmentPadding = 2
        view.textStorage?.setAttributedString(RichMarkdown.render(markdown).text)
        return RichMarkdownText.fittingHeight(of: view, width: width) ?? 0
    }

    @Test("It is as tall as its text at the width it is given")
    func fits() {
        let sentence = String(repeating: "A sentence that goes on. ", count: 20)
        #expect(height("One line", width: 400) > 0)
        #expect(height(sentence, width: 200) > height(sentence, width: 600))
    }

    @Test("A code block at the end keeps its box inside the view")
    func codeAtTheEnd() {
        let plain = height("text\n\nmore", width: 400)
        let code = height("text\n\n```\nmore\n```", width: 400)
        #expect(code >= plain + RichMarkdown.codeBoxInset)
    }
}
