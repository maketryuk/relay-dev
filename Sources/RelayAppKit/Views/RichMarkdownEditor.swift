import AppKit
import RelayUI
import SwiftUI

/// A description written the way the tracker's own editor writes one: bold,
/// headings and lists shown as they will read, with the Markdown a switch
/// away for whoever wants it.
///
/// What is edited is Markdown throughout — `RichMarkdown` draws it and writes
/// it back — so switching to the source shows exactly what will be saved, and
/// a description opened and closed here is saved as it was.
struct RichMarkdownEditor: View {
    let placeholder: String
    @Binding var markdown: String
    var minHeight: CGFloat = 260

    @State private var mode: Mode = .visual
    @State private var controller = RichTextController()

    enum Mode: Hashable {
        case visual
        case source
    }

    var body: some View {
        VStack(spacing: 0) {
            RichTextToolbar(controller: controller, mode: $mode)
            RelayDivider()
            ZStack(alignment: .topLeading) {
                if markdown.isEmpty {
                    Text(placeholder)
                        .font(mode == .visual ? .system(size: RichMarkdown.fontSize) : Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .padding(.horizontal, Theme.Spacing.small + 4)
                        .padding(.vertical, Theme.Spacing.small + 2)
                        .allowsHitTesting(false)
                }
                switch mode {
                case .visual:
                    RichTextView(markdown: $markdown, controller: controller)
                case .source:
                    TextEditor(text: $markdown)
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, Theme.Spacing.small - 2)
                        .padding(.vertical, Theme.Spacing.xsmall + 2)
                }
            }
            .frame(minHeight: minHeight, alignment: .topLeading)
        }
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(controller.isFocused ? Theme.Palette.accent.opacity(0.7) : Theme.Palette.border, lineWidth: 1)
        )
        .relayPointer(.text)
    }
}

// MARK: - Toolbar

private struct RichTextToolbar: View {
    let controller: RichTextController
    @Binding var mode: RichMarkdownEditor.Mode

    private var selection: RichTextController.Selection { controller.selection }
    private var isVisual: Bool { mode == .visual }

    /// Spelled out rather than taken from `@Bindable` in the body, which the
    /// newest compiler refuses.
    private var isEditingLink: Binding<Bool> {
        Binding(get: { controller.isEditingLink }, set: { controller.isEditingLink = $0 })
    }

    var body: some View {
        HStack(spacing: 2) {
            blockMenu
            separator
            button("bold", relayLocalized("Bold"), shortcut: "⌘B", isOn: selection.strong) { controller.toggle(.richStrong) }
            button("italic", relayLocalized("Italic"), shortcut: "⌘I", isOn: selection.emphasis) { controller.toggle(.richEmphasis) }
            button("strikethrough", relayLocalized("Strikethrough"), shortcut: "⇧⌘X", isOn: selection.strike) {
                controller.toggle(.richStrike)
            }
            separator
            button("text.quote", relayLocalized("Quote"), isOn: selection.block == .quote) { controller.toggleBlock(.quote) }
            button("chevron.left.forwardslash.chevron.right", relayLocalized("Code"), shortcut: "⌘E", isOn: selection.code) {
                controller.toggle(.richCode)
            }
            button("link", relayLocalized("Link"), shortcut: "⌘K", isOn: selection.link != nil) { controller.beginLink() }
                .popover(isPresented: isEditingLink, arrowEdge: .bottom) {
                    LinkEditor(controller: controller)
                }
            separator
            button("list.bullet", relayLocalized("Bulleted List"), isOn: selection.list == .bullet) { controller.toggleList(ordered: false) }
            button("list.number", relayLocalized("Numbered List"), isOn: selection.list == .ordered) { controller.toggleList(ordered: true) }

            Spacer(minLength: Theme.Spacing.small)

            modeSwitch
        }
        .padding(.horizontal, Theme.Spacing.xsmall + 2)
        .frame(height: 36)
    }

