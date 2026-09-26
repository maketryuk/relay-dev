import AppKit
import cmark_gfm
import cmark_gfm_extensions
import RelayUI

extension NSAttributedString.Key {
    /// What a paragraph is — a `RichMarkdown.Block`, by its raw value.
    static let richBlock = NSAttributedString.Key("relay.rich.block")
    /// Which block of the source a paragraph was drawn from.
    static let richOrigin = NSAttributedString.Key("relay.rich.origin")
    static let richStrong = NSAttributedString.Key("relay.rich.strong")
    static let richEmphasis = NSAttributedString.Key("relay.rich.emphasis")
    static let richStrike = NSAttributedString.Key("relay.rich.strike")
    static let richCode = NSAttributedString.Key("relay.rich.code")
    /// Markdown kept as it was written, because it is something the editor
    /// draws as its source: a picture, a piece of HTML.
    static let richRaw = NSAttributedString.Key("relay.rich.raw")
}

/// Markdown as text with its formatting on, and back again.
///
/// The tracker keeps Markdown and so does everyone else's editor, so what is
/// saved from here has to be Markdown that says what theirs would — and must
/// not rewrite what nobody touched. Every block is drawn with the source it
/// came from, and a block that reads the same when it is saved goes back as
/// that source, byte for byte: a description someone wrote with `__bold__`
/// and a setext heading keeps both, and only the paragraph that was edited
/// comes back in the editor's own spelling.
///
/// What the editor does not draw — a table, a block of HTML, a task list, a
/// picture YouTrack names by its attachment — is shown as the Markdown it is,
/// in a face of its own, and written back as that text. Nothing is lost by
/// opening a description here; the worst it gets is shown as written.
///
/// On the main actor for the fonts and the colours, which are AppKit's.
@MainActor
enum RichMarkdown {
    enum Block: Equatable {
        case paragraph
        case heading(Int)
        case quote
        /// A fenced block, and what its fence says after the backticks.
        case code(String)
        /// Source the editor shows as it is.
        case raw

        var rawValue: String {
            switch self {
            case .paragraph: "p"
            case let .heading(level): "h\(level)"
            case .quote: "quote"
            case let .code(info): "code:\(info)"
            case .raw: "raw"
            }
        }

        init(rawValue: String?) {
            guard let rawValue else {
                self = .paragraph
                return
            }
            if rawValue.hasPrefix("code:") {
                self = .code(String(rawValue.dropFirst(5)))
            } else if rawValue.hasPrefix("h"), let level = Int(rawValue.dropFirst()), (1 ... 6).contains(level) {
                self = .heading(level)
            } else {
                switch rawValue {
                case "quote": self = .quote
                case "raw": self = .raw
                default: self = .paragraph
                }
            }
        }
    }

    /// A description as the editor opens it.
    struct Document {
        let source: String
        let text: NSAttributedString
        fileprivate let origins: [Origin]
        /// Lines before the first block — link definitions, as a rule — which
        /// are no block of their own and go back where they were.
        fileprivate let head: String
    }

    fileprivate struct Origin {
        let source: String
        /// Lines after the block that belong to no block, kept with it.
        let tail: String
        let signature: [Run]
    }

    // MARK: - Reading

    static func render(_ markdown: String) -> Document {
        let source = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = source.components(separatedBy: "\n")
        let text = NSMutableAttributedString()
        var origins: [Origin] = []
        var head = ""

        withDocument(source) { document in
            let blocks = children(of: document).sorted { cmark_node_get_start_line($0) < cmark_node_get_start_line($1) }
            if let first = blocks.first {
                head = slice(lines, from: 1, to: Int(cmark_node_get_start_line(first)) - 1)
            }
            for (index, block) in blocks.enumerated() {
                let start = Int(cmark_node_get_start_line(block))
                let end = max(start, Int(cmark_node_get_end_line(block)))
                let next = index + 1 < blocks.count ? Int(cmark_node_get_start_line(blocks[index + 1])) : lines.count + 1
                let own = slice(lines, from: start, to: end)
                let tail = slice(lines, from: end + 1, to: next - 1)

                let drawn = paragraphs(of: block) ?? rawParagraphs(own)
                if text.length > 0 { text.append(NSAttributedString(string: "\n")) }
                let location = text.length
                for (offset, paragraph) in drawn.enumerated() {
                    if offset > 0 {
                        text.append(NSAttributedString(string: "\n", attributes: paragraphAttributes(ending: offset - 1, of: drawn)))
                    }
                    text.append(paragraph)
                }
                let range = NSRange(location: location, length: text.length - location)
                text.addAttribute(.richOrigin, value: origins.count, range: range)
                origins.append(Origin(source: own, tail: tail, signature: signature(of: text, in: range)))
            }
        }
        present(text, in: NSRange(location: 0, length: text.length))
        return Document(source: markdown, text: text, origins: origins, head: head)
    }

    // MARK: - Writing

