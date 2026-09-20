import CodeEditLanguages
import Foundation
import SwiftTreeSitter

/// A name a file declares, and where it declares it.
struct SymbolDefinition: Hashable, Sendable, Identifiable {
    /// What sort of thing carries the name.
    ///
    /// Fewer kinds than the grammars distinguish, for the same reason the
    /// highlighter has fewer colours than they have capture names: the list is
    /// read at a glance to tell two candidates apart, and "trait" against
    /// "interface" is not the difference anybody is looking at.
    enum Kind: String, Hashable, Sendable {
        case function, method, type, module, constant, property, variable, other
        /// Not a name in a file but a file with that name: a component used
        /// as `<UserCard />` is declared by `UserCard.vue` existing, and
        /// nothing inside it says so.
        case file

        /// The glyph beside it in a list.
        var systemImage: String {
            switch self {
            case .function, .method: "function"
            case .type: "cube"
            case .module: "shippingbox"
            case .constant: "lock"
            case .property: "list.bullet.indent"
            case .variable: "tag"
            case .other: "number"
            case .file: "doc"
            }
        }

        /// The kind a tags query's capture name stands for, or nil when the
        /// capture is not a definition at all — `reference.call` and the `doc`
        /// a grammar attaches to a definition both come through here.
        init?(capture: String) {
            let parts = capture.split(separator: ".").map(String.init)
            let tail: String
            switch parts.first {
            case "definition":
                guard parts.count > 1 else { return nil }
                tail = parts[1]
            // A handful of grammars name a namespace without the prefix.
            case "module":
                tail = "module"
            default:
                return nil
            }

            switch tail {
            case "function", "macro": self = .function
            case "method": self = .method
            case "class", "type", "interface", "struct", "enum", "trait", "union", "protocol": self = .type
            case "module", "namespace", "package": self = .module
            case "constant": self = .constant
            case "field", "property": self = .property
            case "var", "variable", "parameter": self = .variable
            default: self = .other
            }
        }

        /// Which of two names for one declaration to keep. `const handler =
        /// () => {}` is a binding to our pattern and a function to the
        /// grammar's; it is a function, and the glyph beside it should say so.
        var precedence: Int {
            switch self {
            case .function, .method: 0
            case .type, .module: 1
            case .property: 2
            case .constant: 3
            case .variable: 4
            case .other: 5
            case .file: 6
            }
        }
    }

    let name: String
    let kind: Kind
    /// Absolute, the same way an open file is named.
    let path: String
    /// Where the name itself sits, for putting the caret on it rather than on
    /// the line it starts.
    let range: NSRange
    /// 1-based, as every editor and every error message counts lines.
    let line: Int

    var id: String { "\(path):\(range.location)" }
}

/// Reading a file for the names it declares.
///
/// The queries are the grammars' own `tags.scm` — the files GitHub's code
/// navigation is built on — so what counts as a definition in Go, in PHP or in
/// Swift is each language's own answer rather than a regular expression of
/// ours. Not every grammar ships one; a language without it simply declares
/// nothing, which is the same outcome as before there was any of this.
enum SymbolTags {
    /// Every definition in this text, including the ones in another language
    /// inside it.
    static func definitions(in text: String, language: SourceLanguage, path: String) -> [SymbolDefinition] {
        definitions(in: text, language: language, path: path, depth: 0)
    }

    /// How deep an injected language may itself inject another. The
    /// highlighter's limit and the highlighter's reasoning: HTML inside PHP,
    /// and JavaScript inside that HTML.
    private static let injectionLimit = 2

    private static func definitions(
        in text: String,
        language: SourceLanguage,
        path: String,
        depth: Int
    ) -> [SymbolDefinition] {
        var found = declared(in: text, language: language, path: path)
        guard depth < injectionLimit else { return found }

        // A single-file component declares nothing as HTML and everything
        // inside its `script`, and the grammar says where that is. Without
        // this a Vue or Svelte project has no names in it at all: the host
        // language has no tags query, so the file was read and came back
        // empty.
        let lines = LineMap(text as NSString)
        for region in SourceHighlighter.injectedRegions(in: text, language: language) {
            guard let injected = SourceLanguage(tsName: region.language),
                  injected.code.id != language.code.id || depth == 0,
                  let inner = substring(of: text, in: region.range)
            else { continue }

            // The injected text begins where the opening tag ends, which is
            // part-way through a line of the file it sits in.
            let firstLine = lines.line(at: region.range.location)
            for definition in definitions(in: inner, language: injected, path: path, depth: depth + 1) {
                found.append(SymbolDefinition(
                    name: definition.name,
                    kind: definition.kind,
                    path: path,
                    range: NSRange(
                        location: definition.range.location + region.range.location,
                        length: definition.range.length
                    ),
                    line: definition.line + firstLine - 1
                ))
            }
        }
        return found
    }

    private static func substring(of text: String, in range: NSRange) -> String? {
        let source = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= source.length, range.length > 0 else { return nil }
        return source.substring(with: range)
    }