    private var separator: some View {
        RelayDivider(axis: .vertical)
            .frame(height: 16)
            .padding(.horizontal, Theme.Spacing.xsmall)
    }

    private func button(
        _ systemImage: String,
        _ label: String,
        shortcut: String? = nil,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        IconButton(systemImage: systemImage, size: 26, isSelected: isVisual && isOn, isEnabled: isVisual, action: action)
            .relayTooltip(label, shortcut: shortcut)
    }

    private var blockMenu: some View {
        Menu {
            ForEach(RichTextController.blockChoices, id: \.rawValue) { block in
                Button {
                    controller.setBlock(block)
                } label: {
                    if block == selection.block {
                        Label(Self.title(of: block), systemImage: "checkmark")
                    } else {
                        Text(Self.title(of: block))
                    }
                }
            }
        } label: {
            HStack(spacing: Theme.Spacing.xsmall) {
                Text(Self.title(of: selection.block))
                    .font(Theme.Typography.row)
                    .foregroundStyle(isVisual ? Theme.Palette.textSecondary : Theme.Palette.textTertiary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .frame(width: 132, height: 26, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .clickable(isVisual)
        .disabled(!isVisual)
    }

    static func title(of block: RichMarkdown.Block) -> String {
        switch block {
        case .paragraph, .raw: relayLocalized("Normal Text")
        case .heading(1): relayLocalized("Heading 1")
        case .heading(2): relayLocalized("Heading 2")
        case .heading: relayLocalized("Heading 3")
        case .quote: relayLocalized("Quote")
        case .code: relayLocalized("Code Block")
        }
    }

    private var modeSwitch: some View {
        HStack(spacing: 0) {
            modeButton(relayLocalized("Visual"), .visual)
            modeButton(relayLocalized("Markdown"), .source)
        }
        .padding(2)
        .background(Theme.Palette.base)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
    }

    private func modeButton(_ title: String, _ target: RichMarkdownEditor.Mode) -> some View {
        Button {
            mode = target
        } label: {
            Text(title)
                .font(Theme.Typography.rowSecondary)
                .foregroundStyle(mode == target ? Theme.Palette.textPrimary : Theme.Palette.textTertiary)
                .padding(.horizontal, Theme.Spacing.small)
                .frame(height: 22)
                .background(mode == target ? Theme.Palette.surfaceActive : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small - 2, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
    }
}

private struct LinkEditor: View {
    @Bindable var controller: RichTextController

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            RelayTextField("https://", text: $controller.linkDraft, systemImage: "link", autofocus: true) {
                controller.applyLink(controller.linkDraft)
            }
            HStack(spacing: Theme.Spacing.small) {
                if controller.selection.link != nil {
                    RelayButton(relayLocalized("Remove Link"), kind: .ghost) { controller.applyLink(nil) }
                }
                Spacer()
                RelayButton(relayLocalized("Apply"), kind: .primary) { controller.applyLink(controller.linkDraft) }
                    .disabled(controller.linkDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(Theme.Spacing.medium)
        .frame(width: 340)
    }
}

// MARK: - Controller

/// What the toolbar does to the text, and what it shows about the text under
/// the caret. Every change goes through the text view's own editing calls, so
/// each one is a step Undo can take back.
@MainActor
@Observable
final class RichTextController {
    enum ListKind: Equatable {
        case bullet
        case ordered
    }

    struct Selection: Equatable {
        var strong = false
        var emphasis = false
        var strike = false
        var code = false
        var link: String?
        var block: RichMarkdown.Block = .paragraph
        var list: ListKind?
    }

    static let blockChoices: [RichMarkdown.Block] = [.paragraph, .heading(1), .heading(2), .heading(3), .code("")]

    private(set) var selection = Selection()
    var isFocused = false
    var isEditingLink = false
    var linkDraft = ""

    @ObservationIgnored weak var textView: NSTextView?

    // MARK: Reading the caret

    func refreshSelection() {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        let attributes: [NSAttributedString.Key: Any]
        if range.length == 0 || storage.length == 0 {
            attributes = view.typingAttributes
        } else {
            attributes = storage.attributes(at: min(range.location, storage.length - 1), effectiveRange: nil)
        }
        let paragraph = paragraphAttributes(at: range.location)
        let lists = (paragraph[.paragraphStyle] as? NSParagraphStyle)?.textLists ?? []
        var list: ListKind?
        if let last = lists.last { list = RichTextController.isOrdered(last) ? .ordered : .bullet }
        let next = Selection(
            strong: attributes[.richStrong] != nil,
            emphasis: attributes[.richEmphasis] != nil,
            strike: attributes[.richStrike] != nil,
            code: attributes[.richCode] != nil,
            link: RichMarkdown.linkTarget(attributes[.link]),
            block: RichMarkdown.Block(rawValue: paragraph[.richBlock] as? String),
            list: list
        )
        if next != selection { selection = next }
    }

    private func paragraphAttributes(at location: Int) -> [NSAttributedString.Key: Any] {
        guard let view = textView, let storage = view.textStorage, storage.length > 0 else {
            return textView?.typingAttributes ?? [:]
        }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: min(location, storage.length), length: 0))
        if paragraph.length == 0 { return view.typingAttributes }
        return storage.attributes(at: paragraph.location, effectiveRange: nil)
    }

    static func isOrdered(_ list: NSTextList) -> Bool {
        ![NSTextList.MarkerFormat.disc, .circle, .square, .hyphen, .box, .check, .diamond].contains(list.markerFormat)
    }

    // MARK: Marks

    /// Bold, italic, struck or code, on the selection or, with nothing
    /// selected, on what is typed next.
    func toggle(_ key: NSAttributedString.Key) {
        guard let view = textView, let storage = view.textStorage else { return }
        let range = view.selectedRange()
        if range.length == 0 {
            var typing = view.typingAttributes
            typing[key] = typing[key] == nil ? true : nil
            let block = RichMarkdown.Block(rawValue: paragraphAttributes(at: range.location)[.richBlock] as? String)
            for dropped in [NSAttributedString.Key.backgroundColor, .strikethroughStyle, .underlineStyle] {
                typing[dropped] = nil
            }
            typing.merge(RichMarkdown.look(of: typing, in: block)) { $1 }
            view.typingAttributes = typing
            refreshSelection()
            return
        }
        var everywhere = true
        storage.enumerateAttribute(key, in: range) { value, _, stop in
            if value == nil {
                everywhere = false
                stop.pointee = true
            }
        }
        change(range) { storage in
            if everywhere {
                storage.removeAttribute(key, range: range)
            } else {
                storage.addAttribute(key, value: true, range: range)
            }
        }
    }

    // MARK: Links

    func beginLink() {
        refreshSelection()
        linkDraft = selection.link ?? ""
        isEditingLink = true
    }

    /// Links the selection, or with nothing selected the link the caret is
    /// in; nil takes the link off. With nothing selected and no link there,
    /// the address itself goes in as its own link.
    func applyLink(_ typed: String?) {
        isEditingLink = false
        guard let view = textView, let storage = view.textStorage else { return }
        defer { view.window?.makeFirstResponder(view) }
        let target = typed?.trimmingCharacters(in: .whitespacesAndNewlines)
        var range = view.selectedRange()
        if range.length == 0, storage.length > 0, range.location < storage.length || range.location > 0 {
            let at = range.location < storage.length ? range.location : range.location - 1
            var effective = NSRange()
            if storage.attribute(.link, at: at, longestEffectiveRange: &effective, in: NSRange(location: 0, length: storage.length)) != nil {
                range = effective
            }
        }
        if range.length == 0 {
            guard let target, !target.isEmpty else { return }
            var attributes = view.typingAttributes
            attributes[.link] = target
            let block = RichMarkdown.Block(rawValue: paragraphAttributes(at: range.location)[.richBlock] as? String)
            attributes.merge(RichMarkdown.look(of: attributes, in: block)) { $1 }
            let inserted = NSAttributedString(string: target, attributes: attributes)
            guard view.shouldChangeText(in: range, replacementString: target) else { return }
            storage.replaceCharacters(in: range, with: inserted)
            view.didChangeText()
            return
        }
        change(range) { storage in
            if let target, !target.isEmpty {
                storage.addAttribute(.link, value: target, range: range)
            } else {
                storage.removeAttribute(.link, range: range)
            }
        }
    }

    // MARK: Paragraphs

    /// A heading, code or normal text for every paragraph the selection
    /// touches. A list item stops being one: Markdown has no heading in a list.
    func setBlock(_ block: RichMarkdown.Block) {
        rewriteParagraphs { paragraph in
            let text = NSMutableAttributedString(attributedString: Self.withoutMarker(paragraph))
            let whole = NSRange(location: 0, length: text.length)
            text.addAttribute(.richBlock, value: block.rawValue, range: whole)
            text.addAttribute(.paragraphStyle, value: RichMarkdown.paragraphStyle(for: block), range: whole)
            return text
        }
    }

    /// Quote on, or off again when every paragraph is one already.
    func toggleBlock(_ block: RichMarkdown.Block) {
        refreshSelection()
        setBlock(selection.block == block ? .paragraph : block)
    }

    /// Makes the paragraphs one list, numbered from one, or takes them out of
    /// it when they already are that kind of list.
    func toggleList(ordered: Bool) {
        refreshSelection()
        let kind: ListKind = ordered ? .ordered : .bullet
        let removing = selection.list == kind
        let list = NSTextList(markerFormat: ordered ? RichMarkdown.orderedMarker : .disc, options: 0)
        var number = 1
        rewriteParagraphs { paragraph in
            let text = NSMutableAttributedString(attributedString: Self.withoutMarker(paragraph))
            let whole = NSRange(location: 0, length: text.length)
            text.addAttribute(.richBlock, value: RichMarkdown.Block.paragraph.rawValue, range: whole)
            if removing {
                text.addAttribute(.paragraphStyle, value: RichMarkdown.paragraphStyle(for: .paragraph), range: whole)
                return text
            }
            let attributes = text.length > 0 ? text.attributes(at: 0, effectiveRange: nil) : [:]
            text.insert(NSAttributedString(string: "\t\(list.marker(forItemNumber: number))\t", attributes: attributes), at: 0)
            text.addAttribute(.paragraphStyle, value: RichMarkdown.listStyle([list]), range: NSRange(location: 0, length: text.length))
            number += 1
            return text
        }
    }

    /// A paragraph without the marker AppKit keeps at the start of a list
    /// item, and without the list.
    private static func withoutMarker(_ paragraph: NSAttributedString) -> NSAttributedString {
        let style = paragraph.length > 0 ? paragraph.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
        guard let style, !style.textLists.isEmpty else { return paragraph }
        let string = paragraph.string as NSString
        var start = 0
        if string.hasPrefix("\t") {
            let second = string.range(of: "\t", range: NSRange(location: 1, length: string.length - 1))
            if second.location != NSNotFound { start = NSMaxRange(second) }
        }
        let rest = NSMutableAttributedString(attributedString: paragraph.attributedSubstring(from: NSRange(location: start, length: string.length - start)))
        rest.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: rest.length))
        return rest
    }

    /// Replaces every paragraph the selection touches with what `transform`
    /// makes of it, as one edit, keeping the caret where it was in its text.
    private func rewriteParagraphs(_ transform: (NSAttributedString) -> NSAttributedString) {
        guard let view = textView, let storage = view.textStorage else { return }
        let string = storage.string as NSString
        let selected = view.selectedRange()
        let affected = string.paragraphRange(for: selected)
        let replacement = NSMutableAttributedString()
        var caretShift = 0
        var spansParagraphs = false
        var emptyCaretParagraph: [NSAttributedString.Key: Any]?
        var paragraphs: [(range: NSRange, enclosing: NSRange)] = []
        string.enumerateSubstrings(in: affected, options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
            paragraphs.append((range, enclosing))
        }
        // The empty line after the last line break is a paragraph too, and
        // the one a caret at the very end is in; nothing lists it.
        if NSMaxRange(selected) == string.length, string.length == 0 || string.hasSuffix("\n") {
            let end = NSRange(location: string.length, length: 0)
            paragraphs.append((end, end))
        }
        for (range, enclosing) in paragraphs {
            let body = storage.attributedSubstring(from: range)
            let made = NSMutableAttributedString(attributedString: transform(body))
            // What the paragraph now is has to be on its line break as well,
            // and an empty paragraph has nothing else to say it with.
            let described = made.length > 0 ? made : NSMutableAttributedString(attributedString: transform(NSAttributedString(string: " ", attributes: view.typingAttributes)))
            let now = described.attributes(at: max(described.length - 1, 0), effectiveRange: nil)
            if made.length == 0, NSLocationInRange(selected.location, enclosing) || selected.location == NSMaxRange(enclosing) {
                emptyCaretParagraph = now
            }
            let terminator = NSMutableAttributedString(attributedString: storage.attributedSubstring(
                from: NSRange(location: NSMaxRange(range), length: NSMaxRange(enclosing) - NSMaxRange(range))
            ))
            for key in [NSAttributedString.Key.richBlock, .paragraphStyle] {
                if let value = now[key], terminator.length > 0 {
                    terminator.addAttribute(key, value: value, range: NSRange(location: 0, length: terminator.length))
                }
            }
            if NSLocationInRange(selected.location, enclosing) || selected.location == NSMaxRange(enclosing) && NSMaxRange(enclosing) == string.length {
                caretShift = made.length - body.length
            } else if enclosing.location > selected.location {
                spansParagraphs = true
            }
            made.append(terminator)
            replacement.append(made)
        }
        guard view.shouldChangeText(in: affected, replacementString: replacement.string) else { return }
        storage.beginEditing()
        storage.replaceCharacters(in: affected, with: replacement)
        RichMarkdown.present(storage, in: NSRange(location: affected.location, length: replacement.length))
        storage.endEditing()
        view.didChangeText()
        if spansParagraphs || selected.length > 0 {
            let trailing = replacement.string.hasSuffix("\n") ? 1 : 0
            view.setSelectedRange(NSRange(location: affected.location, length: max(0, replacement.length - trailing)))
        } else {
            view.setSelectedRange(NSRange(location: max(affected.location, selected.location + caretShift), length: 0))
        }
        // An empty paragraph is what is typed into it next. After the caret
        // is placed, which takes what is typed from the character before it.
        if let emptyCaretParagraph {
            var typing = view.typingAttributes
            typing.merge(emptyCaretParagraph) { $1 }
            view.typingAttributes = typing
        }
        refreshSelection()
    }

    private func change(_ range: NSRange, _ body: (NSTextStorage) -> Void) {
        guard let view = textView, let storage = view.textStorage,
              view.shouldChangeText(in: range, replacementString: nil)
        else { return }
        storage.beginEditing()
        body(storage)
        RichMarkdown.present(storage, in: range)
        storage.endEditing()
        view.didChangeText()
        refreshSelection()
    }

    // MARK: Return

    /// What Return does outside a list, where AppKit already knows: after a
    /// heading the next line is text, and on an empty line of a quote or a
    /// block of code it leaves the quote or the code. False leaves Return to
    /// AppKit.
    func handleReturn() -> Bool {
        guard let view = textView, let storage = view.textStorage else { return false }
        let caret = view.selectedRange()
        let attributes = paragraphAttributes(at: caret.location)
        if let style = attributes[.paragraphStyle] as? NSParagraphStyle, !style.textLists.isEmpty { return false }
        let paragraph = (storage.string as NSString).paragraphRange(for: caret)
        let content = (storage.string as NSString).substring(with: paragraph).trimmingCharacters(in: .newlines)
        switch RichMarkdown.Block(rawValue: attributes[.richBlock] as? String) {
        case .heading:
            view.insertNewline(nil)
            var typing: [NSAttributedString.Key: Any] = [.richBlock: RichMarkdown.Block.paragraph.rawValue]
            typing.merge(RichMarkdown.look(of: typing, in: .paragraph)) { $1 }
            typing[.paragraphStyle] = RichMarkdown.paragraphStyle(for: .paragraph)
            view.typingAttributes = typing
            refreshSelection()
            return true
        case .quote, .code:
            guard content.isEmpty else { return false }
            setBlock(.paragraph)
            return true
        default:
            return false
        }
    }
}

// MARK: - Text view

private struct RichTextView: NSViewRepresentable {
    @Binding var markdown: String
    let controller: RichTextController

    func makeCoordinator() -> Coordinator {
        Coordinator(markdown: $markdown, controller: controller)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = RichScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        // TextKit 1, because its lists are AppKit's own: Return makes the next
        // item, Tab nests it, Return on an empty one ends the list. The newer
        // text system keeps none of that.
        let textView = RichNSTextView(usingTextLayoutManager: false)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.usesFontPanel = false
        textView.insertionPointColor = NSColor(Theme.Palette.textPrimary)
        textView.textContainerInset = NSSize(width: Theme.Spacing.small - 1, height: Theme.Spacing.small + 2)
        textView.linkTextAttributes = [
            .foregroundColor: NSColor(Theme.Palette.accent),
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.iBeam,
        ]
        // Prose for other people to read: it should arrive with the quotes
        // and dashes it was typed with.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.delegate = context.coordinator
        textView.controller = controller
        scroll.documentView = textView

        controller.textView = textView
        context.coordinator.load(markdown, into: textView)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.markdown = $markdown
        guard let textView = scroll.documentView as? NSTextView, markdown != context.coordinator.written else { return }
        // Filled or cleared from outside: drawn again from what it now says.
        context.coordinator.load(markdown, into: textView)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var markdown: Binding<String>
        let controller: RichTextController
        private var document: RichMarkdown.Document?
        /// What was last written into the binding from here, so that an
        /// update carrying it back is not taken for a change from outside.
        private(set) var written: String?

        init(markdown: Binding<String>, controller: RichTextController) {
            self.markdown = markdown
            self.controller = controller
        }

        func load(_ source: String, into textView: NSTextView) {
            let document = RichMarkdown.render(source)
            self.document = document
            written = source
            textView.textStorage?.setAttributedString(document.text)
            var typing: [NSAttributedString.Key: Any] = [.richBlock: RichMarkdown.Block.paragraph.rawValue]
            typing.merge(RichMarkdown.look(of: typing, in: .paragraph)) { $1 }
            typing[.paragraphStyle] = RichMarkdown.paragraphStyle(for: .paragraph)
            if document.text.length == 0 { textView.typingAttributes = typing }
            controller.refreshSelection()
        }

        /// Typed text takes the look of what it follows, spacing and all: a
        /// new last line of code would keep the gap the old last line had
        /// below it, inside the box. So what changed is drawn again from what
        /// it is.
        private var edited: NSRange?

        func textDidChange(_ notification: Notification) {
            guard let textView = controller.textView, let storage = textView.textStorage else { return }
            if let edited {
                RichMarkdown.present(storage, in: edited)
                self.edited = nil
            }
            let source = RichMarkdown.markdown(from: storage, keeping: document)
            written = source
            if markdown.wrappedValue != source { markdown.wrappedValue = source }
            controller.refreshSelection()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            controller.refreshSelection()
        }

        /// Where the text is about to change, so the change can be drawn
        /// again once it has.
        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            edited = NSRange(location: range.location, length: (replacementString as NSString?)?.length ?? range.length)
            return true
        }

        func textDidBeginEditing(_ notification: Notification) {
            controller.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            controller.isFocused = false
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) { return controller.handleReturn() }
            return false
        }

        /// A link in text being written is text to be edited; ⌘-click is how
        /// to follow it.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            guard NSEvent.modifierFlags.contains(.command),
                  let target = RichMarkdown.linkTarget(link).flatMap(URL.init(string:))
            else { return true }
            NSWorkspace.shared.open(target)
            return true
        }
    }
}