    /// The text as Markdown, with every block that reads as it did when it
    /// was opened written as it was written then.
    static func markdown(from text: NSAttributedString, keeping document: Document? = nil) -> String {
        let whole = NSRange(location: 0, length: text.length)
        if let document, signature(of: text, in: whole) == signature(of: document.text, in: NSRange(location: 0, length: document.text.length)) {
            return document.source
        }

        let groups = self.groups(in: text)
        var lastGroupOfOrigin: [Int: Int] = [:]
        for (index, group) in groups.enumerated() {
            if let origin = group.origin { lastGroupOfOrigin[origin] = index }
        }

        var chunks: [String] = []
        if let head = document?.head, !head.isEmpty { chunks.append(head) }
        for (index, group) in groups.enumerated() {
            if let origin = group.origin, let kept = document?.origins[safe: origin],
               signature(of: text, in: group.range) == kept.signature {
                chunks.append(kept.source)
            } else {
                let written = write(group, in: text)
                if !written.isEmpty { chunks.append(written) }
            }
            if let origin = group.origin, lastGroupOfOrigin[origin] == index,
               let tail = document?.origins[safe: origin]?.tail, !tail.isEmpty {
                chunks.append(tail)
            }
        }
        // A block deleted whole leaves its link definitions behind: another
        // block may still point at them.
        for (origin, kept) in (document?.origins ?? []).enumerated()
            where lastGroupOfOrigin[origin] == nil && !kept.tail.isEmpty {
            chunks.append(kept.tail)
        }
        return chunks.joined(separator: "\n\n")
    }

    // MARK: - Presentation

    static let fontSize: CGFloat = 13

    /// Sets how every character looks from what it is. What it is — strong,
    /// a heading, a list item — is kept in attributes of its own, and the
    /// fonts and colours are only ever drawn from those, so a heading's bold
    /// face is never mistaken for bold text.
    static func present(_ text: NSMutableAttributedString, in range: NSRange) {
        guard text.length > 0 else { return }
        let string = text.string as NSString
        var covered = string.paragraphRange(for: NSRange(location: min(range.location, text.length), length: min(range.length, text.length - min(range.location, text.length))))
        // A paragraph either side as well: a code block is spaced from what
        // is around it by its first and last lines, and an edit changes which
        // lines those are.
        if covered.location > 0 {
            covered = NSUnionRange(covered, string.paragraphRange(for: NSRange(location: covered.location - 1, length: 0)))
        }
        if NSMaxRange(covered) < string.length {
            covered = NSUnionRange(covered, string.paragraphRange(for: NSRange(location: NSMaxRange(covered), length: 0)))
        }
        string.enumerateSubstrings(in: covered, options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            let at = min(enclosing.location, text.length - 1)
            let block = Block(rawValue: text.attribute(.richBlock, at: at, effectiveRange: nil) as? String)
            let existing = text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
            let previous = enclosing.location > 0 ? blockOfParagraph(in: text, containing: enclosing.location - 1) : nil
            let next = NSMaxRange(enclosing) < text.length ? blockOfParagraph(in: text, containing: NSMaxRange(enclosing)) : nil
            text.addAttribute(
                .paragraphStyle,
                value: paragraphStyle(for: block, keeping: existing, after: previous, before: next),
                range: enclosing
            )
            text.enumerateAttributes(in: enclosing) { attributes, run, _ in
                let wanted = look(of: attributes, in: block)
                text.addAttributes(wanted, range: run)
                for key in [NSAttributedString.Key.backgroundColor, .strikethroughStyle, .underlineStyle] where wanted[key] == nil {
                    text.removeAttribute(key, range: run)
                }
            }
        }
    }

    private static func blockOfParagraph(in text: NSAttributedString, containing location: Int) -> Block {
        let paragraph = (text.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        return Block(rawValue: text.attribute(.richBlock, at: min(paragraph.location, text.length - 1), effectiveRange: nil) as? String)
    }

    /// How far a code block's box stands out from its text: its first line
    /// is spaced from what is above by more than this, its last from what is
    /// below, so the box never covers a neighbour.
    static let codeBoxInset: CGFloat = 8

    /// `previous` and `next` are the blocks of the paragraphs around it: a
    /// quote or a code block is spaced as one piece from what surrounds it,
    /// and its lines sit together inside.
    static func paragraphStyle(
        for block: Block,
        keeping existing: NSParagraphStyle? = nil,
        after previous: Block? = nil,
        before next: Block? = nil
    ) -> NSParagraphStyle {
        if let existing, !existing.textLists.isEmpty {
            let style = (existing.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
            style.paragraphSpacing = 3
            return style
        }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 1.5
        switch block {
        case .paragraph:
            style.paragraphSpacing = 8
        case let .heading(level):
            style.paragraphSpacingBefore = level <= 2 ? 8 : 4
            style.paragraphSpacing = 6
        case .quote:
            style.headIndent = 18
            style.firstLineHeadIndent = 18
            style.paragraphSpacingBefore = previous == .quote ? 0 : 4
            style.paragraphSpacing = next == .quote ? 6 : 10
        case .code:
            let inside = { (other: Block?) -> Bool in if case .code = other { true } else { false } }
            style.headIndent = 14
            style.firstLineHeadIndent = 14
            style.tailIndent = -14
            style.lineSpacing = 1
            style.paragraphSpacingBefore = inside(previous) ? 0 : codeBoxInset + 6
            style.paragraphSpacing = inside(next) ? 0 : codeBoxInset + 6
        case .raw:
            style.paragraphSpacing = 2
        }
        return style
    }

    /// What is drawn behind the text rather than as part of it: a bar down
    /// the side of each quote, a box behind each block of code. Consecutive
    /// paragraphs of either are one piece.
    enum Decoration: Equatable {
        case quoteBar
        case codeBox
    }

    static func decorations(in text: NSAttributedString) -> [(Decoration, NSRange)] {
        guard text.length > 0 else { return [] }
        var found: [(Decoration, NSRange)] = []
        let string = text.string as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let decoration: Decoration?
            switch blockOfParagraph(in: text, containing: min(range.location, text.length - 1)) {
            case .quote: decoration = .quoteBar
            case .code: decoration = .codeBox
            default: decoration = nil
            }
            guard let decoration else { return }
            if let last = found.last, last.0 == decoration, NSMaxRange(last.1) + 1 >= range.location {
                found[found.count - 1].1 = NSUnionRange(last.1, range)
            } else {
                found.append((decoration, range))
            }
        }
        return found
    }

    /// A list item's paragraph, indented as AppKit indents one when Tab
    /// nests it, so an item drawn here and an item made by typing line up.
    static func listStyle(_ lists: [NSTextList]) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.textLists = lists
        let level = CGFloat(lists.count)
        style.tabStops = [
            NSTextTab(textAlignment: .left, location: 36 * (level - 1) + 11),
            NSTextTab(textAlignment: .left, location: 36 * level),
        ]
        style.headIndent = 36 * level
        style.paragraphSpacing = 3
        return style
    }

