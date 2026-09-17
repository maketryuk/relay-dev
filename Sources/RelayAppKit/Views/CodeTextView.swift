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
    /// Panes that scroll together, if this is one of them.
    ///
    /// Held by AppKit rather than driven from SwiftUI state: a scroll that
    /// wrote to state re-rendered the pane, which scrolled the others, which
    /// wrote to state — and the notification arrives on the next turn of the
    /// run loop, so the "this was me" flag guarded nothing. The panel came up
    /// blank because it never stopped updating.
    var sync: ScrollSync?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let made = Self.make(fontSize: fontSize)
        made.text.delegate = context.coordinator
        Self.setText(text, in: made.text, fontSize: fontSize)

        context.coordinator.textView = made.text
        context.coordinator.applyTints(tints)
        sync?.adopt(made.scroll)
        return made.scroll
    }

    /// Builds the views, away from SwiftUI, so that what AppKit needs to lay
    /// text out at all can be asserted on.
    ///
    /// All of it is needed. A text view with no frame, no `minSize`/`maxSize`
    /// and no container size is laid out into nothing — and says nothing about
    /// it: the ruler still draws its line numbers, which is how this showed up,
    /// as four numbers floating in an empty black panel.
    /// How the text is drawn.
    ///
    /// Attributed rather than assigned as a plain string: both are drawn the
    /// same — a text view applies its own `textColor` to storage that carries
    /// none — but the font and colour then live in one place instead of two,
    /// and what is typed into the view is styled by the same attributes.
    static func attributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor(Theme.Palette.textPrimary),
        ]
    }

    static func setText(_ text: String, in textView: NSTextView, fontSize: CGFloat) {
        let attributed = NSAttributedString(string: text, attributes: attributes(fontSize: fontSize))
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
        textView.isEditable = isEditable
        textView.isSelectable = true

        // Only when it actually differs: assigning the string resets the
        // selection and empties the undo stack, which for someone typing in it
        // is the editor throwing their work's history away mid-sentence.
        if textView.string != text {
            let selected = textView.selectedRange()
            Self.setText(text, in: textView, fontSize: fontSize)
            textView.setSelectedRange(NSRange(
                location: min(selected.location, text.utf16.count),
                length: 0
            ))
        }
        context.coordinator.applyTints(tints)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        weak var textView: NSTextView?

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
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
