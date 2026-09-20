import AppKit
import RelayUI
import SwiftUI

/// A monospaced text view with numbered lines.
///
/// AppKit's, not SwiftUI's: `TextEditor` has no line numbers, no way to tint a
/// run of lines and no undo worth the name, and all three are the difference
/// between a text box and somewhere a person will edit a file. This is the
/// piece the merge panes are built from, and the file editor after them.
///
/// It does not bring its own caret: whoever places it says `.relayPointer(.text)`
/// as well. A hosting view claims the pointer for everything inside it, and
/// that supersedes the cursor rectangles `NSTextView` registers for its own
/// text — so the arrow stayed an arrow over a file that could be typed into,
/// which is the one shape that says "nothing here takes text".
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    /// Line indexes to tint, and what to tint them with: how a conflict shows
    /// where it is without markers having to be read.
    var tints: [Int: Color] = [:]
    var fontSize: CGFloat = 11.5
    /// Extra room under every line.
    ///
    /// A line of text is about as tall as its font and no taller, which leaves
    /// the gutter beside it too short to put a legible glyph in. Given as
    /// paragraph spacing rather than line spacing deliberately: every line here
    /// is its own paragraph, and `lineSpacing` separates the lines *within*
    /// one, so it would do nothing at all.
    var lineSpacing: CGFloat = 0
    /// Empty room to leave above given lines, in lines.
    ///
    /// What keeps the three panes of a merge level: a passage answered with
    /// one line here may be three lines in the pane beside it, and without the
    /// difference left as space everything below it reads against the wrong
    /// line. The text is not padded — blank lines would be written to the file
    /// — only the space above it.
    var gaps: [Int: Int] = [:]
    /// What the file is written in, when that is known. Nil leaves the text
    /// in one colour — which is right for a scratch buffer and wrong for a
    /// file, so whoever opens a file passes it.
    var language: SourceLanguage?
    /// Called whenever the caret moves in this view, which is every way a
    /// person can say "I am working in this pane" short of typing. Carries
    /// where the caret went, so a command from the menu means the same place
    /// a ⌘-click would.
    var onFocus: ((Int) -> Void)?
    /// ⌘-click, with the character it landed on: "take me to whatever this
    /// name comes from".
    var onCommandClick: ((Int) -> Void)?
    /// Whether a name is currently drawn as a link, so the pane can promise
    /// the same thing with the pointer that it promises with the underline.
    /// Handed out rather than done here: the pointer over this view belongs
    /// to SwiftUI, which supersedes anything AppKit says about it.
    var onLink: ((Bool) -> Void)?
    /// Somewhere to put the caret and scroll to, when something outside the
    /// pane decides where to look.
    var reveal: OpenFile.Reveal?
    /// What a find has turned up in this text, and which of them is being
    /// looked at.
    var find: FindMatches?
    /// Everywhere one local name is written, marked together.
    var occurrences: [NSRange] = []
    /// What a checker objected to, drawn under the text it objected to.
    var problems: [Problem] = []

    struct Problem: Equatable {
        let range: NSRange
        let isError: Bool
        /// Shown when the pointer rests on it: a mark that says something is
        /// wrong and not what is a mark that has to be taken somewhere else
        /// to be read.
        let message: String
    }

    struct FindMatches: Equatable {
        var ranges: [NSRange] = []
        var current = 0

        var isEmpty: Bool { ranges.isEmpty }

        /// `3/12`, and `0` for a search that found nothing. Empty before
        /// anything has been typed, because "0" is an answer to a question.
        func counter(for query: String) -> String {
            guard !query.isEmpty else { return "" }
            guard !ranges.isEmpty else { return "0" }
            return "\(current + 1)/\(ranges.count)"
        }

        /// The next match, or the one before, wrapping at either end: a find
        /// that stops at the bottom of the file has to be started again to go
        /// on, which is the one thing nobody wants from a find.
        func stepped(_ direction: Int) -> FindMatches {
            guard !ranges.isEmpty else { return self }
            var moved = self
            moved.current = (current + direction % ranges.count + ranges.count) % ranges.count
            return moved
        }
    }
    /// Panes that scroll together, if this is one of them.
    ///
    /// Held by AppKit rather than driven from SwiftUI state: a scroll that
    /// wrote to state re-rendered the pane, which scrolled the others, which
    /// wrote to state — and the notification arrives on the next turn of the
    /// run loop, so the "this was me" flag guarded nothing. The panel came up
    /// blank because it never stopped updating.
    var sync: ScrollSync?

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator(text: $text, onFocus: onFocus, onCommandClick: onCommandClick)
        coordinator.onLink = onLink
        return coordinator
    }

    func makeNSView(context: Context) -> NSScrollView {
        let made = Self.make(fontSize: fontSize)
        made.text.delegate = context.coordinator
        made.text.typingAttributes = Self.attributes(fontSize: fontSize, lineSpacing: lineSpacing)
        Self.setText(text, in: made.text, fontSize: fontSize, lineSpacing: lineSpacing)

        context.coordinator.attach(to: made.text)
        context.coordinator.highlight(language: language, fontSize: fontSize)
        context.coordinator.decorate(tints: tints, gaps: gaps, fontSize: fontSize, lineSpacing: lineSpacing)
        sync?.adopt(made.scroll)
        return made.scroll
    }

    /// How the text is drawn.
    ///
    /// Attributed rather than assigned as a plain string: both are drawn the
    /// same — a text view applies its own `textColor` to storage that carries
    /// none — but the font and colour then live in one place instead of two,
    /// and what is typed into the view is styled by the same attributes.
    /// What a ⌘-click at this offset would be a click on.
    ///
    /// Not every word is one. A word inside a string is a value — the text of
    /// a cookie's name, a class in a template — and nothing declares it
    /// anywhere; drawn as a link it promises a jump that cannot exist. The
    /// exceptions are the strings that do name something: a key with dots in
    /// it, a path with slashes.
    static func linkRange(in text: String, at offset: Int) -> NSRange? {
        guard let word = SymbolWord.identifier(in: text, at: offset) else { return nil }
        guard let literal = SymbolWord.literal(in: text, at: offset) else { return word.range }
        return literal.text.contains(".") || literal.text.contains("/") ? word.range : nil
    }

    static func attributes(fontSize: CGFloat, lineSpacing: CGFloat = 0) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor(Theme.Palette.textPrimary),
            .paragraphStyle: paragraphStyle(lineSpacing: lineSpacing),
        ]
    }

    static func paragraphStyle(lineSpacing: CGFloat, roomAbove: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = lineSpacing
        style.paragraphSpacingBefore = roomAbove
        return style
    }

    /// How tall one line of this editor is.
    ///
    /// Taken from the font rather than from the layout, since asking a text
    /// view for its layout manager is what drops it back into TextKit 1, where
    /// it draws nothing at all inside a hosting view. The panes beside the
    /// editor lay their rows out to this, which is the only reason the three of
    /// them line up: a row a point and a half taller is four lines out of step
    /// by the bottom of the file.
    static func lineHeight(fontSize: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return font.ascender - font.descender + font.leading
    }

    /// How far it is from one line to the next.
    static func pitch(fontSize: CGFloat, lineSpacing: CGFloat) -> CGFloat {
        lineHeight(fontSize: fontSize) + lineSpacing
    }

    static func setText(
        _ text: String,
        in textView: NSTextView,
        fontSize: CGFloat,
        lineSpacing: CGFloat = 0
    ) {
        let attributed = NSAttributedString(
            string: text,
            attributes: attributes(fontSize: fontSize, lineSpacing: lineSpacing)
        )
        textView.textStorage?.setAttributedString(attributed)
    }

    static func make(fontSize: CGFloat) -> (scroll: NSScrollView, text: NSTextView) {
        // AppKit's own factory, and then nothing but styling. Built by hand —
        // frame, `minSize`, `maxSize`, a container size — the view came out in
        // TextKit 1 and, inside a hosting view, drew nothing at all: no
        // rendering subviews, a ruler counting lines beside an empty panel.
        // Asking for `layoutManager` is what puts a text view back into
        // TextKit 1, so nothing here or in the ruler may mention it.
        let scrollView = NSTextView.scrollableTextView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(Theme.Palette.base)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.focusRingType = .none

        guard let textView = scrollView.documentView as? NSTextView else {
            return (scrollView, NSTextView())
        }

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.focusRingType = .none
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor(Theme.Palette.textPrimary)
        textView.typingAttributes = attributes(fontSize: fontSize)
        textView.backgroundColor = NSColor(Theme.Palette.base)
        textView.insertionPointColor = NSColor(Theme.Palette.accent)
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 8, height: 6)
        textView.textContainer?.lineFragmentPadding = 2

        return (scrollView, textView)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Asked for here rather than once, because it is a window-wide setting
        // that somebody else may put back: SwiftTerm turns it on for its own
        // tracking and restores what it found when its last terminal goes.
        // Left on afterwards, which costs a window some events it ignores.
        scrollView.window?.acceptsMouseMovedEvents = true
        textView.isEditable = isEditable
        textView.isSelectable = true

        // Only when it actually differs: assigning the string resets the
        // selection and empties the undo stack, which for someone typing in it
        // is the editor throwing their work's history away mid-sentence.
        let replaced = textView.string != text
        if replaced {
            let selected = textView.selectedRange()
            Self.setText(text, in: textView, fontSize: fontSize, lineSpacing: lineSpacing)
            textView.setSelectedRange(NSRange(
                location: min(selected.location, text.utf16.count),
                length: 0
            ))
            // Every attribute went with the old text, including the marks.
            // Without this the coordinator believes it has already drawn
            // them, and they come back only when they happen to change —
            // which from the outside is an underline that flickers away for
            // no reason.
            context.coordinator.forgetMarks()
        }
        context.coordinator.onFocus = onFocus
        context.coordinator.onCommandClick = onCommandClick
        context.coordinator.onLink = onLink
        context.coordinator.resize(to: fontSize, lineSpacing: lineSpacing)
        context.coordinator.highlight(language: language, fontSize: fontSize)
        if replaced { context.coordinator.recolour() }
        context.coordinator.decorate(tints: tints, gaps: gaps, fontSize: fontSize, lineSpacing: lineSpacing)
        // After the decoration, which clears every background colour there is
        // — including the ones the find put there a moment ago.
        context.coordinator.mark(find)
        context.coordinator.mark(occurrences: occurrences)
        context.coordinator.mark(problems: problems)
        context.coordinator.go(to: reveal)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate, NSGestureRecognizerDelegate {
        private let text: Binding<String>
        var onFocus: ((Int) -> Void)?
        var onCommandClick: ((Int) -> Void)?
        var onLink: ((Bool) -> Void)?
        weak var textView: NSTextView?
        /// The parse-driven colouring, kept alive for as long as the pane is.
        private var highlighter: SourceHighlighter?
        private var highlightedLanguage: SourceLanguage?
        private var highlightedFontSize: CGFloat?
        /// The size the text is currently drawn at, so that a size that has
        /// not moved does not re-attribute the whole file on every redraw.
        private var sized: CGFloat?
        /// The name drawn as a link while ⌘ is held, so it can be undrawn.
        private var underlined: NSRange?
        /// What the find bar last asked for, so that walking to the next
        /// match scrolls and merely redrawing does not.
        private var marked: FindMatches?
        private var markedOccurrences: [NSRange] = []
        private var markedProblems: [Problem] = []
        /// The jump already made, so the same request is not made twice.
        private var arrivedAt: UUID?
        private var pointerWatch: Any?

        init(text: Binding<String>, onFocus: ((Int) -> Void)? = nil, onCommandClick: ((Int) -> Void)? = nil) {
            self.text = text
            self.onFocus = onFocus
            self.onCommandClick = onCommandClick
        }

        /// Takes the text view over: the caret, the ⌘-click and the pointer
        /// tracking that draws a name as a link before it is clicked.
        func attach(to textView: NSTextView) {
            self.textView = textView

            // A gesture rather than a subclass. `NSTextView.scrollableTextView()`
            // is what puts this view in TextKit 2 — building one by hand ended
            // up in TextKit 1, drawing nothing — so the click is taken beside
            // the view instead of inside it, and only when ⌘ is down, which
            // leaves selecting text exactly as it was.
            let click = NSClickGestureRecognizer(target: self, action: #selector(commandClicked(_:)))
            click.delegate = self
            textView.addGestureRecognizer(click)

            // Left for the pointer leaving: entering and exiting still arrive.
            textView.addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .inVisibleRect, .activeInKeyWindow],
                owner: self
            ))

            // Moving does not. macOS 26 stopped delivering `mouseMoved` to a
            // tracking area, which is how this was written first and why
            // nothing was ever underlined; SwiftTerm hit the same wall in this
            // same window and answered it the same way — ask the window for
            // the events and take them from a monitor. `flagsChanged` is in
            // here too because the pointer does not have to move for ⌘ to be
            // pressed, and a link that appears only once the hand twitches is
            // a link nobody finds.
            pointerWatch = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .flagsChanged]) { event in
                MainActor.assumeIsolated { [weak self] in
                    self?.hovered(at: event.type == .mouseMoved ? event : nil)
                }
                return event
            }
        }

        /// Gives the window's event monitor back.
        ///
        /// Here rather than in `deinit`, which is not on any actor: a monitor
        /// is removed on the main thread, and SwiftUI takes the view down on
        /// it — `dismantleNSView` is that moment, stated.
        func detach() {
            if let pointerWatch { NSEvent.removeMonitor(pointerWatch) }
            pointerWatch = nil
        }

        func gestureRecognizer(
            _ recognizer: NSGestureRecognizer,
            shouldAttemptToRecognizeWith event: NSEvent
        ) -> Bool {
            event.modifierFlags.contains(.command) && onCommandClick != nil
        }

        @objc
        private func commandClicked(_ recognizer: NSClickGestureRecognizer) {
            guard let textView else { return }
            onCommandClick?(textView.characterIndexForInsertion(at: recognizer.location(in: textView)))
        }

        @objc
        func mouseExited(with event: NSEvent) {
            underline(nil)
        }

        /// Draws the name under the pointer as a link while ⌘ is held.
        ///
        /// - Parameter event: a move, or nil when the pointer has not moved
        ///   and it is ⌘ itself that changed.
        private func hovered(at event: NSEvent?) {
            guard let textView else { return }

            // A move in another window says where the pointer is in that
            // window's coordinates, which means nothing here.
            let inWindow = event.flatMap { $0.window === textView.window ? $0.locationInWindow : nil }
                ?? textView.window?.mouseLocationOutsideOfEventStream
            let point = inWindow.map { textView.convert($0, from: nil) }
            let offset = point.flatMap { textView.visibleRect.contains($0)
                ? textView.characterIndexForInsertion(at: $0)
                : nil
            }

            explain(at: offset)
            guard onCommandClick != nil, NSEvent.modifierFlags.contains(.command) else { return link(at: nil) }
            link(at: offset)
        }

        /// Puts what the checker said under the pointer, for the tooltip to
        /// show when the hand stops moving.
        private func explain(at offset: Int?) {
            guard let textView else { return }
            let found = offset.flatMap { offset in
                markedProblems.first { NSLocationInRange(offset, $0.range) }
            }
            guard textView.toolTip != found?.message else { return }
            textView.toolTip = found?.message
        }

        /// Draws the name at this offset as a link, or takes the last one
        /// back. Apart from the pointer so that what it decides can be tested
        /// without a window, a mouse and a held-down key.
        func link(at offset: Int?) {
            guard let textView, let offset else { return underline(nil) }
            underline(CodeTextView.linkRange(in: textView.string, at: offset))
        }

        private func underline(_ range: NSRange?) {
            guard range != underlined else { return }
            defer { onLink?(underlined != nil) }
            if let underlined, let storage = textView?.textStorage, NSMaxRange(underlined) <= storage.length {
                storage.removeAttribute(.underlineStyle, range: underlined)
            }
            underlined = nil
            guard let range, let storage = textView?.textStorage, NSMaxRange(range) <= storage.length else { return }
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            underlined = range
        }

        /// Paints what a find has turned up, and follows the one being
        /// looked at.
        ///
        /// Painted every time rather than only on a change, because the
        /// decoration pass before this one clears every background colour in
        /// the text. Scrolled only on a change, because a view that scrolled
        /// itself on every redraw could not be scrolled by hand at all.
        func mark(_ find: FindMatches?) {
            guard let textView, let storage = textView.textStorage else { return }
            let moved = find != marked

            for range in marked?.ranges ?? [] where NSMaxRange(range) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: range)
            }
            marked = find
            guard let find else { return }

            for (index, range) in find.ranges.enumerated() where NSMaxRange(range) <= storage.length {
                let colour = index == find.current
                    ? Theme.Palette.accent.opacity(0.45)
                    : Theme.Palette.accentMuted
                storage.addAttribute(.backgroundColor, value: NSColor(colour), range: range)
            }

            guard moved, find.ranges.indices.contains(find.current) else { return }
            let current = find.ranges[find.current]
            guard NSMaxRange(current) <= storage.length else { return }
            textView.scrollRangeToVisible(current)
        }

        /// Marks every place one name is written.
        ///
        /// Fainter than a find, and for a different question: a find is being
        /// walked through, and this is one answer shown in all the places it
        /// is true at once.
        func mark(occurrences: [NSRange]) {
            guard let storage = textView?.textStorage else { return }
            // Its own record of what it painted: clearing the find's ranges
            // here would rub out the marks painted a moment ago, which both
            // of these write in the same attribute.
            for range in markedOccurrences where NSMaxRange(range) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: range)
            }
            markedOccurrences = occurrences
            for range in occurrences where NSMaxRange(range) <= storage.length {
                storage.addAttribute(
                    .backgroundColor,
                    value: NSColor(Theme.Palette.accent.opacity(0.18)),
                    range: range
                )
            }
        }

        /// The text was replaced, so nothing is drawn on it any more.
        func forgetMarks() {
            marked = nil
            markedOccurrences = []
            markedProblems = []
        }

        /// Draws a line under what a checker objected to.
        ///
        /// Under rather than through or behind: the text stays the colour the
        /// parse made it — which is what says whether a word is a keyword or
        /// a string — and the complaint is a second thing said about the same
        /// characters rather than a replacement for the first.
        func mark(problems: [Problem]) {
            guard problems != markedProblems, let storage = textView?.textStorage else { return }

            for problem in markedProblems where NSMaxRange(problem.range) <= storage.length {
                storage.removeAttribute(.underlineStyle, range: problem.range)
                storage.removeAttribute(.underlineColor, range: problem.range)
            }
            markedProblems = problems

            for problem in problems where NSMaxRange(problem.range) <= storage.length {
                storage.addAttribute(
                    .underlineStyle,
                    value: NSUnderlineStyle.thick.union(.patternDot).rawValue,
                    range: problem.range
                )
                storage.addAttribute(
                    .underlineColor,
                    value: NSColor(problem.isError ? Theme.Palette.statusError : Theme.Palette.statusWaiting),
                    range: problem.range
                )
            }
        }

        /// Puts the caret where something outside the pane asked for, and
        /// scrolls it into view with room around it.
        func go(to reveal: OpenFile.Reveal?) {
            guard let reveal, reveal.id != arrivedAt, let textView else { return }
            arrivedAt = reveal.id

            let length = (textView.string as NSString).length
            let location = min(max(reveal.range.location, 0), length)
            let range = NSRange(location: location, length: min(reveal.range.length, length - location))

            // Next turn of the run loop: this arrives inside a SwiftUI update,
            // where a pane that has only just appeared has not been laid out
            // yet and scrolling lands wherever the old layout was.
            DispatchQueue.main.async { [weak self] in
                guard let textView = self?.textView else { return }
                textView.setSelectedRange(range)
                let clip = textView.enclosingScrollView?.contentView
                let before = clip?.bounds.origin.y
                textView.scrollRangeToVisible(range)
                self?.leaveRoom(around: before, in: textView)
                textView.window?.makeFirstResponder(textView)
            }
        }

        /// Keeps the arrival off the edge it was scrolled to.
        ///
        /// `scrollRangeToVisible` does the least it can, which puts the line
        /// against the top or the bottom of the pane with nothing on the side
        /// it came from — and the lines around a declaration are most of what
        /// is being gone to look at.
        private func leaveRoom(around before: CGFloat?, in textView: NSTextView) {
            guard let before, let scrollView = textView.enclosingScrollView else { return }
            let clip = scrollView.contentView
            let after = clip.bounds.origin.y
            guard after != before else { return }

            let room: CGFloat = 60
            let limit = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            let target = min(max(after + (after > before ? room : -room), 0), limit)
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
            scrollView.reflectScrolledClipView(clip)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            onFocus?(textView?.selectedRange().location ?? 0)
        }

        /// The text was swapped rather than typed into, and the colouring is
        /// of the text that is no longer there.
        func recolour() {
            highlighter?.refresh()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            highlighter?.textChanged()
        }

        /// Draws the text at a new size.
        ///
        /// The font lives in three places at once — the view, what it types
        /// with, and the attributes on every character — and a view built at
        /// one size stays at it: nothing about assigning `fontSize` to a
        /// SwiftUI value reaches a text view that already exists, which is why
        /// ⌘+ moved the terminals and left the files where they were.
        func resize(to fontSize: CGFloat, lineSpacing: CGFloat) {
            guard sized != fontSize, let textView, let storage = textView.textStorage else { return }
            sized = fontSize

            let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            textView.font = font
            textView.typingAttributes = CodeTextView.attributes(fontSize: fontSize, lineSpacing: lineSpacing)
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
        }

        /// Attaches the highlighter, or replaces it when the file changed to
        /// one in another language. Rebuilt rather than reconfigured: the
        /// grammar and its query are what it was constructed around.
        func highlight(language: SourceLanguage?, fontSize: CGFloat) {
            let changed = highlightedLanguage != language || highlightedFontSize != fontSize
            guard changed || (language != nil && highlighter == nil) else { return }
            highlightedLanguage = language
            highlightedFontSize = fontSize
            highlighter = nil
            guard let language, let textView else { return }
            highlighter = SourceHighlighter(
                textView: textView,
                language: language,
                fontSize: fontSize
            )
        }

        /// Paints the conflicting lines and leaves the room asked for above
        /// them: where the disagreement is, seen before a marker is read, and
        /// the panes beside this one kept level with it.
        func decorate(tints: [Int: Color], gaps: [Int: Int], fontSize: CGFloat, lineSpacing: CGFloat) {
            guard let textView, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.backgroundColor, range: full)
            // Back to the plain style rather than to none: the room under
            // every line is what the panes beside this one are laid out to.
            storage.addAttribute(
                .paragraphStyle,
                value: CodeTextView.paragraphStyle(lineSpacing: lineSpacing),
                range: full
            )
            guard !tints.isEmpty || !gaps.isEmpty else { return }

            let pitch = CodeTextView.pitch(fontSize: fontSize, lineSpacing: lineSpacing)
            let text = textView.string as NSString
            var line = 0
            var start = 0
            while start < text.length {
                let range = text.lineRange(for: NSRange(location: start, length: 0))
                if let colour = tints[line] {
                    storage.addAttribute(.backgroundColor, value: NSColor(colour), range: range)
                }
                if let missing = gaps[line], missing > 0 {
                    storage.addAttribute(
                        .paragraphStyle,
                        value: CodeTextView.paragraphStyle(
                            lineSpacing: lineSpacing,
                            roomAbove: CGFloat(missing) * pitch
                        ),
                        range: range
                    )
                }
                line += 1
                // A last line with no newline after it returns a range that
                // ends exactly where this one began, so walking to the end of
                // it walks nowhere: the loop spun for ever, on the main
                // thread, on any file that does not end in a newline — which
                // is most of the ones a merge produces.
                let next = NSMaxRange(range)
                guard next > start else { break }
                start = next
            }
        }
    }
}