    /// What this text declares in its own language.
    private static func declared(in text: String, language: SourceLanguage, path: String) -> [SymbolDefinition] {
        guard let query = query(for: language),
              let parser = language.parser(),
              let tree = parser.parse(text)
        else { return [] }

        let source = text as NSString
        let lines = LineMap(source)
        // Kept by where it is: a grammar and the grammar it inherits from can
        // both claim one declaration — TypeScript inherits all of
        // JavaScript's — and so can a pattern of ours and the grammar's own,
        // which would otherwise turn one `const` into two candidates to
        // choose between.
        var byRange: [NSRange: SymbolDefinition] = [:]

        let matches = query
            .execute(in: tree)
            .resolve(with: Predicate.Context(string: text))

        for match in matches {
            var nameRange: NSRange?
            var kind: SymbolDefinition.Kind?
            for capture in match.captures {
                let capturedName = capture.nameComponents.joined(separator: ".")
                if capturedName == "name" {
                    nameRange = capture.node.range
                } else if let found = SymbolDefinition.Kind(capture: capturedName) {
                    kind = found
                }
            }
            guard let nameRange, let kind, NSMaxRange(nameRange) <= source.length, nameRange.length > 0
            else { continue }

            let definition = SymbolDefinition(
                name: source.substring(with: nameRange),
                kind: kind,
                path: path,
                range: nameRange,
                line: lines.line(at: nameRange.location)
            )
            if let existing = byRange[nameRange], existing.kind.precedence <= kind.precedence { continue }
            byRange[nameRange] = definition
        }
        // Back into the order the file makes them, which is the order a list
        // of them reads in.
        return byRange.values.sorted { $0.range.location < $1.range.location }
    }

    /// The compiled tags query for a language, or nil when its grammar has none.
    static func query(for language: SourceLanguage) -> Query? {
        CompiledQueries.shared.query("tags:\(language.code.id.rawValue)") { compile(for: language) }
    }

    private static func compile(for language: SourceLanguage) -> Query? {
        guard let tsLanguage = language.code.language, let own = tagsURL(for: language.code) else { return nil }
        guard let ownData = try? Data(contentsOf: own) else { return nil }

        // TypeScript declares its functions and classes in JavaScript's file,
        // the same way it colours them there — so the parent comes first and
        // this language's own patterns follow it. Ours come last.
        let parts = [
            language.code.parentQueryURL
                .map { $0.deletingLastPathComponent().appendingPathComponent("tags.scm") }
                .flatMap { try? Data(contentsOf: $0) },
            ownData,
            supplement(for: language.code).flatMap { $0.data(using: .utf8) },
        ].compactMap { $0 }

        var combined = Data()
        for part in parts {
            combined.append(part)
            combined.append(0x0A)
        }
        // A pattern naming a node type this grammar does not have fails the
        // whole file rather than that one pattern, so the grammar's own is
        // kept as the answer of last resort: half the definitions beats none.
        return (try? Query(language: tsLanguage, data: combined))
            ?? (try? Query(language: tsLanguage, data: ownData))
    }

    /// What the grammars' own tags queries leave out.
    ///
    /// They are written for a summary of a file — GitHub lists what a reader
    /// would want in a table of contents — and what a person ⌘-clicks is
    /// routinely none of it. A Vue component is `const count = ref(0)` and
    /// `const props = defineProps()` from top to bottom; a Pinia store is one
    /// `const` holding a call; a PHP class constant is a constant. None of
    /// those is a function, a class or a method, and so none of them was a
    /// definition here.
    ///
    /// Every pattern is anchored at the top level of the file, which is the
    /// line between "declared here" and "a local variable somebody would
    /// never navigate to".
    static func supplement(for language: CodeLanguage) -> String? {
        switch language.id {
        case .javascript, .jsx: javascriptSupplement + factorySupplement
        case .typescript, .tsx: javascriptSupplement + typescriptSupplement + factorySupplement
        case .php: phpSupplement
        case .go: goSupplement
        default: nil
        }
    }

    /// `const` and `let` at the top of a module, including what a destructured
    /// one binds: `const { t } = useI18n()` declares `t` and nothing else does.
    /// And what a module's own factory declares.
    ///
    /// A Pinia store is `export const useX = defineStore("x", () => { … })`
    /// and a composable is `export const useX = () => { … }`: everything they
    /// offer is a `const` inside that function, which is not the top level of
    /// the file and is not a local of anybody's either. Without this a
    /// ⌘-click on a store's own member — the thing a Vue project is made of
    /// — answered that nothing declares it.
    private static let factorySupplement = """
    (program (export_statement (lexical_declaration (variable_declarator
        value: (call_expression arguments: (arguments (arrow_function
            body: (statement_block (lexical_declaration (variable_declarator
                name: (identifier) @name))))))))) @definition.property)
    (program (lexical_declaration (variable_declarator
        value: (call_expression arguments: (arguments (arrow_function
            body: (statement_block (lexical_declaration (variable_declarator
                name: (identifier) @name)))))))) @definition.property)
    (program (export_statement (lexical_declaration (variable_declarator
        value: (arrow_function body: (statement_block (lexical_declaration
            (variable_declarator name: (identifier) @name))))))) @definition.property)
    (program (export_statement (function_declaration
        body: (statement_block (lexical_declaration
            (variable_declarator name: (identifier) @name))))) @definition.property)

    """

