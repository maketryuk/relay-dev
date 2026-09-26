import AppKit
import RelayUI
import SwiftUI

/// Markdown to read, drawn the way the visual editor draws it — headings,
/// lists, a quote's bar, a code block's box — so a description reads the same
/// before and after it is opened for editing.
///
/// AppKit's text view rather than SwiftUI's text, which draws a paragraph
/// and nothing a paragraph cannot hold: a quote came out as `> ` and a code
/// block as a line of monospace with nothing around it.
struct RichMarkdownText: NSViewRepresentable {
    let source: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> DecoratedTextView {
        let view = DecoratedTextView(usingTextLayoutManager: false)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.textContainerInset = .zero
        // Room for the code box's edge, which stands out a little past the
        // text on the left.
        view.textContainer?.lineFragmentPadding = 2
        // Its width is the one SwiftUI offers, set when it asks for a size;
        // it is asked before the view has a frame to take a width from.
        view.textContainer?.widthTracksTextView = false
        view.linkTextAttributes = [
            .foregroundColor: NSColor(Theme.Palette.accent),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        load(source, into: view, context: context)
        return view
    }

    func updateNSView(_ view: DecoratedTextView, context: Context) {
        guard context.coordinator.source != source else { return }
        load(source, into: view, context: context)
    }

    /// As tall as the text is at the width it is offered: SwiftUI asks for a
    /// size, and a text view has none of its own until it is told its width.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: DecoratedTextView, context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? 480
        return Self.fittingHeight(of: view, width: width).map { CGSize(width: width, height: $0) }
    }

    static func fittingHeight(of view: NSTextView, width: CGFloat) -> CGFloat? {
        guard let layout = view.layoutManager, let container = view.textContainer, let storage = view.textStorage else {
            return nil
        }
        container.widthTracksTextView = false
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        var height = layout.usedRect(for: container).maxY
        // A box that closes the text stands out below its last line.
        if let last = RichMarkdown.decorations(in: storage).last, last.0 == .codeBox, NSMaxRange(last.1) == storage.length {
            height += RichMarkdown.codeBoxInset + 1
        }
        return ceil(height)
    }

    private func load(_ source: String, into view: DecoratedTextView, context: Context) {
        context.coordinator.source = source
        view.textStorage?.setAttributedString(RichMarkdown.render(source).text)
        view.needsDisplay = true
    }

    final class Coordinator {
        var source: String?
    }
}
