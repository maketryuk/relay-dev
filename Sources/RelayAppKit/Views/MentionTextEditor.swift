import AppKit
import RelayTracker
import RelayUI
import SwiftUI

/// What the reply field knows about the mention being typed into it, shared
/// between the text view that notices it and the list that offers names.
@MainActor
@Observable
final class MentionState {
    var people: [TrackerUser] = []
    private(set) var query: MentionQuery?
    private(set) var highlighted = 0
    var isFocused = false
    /// Set by the text view: puts the chosen person in place of the query.
    @ObservationIgnored var insert: ((TrackerUser) -> Void)?

    var suggestions: [TrackerUser] {
        guard let query else { return [] }
        return MentionQuery.matches(people, for: query.text)
    }

    func update(_ query: MentionQuery?) {
        guard query != self.query else { return }
        // A new word is a new list; carrying on typing the same one keeps the
        // place only if it is still in the list.
        if query?.range.location != self.query?.range.location { highlighted = 0 }
        self.query = query
        highlighted = min(highlighted, max(0, suggestions.count - 1))
    }

    func move(by offset: Int) {
        let count = suggestions.count
        guard count > 0 else { return }
        highlighted = (highlighted + offset + count) % count
    }

    func accept(_ person: TrackerUser? = nil) {
        guard let chosen = person ?? suggestions[safe: highlighted] else { return }
        insert?(chosen)
    }

    func dismiss() {
        query = nil
    }
}

/// Several lines of text, dressed as `RelayTextEditor`, that offer the people
/// on the issue when an `@` is typed.
///
/// A text view of AppKit's rather than SwiftUI's, because the offer needs
/// the caret: SwiftUI's editor says what the text is but not where in it the
/// person is typing, and a mention is typed in the middle of a sentence as
/// often as at its end.
struct MentionTextEditor: View {
    let placeholder: String
    @Binding var text: String
    let state: MentionState
    var minHeight: CGFloat = 72

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.horizontal, Theme.Spacing.small + 2)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
                MentionTextView(text: $text, state: state)
            }
            .frame(minHeight: minHeight, alignment: .topLeading)
            .background(Theme.Palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(
                        state.isFocused ? Theme.Palette.accent.opacity(0.7) : Theme.Palette.border,
                        lineWidth: 1
                    )
            )
            .relayPointer(.text)

            if state.isFocused, !state.suggestions.isEmpty {
                MentionSuggestions(state: state)
            }
        }
    }
}

private struct MentionSuggestions: View {
    @Environment(AppModel.self) private var model
    let state: MentionState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.suggestions.enumerated()), id: \.element.id) { index, person in
                Button {
                    state.accept(person)
                } label: {
                    HStack(spacing: Theme.Spacing.small) {
                        TrackerAvatar(name: person.name, avatar: person.avatar, size: 18)
                        Text(verbatim: person.name)
                            .font(Theme.Typography.row)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                        Text(verbatim: "@\(person.login)")
                            .font(Theme.Typography.rowSecondary)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, 5)
                    .background(index == state.highlighted ? Theme.Palette.accentMuted : Color.clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()
            }
        }
        .padding(Theme.Spacing.xxsmall)
        .background(Theme.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
    }
}

private struct MentionTextView: NSViewRepresentable {
    @Binding var text: String
    let state: MentionState

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, state: state)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = MentionScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let textView = MentionNSTextView(frame: .zero)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = textView
        textView.offersSuggestions = { [weak state] in !(state?.suggestions.isEmpty ?? true) }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 12.5)
        textView.textColor = NSColor(Theme.Palette.textPrimary)
        textView.insertionPointColor = NSColor(Theme.Palette.textPrimary)
        textView.textContainerInset = NSSize(width: Theme.Spacing.small - 3, height: 8)
        // A comment is prose someone else will read in a tracker: the quotes
        // and dashes it is typed with are the ones it should arrive with.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = text
        context.coordinator.textView = textView
        state.insert = { [weak coordinator = context.coordinator] person in coordinator?.insert(person) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scroll.documentView as? NSTextView, textView.string != text else { return }
        // Cleared after a comment was sent, or filled from outside.
        textView.string = text
        context.coordinator.noticeQuery()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        let state: MentionState
        weak var textView: NSTextView?

        init(text: Binding<String>, state: MentionState) {
            self.text = text
            self.state = state
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text.wrappedValue = textView.string
            noticeQuery()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            noticeQuery()
        }

        func textDidBeginEditing(_ notification: Notification) {
            state.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            state.isFocused = false
        }

        func noticeQuery() {
            guard let textView else { return }
            let selection = textView.selectedRange()
            // A selection is not a caret: nothing is being typed at it.
            state.update(selection.length == 0
                ? MentionQuery.find(in: textView.string, caret: selection.location)
                : nil)
        }

        /// The keys that act on the list while it is open, and only then:
        /// otherwise Return is a new line and Escape closes the panel, as they
        /// always are.
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard !state.suggestions.isEmpty else { return false }
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                state.move(by: 1)
            case #selector(NSResponder.moveUp(_:)):
                state.move(by: -1)
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                state.accept()
            case #selector(NSResponder.cancelOperation(_:)):
                state.dismiss()
            default:
                return false
            }
            return true
        }

        func insert(_ person: TrackerUser) {
            guard let textView, let query = state.query else { return }
            textView.insertText(MentionQuery.insertion(for: person), replacementRange: query.range)
            state.dismiss()
        }
    }
}

/// Keeps the text view at least as tall as the field, so a click anywhere in
/// the field puts the caret in it rather than only a click on the first line.
private final class MentionScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let height = contentSize.height
        if textView.minSize.height != height {
            textView.minSize = NSSize(width: 0, height: height)
        }
    }
}

/// Keeps Escape for itself while names are on offer, so it closes the list
/// rather than the panel — and the reply half written in it.
private final class MentionNSTextView: NSTextView, EscapeConsuming {
    var offersSuggestions: () -> Bool = { false }

    var consumesEscape: Bool { offersSuggestions() }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
