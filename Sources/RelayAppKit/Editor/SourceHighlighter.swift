import AppKit
import CodeEditLanguages
import RelayUI
import SwiftTreeSitter
import SwiftUI

/// Colours a text view from a tree-sitter parse of what is in it.
///
/// The parse is what makes this different from a list of keywords: a word is
/// coloured by the part it plays in the syntax tree, so `type` used as a
/// variable stays a variable and a keyword inside a string stays a string.
///
/// The whole file is re-parsed after each pause in typing rather than edited
/// incrementally. tree-sitter reads a megabyte in single-digit milliseconds and
/// the files opened here are hand-written ones; the incremental path costs a
/// byte-offset bookkeeping layer that is wrong in exactly the cases nobody
/// tests — a file with non-ASCII in it — and buys nothing at this size. If a
/// pass ever becomes visible, the parse is where to look first.
@MainActor
final class SourceHighlighter {
    /// A run of text and what it is.
    struct Span: Equatable {
        let range: NSRange
        let role: Role
    }

    private weak var textView: NSTextView?
    private let language: SourceLanguage
    private let fontSize: CGFloat
    private var pending: Task<Void, Never>?

    /// How long to wait after the last keystroke. Long enough that a burst of
    /// typing is one parse, short enough that the colour arrives while the
    /// finger is still moving.
    private static let settleDelay = Duration.milliseconds(90)

    init?(textView: NSTextView, language: SourceLanguage, fontSize: CGFloat) {
        guard Self.query(for: language) != nil else { return nil }
        self.textView = textView
        self.language = language
        self.fontSize = fontSize
        apply()
    }

    deinit {
        pending?.cancel()
    }

    /// Colours what is in the view now.
    ///
    /// For text that was replaced rather than typed: a preview showing
    /// another file, a buffer re-read from disk. Nothing tells a text view
    /// that its contents were swapped — `textDidChange` is for editing — so
    /// without this the new text keeps the old text's colouring, which for a
    /// longer file means no colouring at all.
    func refresh() {
        pending?.cancel()
        apply()
    }