/// What a text view in here will not tolerate, learned the hard way.
///
/// Line numbers were tried twice and are not here. An `NSRulerView` comes
/// dressed in a banner with an `NSVisualEffectView` inside it, and that
/// material inside a SwiftUI hosting view wrecked the compositing of
/// everything around it: the panel's own header, its toolbar and an entire
/// pane were drawn and then covered over — three separate "the panes are
/// blank" reports came from that one view. A plain view added *inside* the
/// text view instead stops TextKit 2 drawing the text at all.
///
/// So the editable pane has no numbers for now, and the read-only panes
/// beside it draw their own in SwiftUI, where they cost nothing. What would
/// work here is a view outside the text view entirely, kept in step with the
/// layout — worth doing when there is a reason beyond symmetry.

/// Keeps several scroll views at the same offset.
///
/// The same passage sits at the same height in all three panes of a merge, so
/// scrolling one and not the others is a way of comparing the wrong lines.
/// Deliberately AppKit down to the ground: no SwiftUI state changes, therefore
/// no re-rendering, therefore no loop between a scroll and the layout that
/// caused it. The reentrancy flag works here because the notification is taken
/// synchronously — a queue would deliver it after the flag was already down.
@MainActor
final class ScrollSync {
    private var views: [NSScrollView] = []
    private var isSyncing = false

    func adopt(_ scrollView: NSScrollView) {
        guard !views.contains(scrollView) else { return }
        views.append(scrollView)
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
    }

    @objc
    private func boundsChanged(_ notification: Notification) {
        guard !isSyncing, let clip = notification.object as? NSClipView else { return }
        isSyncing = true
        defer { isSyncing = false }

        let offset = clip.bounds.origin.y
        for view in views where view.contentView !== clip {
            guard abs(view.contentView.bounds.origin.y - offset) > 0.5 else { continue }
            view.contentView.scroll(to: NSPoint(x: view.contentView.bounds.origin.x, y: offset))
            view.reflectScrolledClipView(view.contentView)
        }
    }
}