    private static let javascriptSupplement = """
    (program (lexical_declaration (variable_declarator name: (identifier) @name)) @definition.constant)
    (program (variable_declaration (variable_declarator name: (identifier) @name)) @definition.variable)
    (program (export_statement (lexical_declaration
        (variable_declarator name: (identifier) @name))) @definition.constant)
    (program (export_statement (variable_declaration
        (variable_declarator name: (identifier) @name))) @definition.variable)
    (program (lexical_declaration (variable_declarator
        name: (object_pattern (shorthand_property_identifier_pattern) @name))) @definition.constant)

    """

    private static let typescriptSupplement = """
    (program (type_alias_declaration name: (type_identifier) @name) @definition.type)
    (program (export_statement (type_alias_declaration name: (type_identifier) @name)) @definition.type)
    (program (enum_declaration name: (identifier) @name) @definition.type)
    (program (export_statement (enum_declaration name: (identifier) @name)) @definition.type)

    """

    private static let phpSupplement = """
    (const_declaration (const_element (name) @name)) @definition.constant
    (enum_declaration name: (name) @name) @definition.type
    (enum_case name: (name) @name) @definition.constant

    """

    private static let goSupplement = """
    (source_file (const_declaration (const_spec name: (identifier) @name)) @definition.constant)
    (source_file (var_declaration (var_spec name: (identifier) @name)) @definition.variable)

    """

    /// Where a grammar keeps its tags query, or nil when it has none.
    ///
    /// The bundle exposes only the highlights path, so the name is swapped in
    /// it — the same trick the injections query is found by.
    static func tagsURL(for language: CodeLanguage) -> URL? {
        guard SourceHighlighter.grammarsAreReachable, let highlights = language.queryURL else { return nil }
        let url = highlights.deletingLastPathComponent().appendingPathComponent("tags.scm")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

/// Where each line of a text begins, so a position can be turned into a line
/// number without walking the file again for every one of them.
private struct LineMap {
    private let starts: [Int]

    init(_ text: NSString) {
        var starts = [0]
        var index = 0
        while index < text.length {
            let next = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
            guard next > index else { break }
            starts.append(next)
            index = next
        }
        self.starts = starts
    }

    func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= offset {
                low = middle
            } else {
                high = middle - 1
            }
        }
        return low + 1
    }
}

/// The identifier under a position in a text.
///
/// Its own thing rather than a parse, because the click has to be answered
/// before anything is known about the file: the word is what the index is
/// asked about, and a tree-sitter node would give the same answer at ten times
/// the cost.
enum SymbolWord {
    static func identifier(in text: String, at offset: Int) -> (text: String, range: NSRange)? {
        let source = text as NSString
        guard offset >= 0, offset <= source.length else { return nil }

        var start = offset
        var end = offset
        while start > 0, isWord(source.character(at: start - 1)) { start -= 1 }
        while end < source.length, isWord(source.character(at: end)) { end += 1 }
        guard end > start else { return nil }

        let range = NSRange(location: start, length: end - start)
        let word = source.substring(with: range)
        // `42` and `0x1f` are words by this reckoning and nothing declares
        // them, so a click on a number is a click on nothing.
        guard let first = word.unicodeScalars.first, !CharacterSet.decimalDigits.contains(first) else { return nil }
        return (word, range)
    }

    /// The string literal the offset is inside, if it is inside one.
    ///
    /// Scanned along the line rather than parsed: what is wanted is the text
    /// between the quotes, and every language on this machine agrees about
    /// what a quote is.
    static func literal(in text: String, at offset: Int) -> (text: String, range: NSRange)? {
        let source = text as NSString
        guard offset >= 0, offset <= source.length else { return nil }
        let lineRange = source.lineRange(for: NSRange(location: min(offset, max(source.length - 1, 0)), length: 0))

        var index = lineRange.location
        while index < NSMaxRange(lineRange) {
            let character = source.character(at: index)
            guard isQuote(character) else {
                index += 1
                continue
            }
            var end = index + 1
            while end < NSMaxRange(lineRange), source.character(at: end) != character { end += 1 }
            guard end < NSMaxRange(lineRange) else { return nil }

            if offset > index, offset <= end {
                let inside = NSRange(location: index + 1, length: end - index - 1)
                guard inside.length > 0 else { return nil }
                return (source.substring(with: inside), inside)
            }
            index = end + 1
        }
        return nil
    }

    private static func isQuote(_ character: unichar) -> Bool {
        character == 0x22 || character == 0x27 || character == 0x60
    }

    /// A letter, a digit or an underscore. `$` is left out deliberately: PHP
    /// writes `$user` and declares `user`, so the sigil is not part of the
    /// name being looked for.
    private static func isWord(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }
}
