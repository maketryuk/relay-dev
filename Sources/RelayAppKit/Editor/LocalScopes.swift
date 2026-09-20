import CodeEditLanguages
import Foundation
import SwiftTreeSitter

/// A name that means something only where it is written.
struct LocalBinding: Equatable {
    /// Where it is declared: a parameter, a `const`, a `let`.
    let definition: NSRange
    /// Every place it is written inside the scope that declares it, the
    /// declaration included.
    let ranges: [NSRange]
}

/// What a name means where the caret is.
///
/// A parameter called `platform` has nothing to do with the `platform`
/// declared in another file, and asking an index of names which of them was
/// meant is asking the wrong question: the answer is in the twelve lines
/// around the click. The grammars carry a second query for exactly this —
/// `locals.scm`, which says what a scope is, what declares a name in one and
/// what merely uses it — and it is asked first, before anything is looked up
/// anywhere else.
enum LocalScopes {
    /// The binding the name at this offset belongs to, or nil when the name
    /// is not local to anything — a top-level function, a class, an import —
    /// which is when the index is the right place to ask.
    static func binding(at offset: Int, in text: String, language: SourceLanguage) -> LocalBinding? {
        binding(at: offset, in: text, language: language, depth: 0)
    }

    /// How deep an injected language is followed. One is enough: the script
    /// inside a single-file component.
    private static let injectionLimit = 1

    private static func binding(
        at offset: Int,
        in text: String,
        language: SourceLanguage,
        depth: Int
    ) -> LocalBinding? {
        if let found = resolved(at: offset, in: text, language: language) { return found }

        // A `.vue` file is HTML, which declares nothing and scopes nothing;
        // everything a component's script declares is local to that script.
        guard depth < injectionLimit else { return nil }
        for region in SourceHighlighter.injectedRegions(in: text, language: language) {
            guard NSLocationInRange(offset, region.range),
                  let injected = SourceLanguage(tsName: region.language),
                  let inner = substring(of: text, in: region.range),
                  let found = binding(
                      at: offset - region.range.location,
                      in: inner,
                      language: injected,
                      depth: depth + 1
                  )
            else { continue }

            let shift = region.range.location
            return LocalBinding(
                definition: moved(found.definition, by: shift),
                ranges: found.ranges.map { moved($0, by: shift) }
            )
        }
        return nil
    }

    private static func resolved(at offset: Int, in text: String, language: SourceLanguage) -> LocalBinding? {
        guard let word = SymbolWord.identifier(in: text, at: offset),
              let query = query(for: language),
              let parser = language.parser(),
              let tree = parser.parse(text)
        else { return nil }

        var scopes: [NSRange] = []
        var definitions: [(name: String, range: NSRange)] = []
        var references: [NSRange] = []
        let source = text as NSString

        let matches = query
            .execute(in: tree)
            .resolve(with: Predicate.Context(string: text))

        for match in matches {
            for capture in match.captures {
                let range = capture.node.range
                guard NSMaxRange(range) <= source.length else { continue }
                switch capture.nameComponents.joined(separator: ".") {
                case "local.scope":
                    scopes.append(range)
                case "local.definition":
                    definitions.append((source.substring(with: range), range))
                case "local.reference":
                    guard source.substring(with: range) == word.text else { continue }
                    references.append(range)
                default:
                    break
                }
            }
        }

        // Innermost first: a parameter of the function you are standing in
        // beats the same name declared around it, which is what shadowing is.
        let containing = scopes
            .filter { NSLocationInRange(offset, $0) }
            .sorted { $0.length < $1.length }

        for scope in containing {
            guard let definition = definitions.first(where: {
                $0.name == word.text && NSLocationInRange($0.range.location, scope)
            }) else { continue }

            let used = references.filter { NSLocationInRange($0.location, scope) }
            var ranges = Array(Set(used + [definition.range]))
            ranges.sort { $0.location < $1.location }
            return LocalBinding(definition: definition.range, ranges: ranges)
        }
        return nil
    }

    /// The compiled locals query, parent first.
    ///
    /// TypeScript's own file says only what a typed parameter is; what a
    /// scope is and what a `const` declares are in JavaScript's, which it
    /// names as its parent — the same arrangement the colouring and the tags
    /// are in.
    static func query(for language: SourceLanguage) -> Query? {
        CompiledQueries.shared.query("locals:\(language.code.id.rawValue)") { compile(for: language) }
    }

    private static func compile(for language: SourceLanguage) -> Query? {
        guard let tsLanguage = language.code.language,
              let own = url(for: language.code),
              let ownData = try? Data(contentsOf: own)
        else { return nil }

        if let parent = language.code.parentQueryURL
            .map({ $0.deletingLastPathComponent().appendingPathComponent("locals.scm") }),
            let parentData = try? Data(contentsOf: parent) {
            var combined = parentData
            combined.append(0x0A)
            combined.append(ownData)
            if let query = try? Query(language: tsLanguage, data: combined) { return query }
        }
        return try? Query(language: tsLanguage, data: ownData)
    }

    private static func url(for language: CodeLanguage) -> URL? {
        guard SourceHighlighter.grammarsAreReachable, let highlights = language.queryURL else { return nil }
        let url = highlights.deletingLastPathComponent().appendingPathComponent("locals.scm")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func substring(of text: String, in range: NSRange) -> String? {
        let source = text as NSString
        guard range.location >= 0, NSMaxRange(range) <= source.length, range.length > 0 else { return nil }
        return source.substring(with: range)
    }

    private static func moved(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }
}