/// The shortcuts a formatting toolbar is expected to have, Shift-Return for a
/// line break within a paragraph, and paste as text — what comes in from a
/// web page brings its fonts and colours, and those are not Markdown.
private final class RichNSTextView: DecoratedTextView {
    weak var controller: RichTextController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let controller else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        switch (flags, event.charactersIgnoringModifiers?.lowercased()) {
        case (.command, "b"): controller.toggle(.richStrong)
        case (.command, "i"): controller.toggle(.richEmphasis)
        case (.command, "e"): controller.toggle(.richCode)
        case (.command, "k"): controller.beginLink()
        case ([.command, .shift], "x"): controller.toggle(.richStrike)
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .shift, event.keyCode == 36 || event.keyCode == 76 {
            insertLineBreak(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        pasteAsPlainText(sender)
    }

    /// A box that grows or shrinks by a line spans more than the lines that
    /// changed, which is all AppKit would otherwise draw again.
    override func didChangeText() {
        super.didChangeText()
        needsDisplay = true
    }
}

/// A text view that draws what `RichMarkdown` puts behind the text: the one
/// a description is written in and the one it is read in look the same.
class DecoratedTextView: NSTextView {
    /// The bar beside a quote and the box behind code, under the text. The
    /// lines' used rectangles are what the text covers; the paragraph spacing
    /// around a code block is what the box's margin stands in.
    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let textContainer, let storage = textStorage else { return }
        let origin = textContainerOrigin
        let padding = textContainer.lineFragmentPadding
        for (decoration, range) in RichMarkdown.decorations(in: storage) {
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var top = CGFloat.greatestFiniteMagnitude
            var bottom = -CGFloat.greatestFiniteMagnitude
            layoutManager.enumerateLineFragments(forGlyphRange: glyphs) { _, used, _, _, _ in
                top = min(top, used.minY)
                bottom = max(bottom, used.maxY)
            }
            guard top < bottom else { continue }
            switch decoration {
            case .quoteBar:
                let bar = NSRect(x: origin.x + padding, y: origin.y + top, width: 3, height: bottom - top)
                NSColor(Theme.Palette.textTertiary).setFill()
                NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
            case .codeBox:
                let inset = RichMarkdown.codeBoxInset
                let box = NSRect(
                    x: origin.x + padding - 2,
                    y: origin.y + top - inset,
                    width: textContainer.size.width - padding * 2 + 4,
                    height: bottom - top + inset * 2
                )
                let path = NSBezierPath(roundedRect: box, xRadius: Theme.Radius.small, yRadius: Theme.Radius.small)
                NSColor(Theme.Palette.surfaceRaised).setFill()
                path.fill()
                NSColor(Theme.Palette.borderStrong).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
    }

}

/// Keeps the text view at least as tall as the field, so a click anywhere in
/// it puts the caret in the text rather than only a click on the first line.
private final class RichScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let textView = documentView as? NSTextView else { return }
        let height = contentSize.height
        if textView.minSize.height != height {
            textView.minSize = NSSize(width: 0, height: height)
        }
    }
}
