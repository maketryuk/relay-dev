import AppKit
import RelayUI
import SwiftUI

/// A monospaced text view with numbered lines.
///
/// AppKit's, not SwiftUI's: `TextEditor` has no line numbers, no way to tint a
/// run of lines and no undo worth the name, and all three are the difference
/// between a text box and somewhere a person will edit a file. This is the
/// piece the merge panes are built from, and the file editor after them.
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var isEditable = true
    /// Line indexes to tint, and what to tint them with: how a conflict shows
    /// where it is without markers having to be read.
    var tints: [Int: Color] = [:]
    var fontSize: CGFloat = 11.5
    /// Called when the view scrolls, so a pane beside it can follow.
    var onScroll: ((CGFloat) -> Void)?
    /// Where this view should be scrolled to, when something else is leading.
    var scrollOffset: CGFloat?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let made = Self.make(fontSize: fontSize)
        made.text.delegate = context.coordinator
        made.text.string = text

        context.coordinator.textView = made.text
        context.coordinator.ruler = made.ruler
        context.coordinator.observe(made.scroll, onScroll: onScroll)
        context.coordinator.applyTints(tints)
        return made.scroll
    }

    /// Builds the views, away from SwiftUI, so that what AppKit needs to lay
    /// text out at all can be asserted on.
    ///
    /// All of it is needed. A text view with no frame, no `minSize`/`maxSize`
    /// and no container size is laid out into nothing — and says nothing about
    /// it: the ruler still draws its line numbers, which is how this showed up,
    /// as four numbers floating in an empty black panel.
    static func make(fontSize: CGFloat) -> (scroll: NSScrollView, text: NSTextView, ruler: LineNumberRuler) {
        let unbounded = CGFloat.greatestFiniteMagnitude
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: unbounded, height: unbounded)
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: 0, height: unbounded)
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        textView.textColor = NSColor(Theme.Palette.textPrimary)
        textView.backgroundColor = NSColor(Theme.Palette.base)
        textView.insertionPointColor = NSColor(Theme.Palette.accent)
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 6, height: 6)

        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(Theme.Palette.base)
        scrollView.borderType = .noBorder

        let ruler = LineNumberRuler(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        return (scrollView, textView, ruler)
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.onScroll = onScroll
        textView.isEditable = isEditable
        textView.isSelectable = true

        // Only when it actually differs: assigning the string resets the
        // selection and empties the undo stack, which for someone typing in it
        // is the editor throwing their work's history away mid-sentence.
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(
                location: min(selected.location, text.utf16.count),
                length: 0
            ))
        }
        context.coordinator.applyTints(tints)

        if let scrollOffset, abs(scrollView.contentView.bounds.origin.y - scrollOffset) > 1 {
            context.coordinator.isFollowing = true
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: scrollOffset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            context.coordinator.isFollowing = false
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        weak var textView: NSTextView?
        weak var ruler: LineNumberRuler?
        var onScroll: ((CGFloat) -> Void)?
        /// True while this view is being scrolled to match another, so the
        /// two do not push each other back and forth for ever.
        var isFollowing = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
            ruler?.needsDisplay = true
        }

        func observe(_ scrollView: NSScrollView, onScroll: ((CGFloat) -> Void)?) {
            self.onScroll = onScroll
            scrollView.contentView.postsBoundsChangedNotifications = true
            // The clip view is held rather than read off the notification:
            // an `NSNotification` is not `Sendable`, and what is wanted from
            // it is one number that the view itself can be asked for.
            let clip = scrollView.contentView
            NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: clip,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, !self.isFollowing else { return }
                    self.onScroll?(clip.bounds.origin.y)
                }
            }
        }

        /// Paints the conflicting lines, so where the disagreement is can be
        /// seen before a marker is read.
        func applyTints(_ tints: [Int: Color]) {
            guard let textView, let storage = textView.textStorage else { return }
            let full = NSRange(location: 0, length: storage.length)
            storage.removeAttribute(.backgroundColor, range: full)
            guard !tints.isEmpty else { return }

            let text = textView.string as NSString
            var line = 0
            var start = 0
            while start < text.length {
                let range = text.lineRange(for: NSRange(location: start, length: 0))
                if let colour = tints[line] {
                    storage.addAttribute(.backgroundColor, value: NSColor(colour), range: range)
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

/// The margin down the left with the line numbers in it.
final class LineNumberRuler: NSRulerView {
    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("not used")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        NSColor(Theme.Palette.sidebar).setFill()
        rect.fill()

        let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(Theme.Palette.textTertiary),
        ]

        let text = textView.string as NSString
        let visible = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
        var line = 1
        var index = 0

        while index < text.length {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            if NSLocationInRange(lineRange.location, visible) || NSMaxRange(visible) == lineRange.location {
                let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
                let bounds = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
                let y = bounds.minY + textView.textContainerInset.height - textView.visibleRect.origin.y
                let label = "\(line)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(
                    at: NSPoint(x: ruleThickness - size.width - 6, y: y + (bounds.height - size.height) / 2),
                    withAttributes: attributes
                )
            }
            line += 1
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
    }
}