    static func font(for block: Block, strong: Bool = false, emphasis: Bool = false, code: Bool = false) -> NSFont {
        var font: NSFont
        switch block {
        case .code, .raw:
            font = .monospacedSystemFont(ofSize: fontSize - 1, weight: strong ? .semibold : .regular)
        case let .heading(level):
            let sizes: [CGFloat] = [21, 18, 15.5, 14, 13, 13]
            font = .systemFont(ofSize: sizes[min(level, 6) - 1], weight: .semibold)
        case .paragraph, .quote:
            font = code
                ? .monospacedSystemFont(ofSize: fontSize - 1, weight: strong ? .semibold : .regular)
                : .systemFont(ofSize: fontSize, weight: strong ? .semibold : .regular)
        }
        if emphasis {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font
    }

    /// How characters with these attributes look in a paragraph of this kind.
    static func look(of attributes: [NSAttributedString.Key: Any], in block: Block) -> [NSAttributedString.Key: Any] {
        let strong = attributes[.richStrong] != nil
        let emphasis = attributes[.richEmphasis] != nil
        let code = attributes[.richCode] != nil
        let raw = attributes[.richRaw] != nil
        var look: [NSAttributedString.Key: Any] = [
            .font: raw ? font(for: .raw) : font(for: block, strong: strong, emphasis: emphasis, code: code),
        ]
        switch block {
        case .raw:
            look[.foregroundColor] = NSColor(Theme.Palette.textSecondary)
        case .quote:
            look[.foregroundColor] = NSColor(Theme.Palette.textSecondary)
        case .code:
            // The box behind it is drawn by the text view, whole: a colour
            // behind each character stops where the characters do.
            look[.foregroundColor] = NSColor(Theme.Palette.textPrimary)
        case .paragraph, .heading:
            look[.foregroundColor] = NSColor(Theme.Palette.textPrimary)
        }
        if raw {
            look[.foregroundColor] = NSColor(Theme.Palette.textTertiary)
        }
        if code {
            look[.backgroundColor] = NSColor(Theme.Palette.surfaceActive)
        }
        if attributes[.richStrike] != nil {
            look[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if attributes[.link] != nil {
            look[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return look
    }

    /// What the line break ending a paragraph carries: what the paragraph
    /// is. An empty line has nothing else to carry it, and without it an
    /// empty line in a code block read as the end of the block.
    private static func paragraphAttributes(ending index: Int, of paragraphs: [NSAttributedString]) -> [NSAttributedString.Key: Any] {
        let nearest = paragraphs[index].length > 0 ? paragraphs[index]
            : (paragraphs[..<index].last { $0.length > 0 } ?? paragraphs[index...].first { $0.length > 0 })
        guard let paragraph = nearest else { return [:] }
        var attributes: [NSAttributedString.Key: Any] = [:]
        for key in [NSAttributedString.Key.richBlock, .paragraphStyle] {
            attributes[key] = paragraph.attribute(key, at: paragraph.length - 1, effectiveRange: nil)
        }
        return attributes
    }
}

// MARK: - Drawing blocks

private typealias Node = UnsafeMutablePointer<cmark_node>

@MainActor
extension RichMarkdown {
    private static func withDocument(_ markdown: String, _ body: (Node) -> Void) {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_UNSAFE) else { return }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tasklist"] {
            guard let syntax = cmark_find_syntax_extension(name) else { continue }
            cmark_parser_attach_syntax_extension(parser, syntax)
        }
        markdown.withCString { cmark_parser_feed(parser, $0, strlen($0)) }
        guard let document = cmark_parser_finish(parser) else { return }
        defer { cmark_node_free(document) }
        body(document)
    }

    private static func children(of node: Node) -> [Node] {
        var result: [Node] = []
        var child = cmark_node_first_child(node)
        while let current = child {
            result.append(current)
            child = cmark_node_next(current)
        }
        return result
    }

    private static func typeName(_ node: Node) -> String {
        cmark_node_get_type_string(node).map { String(cString: $0) } ?? ""
    }

    private static func literal(_ node: Node) -> String {
        cmark_node_get_literal(node).map { String(cString: $0) } ?? ""
    }

    /// Lines `from` through `to`, one-based as cmark counts them, with the
    /// blank ones at either end left off.
    private static func slice(_ lines: [String], from: Int, to: Int) -> String {
        guard from <= to, from >= 1, from <= lines.count else { return "" }
        var picked = Array(lines[(from - 1) ..< min(to, lines.count)])
        while picked.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { picked.removeFirst() }
        while picked.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { picked.removeLast() }
        return picked.joined(separator: "\n")
    }

    /// The paragraphs a block is drawn as, or nil for a block the editor
    /// shows as its source.
    private static func paragraphs(of block: Node) -> [NSMutableAttributedString]? {
        switch cmark_node_get_type(block) {
        case CMARK_NODE_PARAGRAPH:
            return inlineParagraph(block, as: .paragraph).map { [$0] }
        case CMARK_NODE_HEADING:
            return inlineParagraph(block, as: .heading(Int(cmark_node_get_heading_level(block)))).map { [$0] }
        case CMARK_NODE_BLOCK_QUOTE:
            var drawn: [NSMutableAttributedString] = []
            for child in children(of: block) {
                guard cmark_node_get_type(child) == CMARK_NODE_PARAGRAPH,
                      let paragraph = inlineParagraph(child, as: .quote)
                else { return nil }
                drawn.append(paragraph)
            }
            return drawn.isEmpty ? nil : drawn
        case CMARK_NODE_LIST:
            var drawn: [NSMutableAttributedString] = []
            return list(block, within: [], into: &drawn) ? drawn : nil
        case CMARK_NODE_CODE_BLOCK:
            let info = cmark_node_get_fence_info(block).map { String(cString: $0) } ?? ""
            var code = literal(block)
            if code.hasSuffix("\n") { code.removeLast() }
            return code.components(separatedBy: "\n").map { line in
                NSMutableAttributedString(string: line, attributes: [.richBlock: Block.code(info).rawValue])
            }
        default:
            return nil
        }
    }

    private static func rawParagraphs(_ source: String) -> [NSMutableAttributedString] {
        source.components(separatedBy: "\n").map { line in
            NSMutableAttributedString(string: line, attributes: [.richBlock: Block.raw.rawValue])
        }
    }

    private static func inlineParagraph(_ node: Node, as block: Block) -> NSMutableAttributedString? {
        let text = NSMutableAttributedString()
        guard inlines(of: node, style: InlineStyle(), into: text) else { return nil }
        text.addAttribute(.richBlock, value: block.rawValue, range: NSRange(location: 0, length: text.length))
        if text.length == 0 {
            // An empty paragraph still needs something to say what it is.
            return NSMutableAttributedString(string: "", attributes: [.richBlock: block.rawValue])
        }
        return text
    }

    /// Only lists of one-paragraph items, nested or not: an item with two
    /// paragraphs or a code block in it has an indentation the editor would
    /// not know how to keep.
    private static func list(_ node: Node, within outer: [NSTextList], into drawn: inout [NSMutableAttributedString]) -> Bool {
        let ordered = cmark_node_get_list_type(node) == CMARK_ORDERED_LIST
        let list = NSTextList(
            markerFormat: ordered ? orderedMarker : (outer.isEmpty ? .disc : .hyphen),
            options: 0
        )
        if ordered { list.startingItemNumber = Int(cmark_node_get_list_start(node)) }
        let lists = outer + [list]
        var number = list.startingItemNumber
        for item in children(of: node) {
            guard cmark_node_get_type(item) == CMARK_NODE_ITEM, typeName(item) == "item" else { return false }
            let parts = children(of: item)
            let content = NSMutableAttributedString()
            if let first = parts.first {
                guard cmark_node_get_type(first) == CMARK_NODE_PARAGRAPH,
                      inlines(of: first, style: InlineStyle(), into: content)
                else { return false }
            }
            let paragraph = NSMutableAttributedString(string: "\t\(list.marker(forItemNumber: number))\t")
            paragraph.append(content)
            let range = NSRange(location: 0, length: paragraph.length)
            paragraph.addAttribute(.richBlock, value: Block.paragraph.rawValue, range: range)
            paragraph.addAttribute(.paragraphStyle, value: listStyle(lists), range: range)
            drawn.append(paragraph)
            for nested in parts.dropFirst() {
                guard cmark_node_get_type(nested) == CMARK_NODE_LIST, self.list(nested, within: lists, into: &drawn)
                else { return false }
            }
            number += 1
        }
        return true
    }

    static let orderedMarker = NSTextList.MarkerFormat("{decimal}.")

    private struct InlineStyle {
        var strong = false
        var emphasis = false
        var strike = false
        var link: String?

        var attributes: [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [:]
            if strong { attributes[.richStrong] = true }
            if emphasis { attributes[.richEmphasis] = true }
            if strike { attributes[.richStrike] = true }
            if let link { attributes[.link] = link }
            return attributes
        }
    }

    /// False for anything the editor cannot write back as it found it, which
    /// sends the whole block to be shown as its source.
    private static func inlines(of parent: Node, style: InlineStyle, into text: NSMutableAttributedString) -> Bool {
        let nodes = children(of: parent)
        var index = 0
        while index < nodes.count {
            let node = nodes[index]
            index += 1
            switch cmark_node_get_type(node) {
            case CMARK_NODE_TEXT:
                // cmark breaks text at every bracket that opens nothing, and a
                // picture YouTrack names by its file is exactly such brackets.
                var run = literal(node)
                while index < nodes.count, cmark_node_get_type(nodes[index]) == CMARK_NODE_TEXT {
                    run += literal(nodes[index])
                    index += 1
                }
                appendText(run, style: style, to: text)
            case CMARK_NODE_SOFTBREAK, CMARK_NODE_LINEBREAK:
                text.append(NSAttributedString(string: "\u{2028}", attributes: style.attributes))
            case CMARK_NODE_CODE:
                var attributes = style.attributes
                attributes[.richCode] = true
                text.append(NSAttributedString(string: literal(node), attributes: attributes))
            case CMARK_NODE_EMPH:
                var inner = style
                inner.emphasis = true
                guard inlines(of: node, style: inner, into: text) else { return false }
            case CMARK_NODE_STRONG:
                var inner = style
                inner.strong = true
                guard inlines(of: node, style: inner, into: text) else { return false }
            case CMARK_NODE_LINK:
                let title = cmark_node_get_title(node).map { String(cString: $0) } ?? ""
                guard title.isEmpty, style.link == nil else { return false }
                var inner = style
                inner.link = cmark_node_get_url(node).map { String(cString: $0) } ?? ""
                guard inlines(of: node, style: inner, into: text) else { return false }
            case CMARK_NODE_IMAGE:
                var source = "![\(plainText(of: node))](\(cmark_node_get_url(node).map { String(cString: $0) } ?? "")"
                let title = cmark_node_get_title(node).map { String(cString: $0) } ?? ""
                if !title.isEmpty { source += " \"\(title)\"" }
                source += ")"
                // YouTrack's size for it, which cmark leaves as text after it.
                var following = ""
                while index < nodes.count, cmark_node_get_type(nodes[index]) == CMARK_NODE_TEXT {
                    following += literal(nodes[index])
                    index += 1
                }
                if following.hasPrefix("{"), let close = following.firstIndex(of: "}") {
                    source += following[...close]
                    following = String(following[following.index(after: close)...])
                }
                appendRaw(source, style: style, to: text)
                appendText(following, style: style, to: text)
            case CMARK_NODE_HTML_INLINE:
                appendRaw(literal(node), style: style, to: text)
            default:
                if typeName(node) == "strikethrough" {
                    var inner = style
                    inner.strike = true
                    guard inlines(of: node, style: inner, into: text) else { return false }
                } else {
                    return false
                }
            }
        }
        return true
    }

    /// Text, with the pictures YouTrack writes by an attachment's name —
    /// which no Markdown reader takes for pictures — kept as they are.
    private static func appendText(_ string: String, style: InlineStyle, to text: NSMutableAttributedString) {
        guard !string.isEmpty else { return }
        let source = string as NSString
        var cursor = 0
        for match in pictureReference?.matches(in: string, range: NSRange(location: 0, length: source.length)) ?? [] {
            if match.range.location > cursor {
                text.append(NSAttributedString(
                    string: source.substring(with: NSRange(location: cursor, length: match.range.location - cursor)),
                    attributes: style.attributes
                ))
            }
            appendRaw(source.substring(with: match.range), style: style, to: text)
            cursor = match.range.location + match.range.length
        }
        if cursor < source.length {
            text.append(NSAttributedString(string: source.substring(from: cursor), attributes: style.attributes))
        }
    }

    private static func appendRaw(_ source: String, style: InlineStyle, to text: NSMutableAttributedString) {
        var attributes = style.attributes
        attributes[.richRaw] = true
        text.append(NSAttributedString(string: source, attributes: attributes))
    }

    private static func plainText(of node: Node) -> String {
        children(of: node).map { child in
            switch cmark_node_get_type(child) {
            case CMARK_NODE_TEXT, CMARK_NODE_CODE: literal(child)
            default: plainText(of: child)
            }
        }.joined()
    }

    /// The pattern `IssueMarkdown` draws pictures by, so what it shows as a
    /// picture this keeps as one.
    private static var pictureReference: NSRegularExpression? {
        try? NSRegularExpression(pattern: #"!\[[^\]\n]*\]\([^)\n]+\)(\{[^}\n]*\})?"#)
    }
}

// MARK: - Writing blocks

@MainActor
extension RichMarkdown {
    /// One character's worth of what the editor keeps, for telling whether a
    /// block still reads as it did.
    fileprivate struct Run: Equatable {
        var text: String
        var block: String?
        var strong = false
        var emphasis = false
        var strike = false
        var code = false
        var raw = false
        var link: String?
        var lists: [String] = []
    }

    fileprivate static func signature(of text: NSAttributedString, in range: NSRange) -> [Run] {
        var runs: [Run] = []
        guard range.length > 0 else { return runs }
        let string = text.string as NSString
        text.enumerateAttributes(in: range) { attributes, run, _ in
            let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
            let next = Run(
                text: string.substring(with: run),
                block: attributes[.richBlock] as? String,
                strong: attributes[.richStrong] != nil,
                emphasis: attributes[.richEmphasis] != nil,
                strike: attributes[.richStrike] != nil,
                code: attributes[.richCode] != nil,
                raw: attributes[.richRaw] != nil,
                link: linkTarget(attributes[.link]),
                lists: paragraph?.textLists.map(\.markerFormat.rawValue) ?? []
            )
            if var last = runs.last, sameLook(last, next) {
                last.text += next.text
                runs[runs.count - 1] = last
            } else {
                runs.append(next)
            }
        }
        return runs
    }

    private static func sameLook(_ one: Run, _ other: Run) -> Bool {
        var one = one
        one.text = other.text
        return one == other
    }

    static func linkTarget(_ value: Any?) -> String? {
        if let url = value as? URL { return url.absoluteString }
        return value as? String
    }

    fileprivate struct Group {
        var range: NSRange
        var kind: Kind
        var origin: Int?
        var paragraphs: [NSRange]

        enum Kind: Equatable {
            case paragraph
            case heading(Int)
            case quote
            case code(String)
            case raw
            case list
        }
    }

    /// The paragraphs of the text put together into the blocks they will be
    /// written as: a list's items, a quote's paragraphs, a code block's lines.
    private static func groups(in text: NSAttributedString) -> [Group] {
        var groups: [Group] = []
        let string = text.string as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, _, _ in
            let at = min(range.location, max(text.length - 1, 0))
            guard text.length > 0 else { return }
            let style = text.attribute(.paragraphStyle, at: at, effectiveRange: nil) as? NSParagraphStyle
            let block = Block(rawValue: text.attribute(.richBlock, at: at, effectiveRange: nil) as? String)
            let origin = range.length > 0 ? text.attribute(.richOrigin, at: range.location, effectiveRange: nil) as? Int : nil
            let kind: Group.Kind
            if let lists = style?.textLists, !lists.isEmpty {
                kind = .list
            } else {
                switch block {
                case .paragraph: kind = .paragraph
                case let .heading(level): kind = .heading(level)
                case .quote: kind = .quote
                case let .code(info): kind = .code(info)
                case .raw: kind = .raw
                }
            }
            // An empty line ends what it follows, except inside code, where
            // it is a line of the code.
            if range.length == 0 {
                if case .code = kind, var last = groups.last, last.kind == kind {
                    last.paragraphs.append(range)
                    last.range = NSUnionRange(last.range, range)
                    groups[groups.count - 1] = last
                } else {
                    groups.append(Group(range: range, kind: .paragraph, origin: nil, paragraphs: []))
                }
                return
            }
            // A list's items and a quote's paragraphs are one block wherever
            // each came from: paragraphs made a list together are one list.
            // Code and source keep to the block they came from, since two
            // blocks of code side by side are two blocks.
            let joins: Bool
            switch kind {
            case .list, .quote: joins = true
            case .code, .raw: joins = groups.last?.origin == origin || origin == nil
            case .paragraph, .heading: joins = false
            }
            if joins, var last = groups.last, last.kind == kind {
                if last.origin != origin { last.origin = nil }
                last.paragraphs.append(range)
                last.range = NSUnionRange(last.range, range)
                groups[groups.count - 1] = last
            } else {
                groups.append(Group(range: range, kind: kind, origin: origin, paragraphs: [range]))
            }
        }
        return groups.filter { !$0.paragraphs.isEmpty }
    }

    private static func write(_ group: Group, in text: NSAttributedString) -> String {
        let string = text.string as NSString
        switch group.kind {
        case .paragraph:
            return inline(text, in: group.paragraphs[0])
        case let .heading(level):
            let content = inline(text, in: group.paragraphs[0]).replacingOccurrences(of: "\n", with: " ")
            return String(repeating: "#", count: level) + " " + content
        case .quote:
            return group.paragraphs.map { range in
                inline(text, in: range).components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            }.joined(separator: "\n>\n")
        case let .code(info):
            let lines = group.paragraphs.map { string.substring(with: $0).replacingOccurrences(of: "\u{2028}", with: "\n") }
            let body = lines.joined(separator: "\n")
            var fence = "```"
            while body.contains(fence) { fence += "`" }
            return fence + info + "\n" + body + "\n" + fence
        case .raw:
            return group.paragraphs.map { string.substring(with: $0).replacingOccurrences(of: "\u{2028}", with: "\n") }
                .joined(separator: "\n")
        case .list:
            return writeList(group, in: text)
        }
    }

    private static func writeList(_ group: Group, in text: NSAttributedString) -> String {
        let string = text.string as NSString
        var lines: [String] = []
        var numbers: [Int] = []
        var contentColumns: [Int] = []
        for range in group.paragraphs {
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let lists = style?.textLists ?? []
            let level = max(lists.count, 1)
            let ordered = lists.last.map { !bulletFormats.contains($0.markerFormat) } ?? false

            // AppKit keeps the marker in the text, between two tabs.
            var content = range
            let paragraph = string.substring(with: range)
            if let marker = markerPrefix?.firstMatch(in: paragraph, range: NSRange(location: 0, length: (paragraph as NSString).length)) {
                content = NSRange(location: range.location + marker.range.length, length: range.length - marker.range.length)
            }

            numbers = Array(numbers.prefix(level))
            contentColumns = Array(contentColumns.prefix(level - 1))
            if numbers.count < level {
                numbers += Array(repeating: lists.last?.startingItemNumber ?? 1, count: level - numbers.count)
            } else {
                numbers[level - 1] += 1
            }
            let marker = ordered ? "\(numbers[level - 1]). " : "- "
            let indent = contentColumns.last ?? 0
            contentColumns.append(indent + marker.count)

            let body = inline(text, in: content)
                .replacingOccurrences(of: "\n", with: "\n" + String(repeating: " ", count: indent + marker.count))
            lines.append(String(repeating: " ", count: indent) + marker + body)
        }
        return lines.joined(separator: "\n")
    }

    private static let bulletFormats: Set<NSTextList.MarkerFormat> = [
        .disc, .circle, .square, .hyphen, .box, .check, .diamond,
    ]

    private static var markerPrefix: NSRegularExpression? {
        try? NSRegularExpression(pattern: "^\t[^\t\n]*\t")
    }
}

// MARK: - Writing text

@MainActor
extension RichMarkdown {
    private enum Mark: Equatable {
        case link(String)
        case strike
        case strong
        case emphasis

        /// Outermost first: a link around bold text reads as one, and bold
        /// around a link is closed and opened again inside it.
        var rank: Int {
            switch self {
            case .link: 0
            case .strike: 1
            case .strong: 2
            case .emphasis: 3
            }
        }

        var opener: String {
            switch self {
            case .link: "["
            case .strike: "~~"
            case .strong: "**"
            case .emphasis: "*"
            }
        }

        var closer: String {
            switch self {
            case let .link(target): "](\(destination(target)))"
            case .strike: "~~"
            case .strong: "**"
            case .emphasis: "*"
            }
        }
    }

    private enum Piece {
        case text(String)
        case code(String)
        /// Written as it is: a picture, a bare address.
        case verbatim(String)
    }

    /// A paragraph's text as Markdown: marks opened and closed around the runs
    /// that carry them, and the characters Markdown would read as marks of its
    /// own escaped.
    private static func inline(_ text: NSAttributedString, in range: NSRange) -> String {
        let string = text.string as NSString
        var runs: [(marks: [Mark], piece: Piece)] = []
        text.enumerateAttributes(in: range) { attributes, run, _ in
            let content = string.substring(with: run).replacingOccurrences(of: "\u{2028}", with: "\n")
            var marks: [Mark] = []
            if let target = linkTarget(attributes[.link]) { marks.append(.link(target)) }
            if attributes[.richStrike] != nil { marks.append(.strike) }
            if attributes[.richStrong] != nil { marks.append(.strong) }
            if attributes[.richEmphasis] != nil { marks.append(.emphasis) }
            let piece: Piece
            if attributes[.richRaw] != nil {
                piece = .verbatim(content)
            } else if attributes[.richCode] != nil {
                piece = .code(content)
            } else {
                piece = .text(content)
            }
            runs.append((marks, piece))
        }
        runs = bareLinks(in: runs)

        var output = ""
        var open: [Mark] = []

        func close(from index: Int) {
            guard index < open.count else { return }
            // A closing mark has to follow the text it closes, not a space.
            var trailing = ""
            while let last = output.last, last.isWhitespace {
                trailing.insert(last, at: trailing.startIndex)
                output.removeLast()
            }
            for mark in open[index...].reversed() { output += mark.closer }
            output += trailing
            open.removeSubrange(index...)
        }

        for (marks, piece) in runs {
            var wanted = marks.sorted { $0.rank < $1.rank }
            if case let .text(content) = piece, content.allSatisfy(\.isWhitespace) {
                // Nothing opens on whitespace, and nothing needs closing for it.
                wanted = Array(zip(open, wanted).prefix { $0 == $1 }.map(\.0))
                if wanted.count < open.count { close(from: wanted.count) }
                output += escapeText(content, atLineStart: output.isEmpty || output.hasSuffix("\n"), insideLink: open.contains { if case .link = $0 { true } else { false } })
                continue
            }
            let kept = zip(open, wanted).prefix { $0 == $1 }.count
            close(from: kept)

            var body = piece
            if case let .text(content) = piece {
                // An opening mark has to come before text, not a space.
                let leading = content.prefix(while: \.isWhitespace)
                output += leading
                body = .text(String(content.dropFirst(leading.count)))
            }
            for mark in wanted[kept...] {
                output += mark.opener
                open.append(mark)
            }
            let insideLink = open.contains { if case .link = $0 { true } else { false } }
            switch body {
            case let .text(content):
                output += escapeText(content, atLineStart: output.isEmpty || output.hasSuffix("\n"), insideLink: insideLink)
            case let .code(content):
                output += codeSpan(content)
            case let .verbatim(content):
                output += content
            }
        }
        close(from: 0)

        return output.components(separatedBy: "\n")
            .map { line in
                // Two spaces at the end of a line are a hard break, four at
                // its start a code block: neither is what was typed.
                var line = line
                while line.hasSuffix(" ") || line.hasSuffix("\t") { line.removeLast() }
                return String(line.drop { $0 == " " || $0 == "\t" })
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    /// A link whose text is its own address is written as the address, as it
    /// was most likely typed.
    private static func bareLinks(in runs: [(marks: [Mark], piece: Piece)]) -> [(marks: [Mark], piece: Piece)] {
        var result: [(marks: [Mark], piece: Piece)] = []
        var index = 0
        while index < runs.count {
            guard case let .link(target)? = runs[index].marks.first(where: { if case .link = $0 { true } else { false } }) else {
                result.append(runs[index])
                index += 1
                continue
            }
            var end = index
            var shown = ""
            var plain = true
            while end < runs.count, runs[end].marks.contains(.link(target)) {
                if runs[end].marks.count > 1 { plain = false }
                switch runs[end].piece {
                case let .text(content): shown += content
                default: plain = false
                }
                end += 1
            }
            let isWeb = target.hasPrefix("http://") || target.hasPrefix("https://")
            if plain, shown == target, isWeb {
                result.append(([], .verbatim(target)))
            } else if plain, target == "mailto:" + shown {
                result.append(([], .verbatim("<\(shown)>")))
            } else {
                result.append(contentsOf: runs[index ..< end])
            }
            index = end
        }
        return result
    }

    private static func codeSpan(_ content: String) -> String {
        var fence = "`"
        while content.contains(fence) { fence += "`" }
        let padded = content.hasPrefix("`") || content.hasSuffix("`") ? " \(content) " : content
        return fence + padded + fence
    }

    fileprivate nonisolated static func destination(_ target: String) -> String {
        guard target.contains(where: { $0 == " " || $0 == "(" || $0 == ")" || $0 == "<" || $0 == ">" }) else { return target }
        return "<" + target.replacingOccurrences(of: "<", with: "%3C").replacingOccurrences(of: ">", with: "%3E") + ">"
    }

    /// Text as Markdown reads it back as the same text. Only what would be
    /// read as a mark is escaped, so a sentence with an underscore in a word
    /// or a bracket in it does not arrive covered in backslashes.
    static func escapeText(_ text: String, atLineStart: Bool, insideLink: Bool = false) -> String {
        text.components(separatedBy: "\n").enumerated().map { index, line in
            let (prefix, rest) = index > 0 || atLineStart ? lineStart(of: line) : ("", Substring(line))
            let characters = Array(rest)
            var output = prefix
            for (offset, character) in characters.enumerated() {
                let previous = offset > 0 ? characters[offset - 1] : nil
                let next = offset + 1 < characters.count ? characters[offset + 1] : nil
                output += escape(character, previous: previous, next: next, insideLink: insideLink)
            }
            return output
        }.joined(separator: "\n")
    }

    private static func escape(_ character: Character, previous: Character?, next: Character?, insideLink: Bool) -> String {
        switch character {
        case "\\", "*", "`":
            return "\\\(character)"
        case "_":
            // Inside a word it is only an underscore.
            let inWord = (previous?.isLetter == true || previous?.isNumber == true)
                && (next?.isLetter == true || next?.isNumber == true)
            return inWord ? "_" : "\\_"
        case "~":
            return next == "~" || previous == "~" ? "\\~" : "~"
        case "[":
            return insideLink ? "\\[" : "["
        case "]":
            return insideLink || next == "(" || next == "[" ? "\\]" : "]"
        case "<":
            if let next, next.isLetter || next == "/" || next == "!" || next == "?" { return "\\<" }
            return "<"
        default:
            return String(character)
        }
    }

    /// The start of a line with what it would be read as — a heading, a
    /// quote, a list item, a rule — stopped by a backslash, and the rest.
    private static func lineStart(of line: String) -> (String, Substring) {
        let whole = Substring(line)
        guard let first = line.first else { return ("", whole) }
        let rest = whole.dropFirst()
        switch first {
        case "#":
            let hashes = line.prefix { $0 == "#" }
            let after = line.dropFirst(hashes.count).first
            if hashes.count <= 6, after == nil || after == " " { return ("\\#", rest) }
        case ">":
            return ("\\>", rest)
        case "-", "+", "*", "=":
            let isItem = first != "=" && (rest.first == " " || rest.first == nil)
            let isRule = line.allSatisfy { $0 == first || $0 == " " } && line.filter { $0 == first }.count >= (first == "=" ? 1 : 3)
            if isItem || isRule { return ("\\\(first)", rest) }
        default:
            break
        }
        // `1.` or `1)` and a space reads as a numbered item.
        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 9 {
            let after = whole.dropFirst(digits.count)
            if let mark = after.first, mark == "." || mark == ")", after.dropFirst().first == " " || after.dropFirst().first == nil {
                return (digits + "\\" + String(mark), after.dropFirst())
            }
        }
        return ("", whole)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