    /// Called when the text changed. Coalesces: a burst of keystrokes is one
    /// parse rather than one per character.
    func textChanged() {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.apply()
        }
    }

    private func apply() {
        guard let textView, let storage = textView.textStorage else { return }
        let text = textView.string
        let spans = Self.spans(in: text, language: language)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let full = NSRange(location: 0, length: (text as NSString).length)

        storage.beginEditing()
        // Added rather than set: the merge panes put a background tint and a
        // paragraph style on these same characters, and setting attributes
        // wholesale would wipe the conflict out from under the colouring.
        storage.addAttribute(.foregroundColor, value: NSColor(Theme.Code.plain), range: full)
        storage.addAttribute(.font, value: font, range: full)
        for span in spans where NSMaxRange(span.range) <= full.length {
            storage.addAttribute(.foregroundColor, value: NSColor(span.role.colour), range: span.range)
            if span.role == .comment {
                storage.addAttribute(.font, value: italic, range: span.range)
            }
        }
        storage.endEditing()
    }

    // MARK: - The parse

    /// Every coloured run in the text, in the order a later one wins.
    ///
    /// A pure function of the text and the grammar, which is the only reason
    /// the colouring is testable at all: everything else here is a text view.
    /// Ranges come back as `NSRange` because the bindings parse UTF-16 — the
    /// same units `NSTextStorage` counts in, so there is no offset arithmetic
    /// to get wrong.
    static func spans(in text: String, language: SourceLanguage) -> [Span] {
        spans(in: text, language: language, depth: 0)
    }

    /// How deep an injected language may itself inject another.
    ///
    /// Two is enough for everything that occurs: HTML inside PHP, and then
    /// JavaScript inside that HTML. Deeper is a template language nobody has
    /// written yet, and the limit keeps a grammar that injects itself from
    /// taking the main thread with it.
    private static let injectionLimit = 2

    private static func spans(in text: String, language: SourceLanguage, depth: Int) -> [Span] {
        parsed(in: text, language: language, depth: depth)
            // Painted last so they win: to the host language a directive is an
            // ordinary word or a stray brace, and whatever it made of it is
            // exactly what should be overruled.
            + (language.markup?.spans(in: text) ?? [])
    }

    private static func parsed(in text: String, language: SourceLanguage, depth: Int) -> [Span] {
        guard let parser = language.parser(), let tree = parser.parse(text) else { return [] }

        var spans: [Span] = []

        if let query = query(for: language) {
            // Resolved rather than raw: `#match?` and `#eq?` are how a grammar
            // says "this identifier is a type only when it is capitalised", and
            // a sequence that ignores them colours words it was told not to.
            let matches = query
                .execute(in: tree)
                .resolve(with: Predicate.Context(string: text))

            for match in matches {
                for capture in match.captures {
                    guard let name = capture.nameComponents.first else { continue }
                    let role = role(for: name)
                    guard role != .plain else { continue }
                    spans.append(Span(range: capture.node.range, role: role))
                }
            }
        }

        // A file is rarely one language. PHP holds HTML, HTML holds JavaScript
        // and CSS, Markdown holds whatever the fence says — and the grammar
        // says so itself, in `injections.scm`. Without this a Blade template
        // comes back with nothing coloured at all: to PHP the markup around
        // its tags is one undifferentiated run of text.
        guard depth < injectionLimit else { return spans }
        for injection in injections(in: text, language: language, tree: tree) {
            guard let injected = SourceLanguage(tsName: injection.languageName),
                  injected.code.id != language.code.id || depth == 0,
                  let sub = substring(of: text, in: injection.range)
            else { continue }

            for span in Self.spans(in: sub, language: injected, depth: depth + 1) {
                spans.append(Span(
                    range: NSRange(
                        location: span.range.location + injection.range.location,
                        length: span.range.length
                    ),
                    role: span.role
                ))
            }
        }
        return spans
    }

    /// What a `script` tag says it holds.
    ///
    /// The HTML grammar calls every script JavaScript, because the attribute
    /// is not its business. A Vue or Svelte component written in TypeScript is
    /// then read as JavaScript, which gets the ordinary lines right and makes
    /// a mess of a type argument: `defineModel<string>()` becomes a chain of
    /// comparisons, and the declarations on either side of it go down with it.
    /// Two of the four `const`s in an ordinary component were being lost that
    /// way, which from the outside looked like an index that missed things at
    /// random.
    nonisolated private static func refined(_ name: String, before range: NSRange, in text: NSString) -> String {
        guard name == "javascript", range.location > 0 else { return name }
        // The tag itself, which is however far back the attributes reach.
        let start = max(0, range.location - 200)
        let opening = text
            .substring(with: NSRange(location: start, length: range.location - start))
            .lowercased()
        guard let tag = opening.range(of: "<script", options: .backwards) else { return name }

        let attributes = opening[tag.lowerBound...]
        // `tsx` as well, which has no grammar of its own here and is read by
        // TypeScript's — the same way `.tsx` files already are.
        for spelling in ["lang=\"ts\"", "lang='ts'", "lang=\"tsx\"", "lang='tsx'"]
        where attributes.contains(spelling) {
            return "typescript"
        }
        return name
    }

    nonisolated private static func substring(of text: String, in range: NSRange) -> String? {
        let source = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= source.length, range.length > 0 else { return nil }
        return source.substring(with: range)
    }

    /// A run of text written in another language, as the grammar describes it.
    private struct Injection {
        let range: NSRange
        let languageName: String
    }

    /// The runs of another language inside this text, as the grammar describes
    /// them. Exposed because the failure it guards against is invisible: a
    /// template whose markup is simply never coloured.
    nonisolated static func injectedRegions(
        in text: String,
        language: SourceLanguage
    ) -> [(range: NSRange, language: String)] {
        guard let parser = language.parser(), let tree = parser.parse(text) else { return [] }
        return injections(in: text, language: language, tree: tree).map { ($0.range, $0.languageName) }
    }

    nonisolated private static func injections(
        in text: String,
        language: SourceLanguage,
        tree: MutableTree
    ) -> [Injection] {
        guard let query = injectionQuery(for: language) else { return [] }

        let matches = query
            .execute(in: tree)
            .resolve(with: Predicate.Context(string: text))

        var found: [Injection] = []
        for match in matches {
            var content: NSRange?
            // `(#set! injection.language "html")` belongs to the match rather
            // than to any one capture in it — which is where an hour went,
            // because reading it off the capture returns nothing and nothing
            // is also what a file with no markup in it returns.
            var name = match.metadata["injection.language"]
            for capture in match.captures {
                let capturedName = capture.nameComponents.joined(separator: ".")
                switch capturedName {
                case "injection.content":
                    content = capture.node.range
                    name = name ?? capture.metadata["injection.language"]
                case "injection.language":
                    // The other form: the language is whatever the node says,
                    // which is how a Markdown fence names its own contents.
                    name = substring(of: text, in: capture.node.range)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                default:
                    break
                }
            }
            guard let content, let name, !name.isEmpty else { continue }
            found.append(Injection(
                range: content,
                languageName: refined(name, before: content, in: text as NSString)
            ))
        }
        return found
    }

    /// The grammar's own account of which parts of a file are another language.
    ///
    /// Not every grammar has one, and the bundle exposes only the highlights
    /// path, so the name is swapped in it. A missing file is the normal case
    /// and is remembered as such rather than looked for on every parse.
    nonisolated static func injectionQuery(for language: SourceLanguage) -> Query? {
        CompiledQueries.shared.query("injections:\(language.code.id.rawValue)") {
            guard grammarsAreReachable,
                  let tsLanguage = language.code.language,
                  let highlights = language.code.queryURL
            else { return nil }

            let url = highlights
                .deletingLastPathComponent()
                .appendingPathComponent("injections.scm")
            return (try? Data(contentsOf: url)).flatMap { try? Query(language: tsLanguage, data: $0) }
        }
    }

    private static func query(for language: SourceLanguage) -> Query? {
        CompiledQueries.shared.query("highlights:\(language.code.id.rawValue)") { compile(for: language) }
    }

    private static func compile(for language: SourceLanguage) -> Query? {
        guard grammarsAreReachable, let tsLanguage = language.code.language else { return nil }

        // A grammar's own file is not the whole of it. TypeScript's says how to
        // colour a type annotation and nothing else, because everything about
        // functions, properties and constants is in JavaScript's — which it
        // names as its parent. Read on its own it colours the types and leaves
        // the rest of the file white, which is exactly how this looked.
        //
        // The parent goes first so the language's own patterns are applied over
        // it where the two disagree.
        let sources = [language.code.parentQueryURL, language.code.queryURL]
            .compactMap { $0 }
            .compactMap { try? Data(contentsOf: $0) }
        guard !sources.isEmpty else { return nil }

        let combined = sources.reduce(into: Data()) { result, source in
            result.append(source)
            result.append(0x0A)
        }
        return try? Query(language: tsLanguage, data: combined)
    }

    /// Whether the grammars can actually be read in this build.
    ///
    /// `CodeEditLanguages` builds its query path as `Bundle.module.resourceURL`
    /// plus `"Resources/…"`. That is the bundle root under Xcode and already
    /// `Resources` under SwiftPM, so the path doubles and every query fails to
    /// load — with nothing said about it, leaving the file drawn in plain
    /// white. `Scripts/build-app.sh` repairs the layout inside the app bundle,
    /// where writing after signing would break the signature; this repairs it
    /// for a `swift run` or a test, where there is no bundle to prepare.
    nonisolated static let grammarsAreReachable: Bool = {
        guard let query = CodeLanguage.swift.queryURL else { return false }
        let manager = FileManager.default
        if manager.fileExists(atPath: query.path) { return true }

        let nested = query.deletingLastPathComponent().deletingLastPathComponent()
        let root = nested.deletingLastPathComponent()
        guard let grammars = try? manager.contentsOfDirectory(atPath: root.path) else { return false }
        try? manager.createDirectory(at: nested, withIntermediateDirectories: true)
        for grammar in grammars where grammar.hasPrefix("tree-sitter-") {
            try? manager.createSymbolicLink(
                atPath: nested.appendingPathComponent(grammar).path,
                withDestinationPath: "../\(grammar)"
            )
        }
        return manager.fileExists(atPath: query.path)
    }()

    // MARK: - Names and colours

    /// The parts of a file a reader actually tells apart at a glance. Fewer
    /// than any grammar produces, which is what makes one palette enough for
    /// forty languages.
    enum Role: Equatable {
        case plain, keyword, type, function, string, number, comment, property, constant, punctuation

        var colour: Color {
            switch self {
            case .plain: Theme.Code.plain
            case .keyword: Theme.Code.keyword
            case .type: Theme.Code.type
            case .function: Theme.Code.function
            case .string: Theme.Code.string
            case .number: Theme.Code.number
            case .comment: Theme.Code.comment
            case .property: Theme.Code.property
            case .constant: Theme.Code.constant
            case .punctuation: Theme.Code.punctuation
            }
        }
    }

    /// What a capture name is drawn as.
    ///
    /// Capture names are dotted and open-ended — `keyword.function`,
    /// `string.special.path`, `punctuation.bracket` — and every grammar invents
    /// its own tail, so only the head is matched. A name nothing here claims is
    /// left in the plain colour rather than guessed at.
    ///
    /// `variable` is deliberately plain. Grammars hand that name to nearly
    /// every identifier in a file, and colouring it leaves a page where only
    /// the punctuation is not coloured — which reads as noise rather than as
    /// structure.
    static func role(for capture: String) -> Role {
        switch capture.split(separator: ".").first.map(String.init) ?? capture {
        case "keyword", "conditional", "repeat", "include", "exception", "storageclass":
            .keyword
        case "type", "class", "struct", "enum", "interface", "namespace":
            .type
        case "function", "method", "constructor":
            .function
        case "string", "text":
            .string
        case "number", "float", "boolean":
            .number
        case "comment", "spell":
            .comment
        case "property", "field", "attribute", "label", "tag":
            .property
        case "constant", "character":
            .constant
        case "operator", "punctuation", "delimiter":
            .punctuation
        default:
            .plain
        }
    }

    static func attributes(for capture: String, fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        let role = role(for: capture)
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        return [
            .foregroundColor: NSColor(role.colour),
            .font: role == .comment
                ? NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                : font,
        ]
    }
}
