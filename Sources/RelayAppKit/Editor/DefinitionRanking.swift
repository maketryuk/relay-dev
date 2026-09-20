import Foundation

/// Which of several declarations of one name was meant.
///
/// The index knows names rather than types, so a popular one comes back from
/// several places at once: `defineProps` is declared by four packages in an
/// ordinary Vue checkout, every one of them right about itself. Asking each
/// time is exact and useless — a jump that stops to ask is a jump nobody
/// makes twice — so the places are ordered by what the click itself says, and
/// the first of them is where it goes.
///
/// What the click says, in order of how much it settles: the file already
/// names the module it means at the top of itself; a declaration beside the
/// caller beats one across the project; the project beats what it depends on;
/// and a thing declared as a function beats the same name bound to a value.
enum DefinitionRanking {
    /// Best first, and stable: the same click gives the same answer.
    static func ranked(
        _ candidates: [SymbolDefinition],
        from origin: String,
        hints: [String] = []
    ) -> [SymbolDefinition] {
        candidates
            .map { (definition: $0, score: score($0, from: origin, hints: hints)) }
            .sorted {
                $0.score == $1.score
                    ? ($0.definition.path, $0.definition.line) < ($1.definition.path, $1.definition.line)
                    : $0.score > $1.score
            }
            .map(\.definition)
    }

    static func score(_ definition: SymbolDefinition, from origin: String, hints: [String]) -> Int {
        var score = 0
        if definition.path == origin { score += 1_000 }
        if hints.contains(where: { mentions(definition.path, $0) }) { score += 500 }
        if folder(of: definition.path) == folder(of: origin) { score += 200 }
        if !DependencyScan.isDependency(definition.path) { score += 100 }
        score += shared(definition.path, origin) * 10
        // A function over a binding of the same name, which is what a
        // re-export usually is.
        score += (10 - definition.kind.precedence) * 2
        // And the nearer the surface the better: a package's own entry rather
        // than something buried in it.
        score -= (definition.path as NSString).pathComponents.count
        return score
    }

    /// The modules and classes a file names at the top of itself.
    ///
    /// `import { ref } from 'vue'` and `use Illuminate\Support\Facades\Route;`
    /// are the file saying which of several `ref`s and `Route`s it means, in
    /// the only terms it has. Kept as fragments of a path, because that is
    /// what they are on disk.
    static func hints(in text: String) -> [String] {
        var found: [String] = []
        for pattern in patterns {
            // Line by line: an import is at the start of its own line, and
            // without this `^` means the start of the file — which is a `<?php`
            // or a comment, and never a `use`.
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
            else { continue }
            let source = text as NSString
            expression.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
                guard let match, match.numberOfRanges > 1 else { return }
                let captured = source.substring(with: match.range(at: 1))
                if let hint = normalised(captured) { found.append(hint) }
            }
        }
        return found
    }

    /// Only the head of a file is read for these: an import lives there, and
    /// a string that looks like one further down is somebody's example.
    private static let patterns = [
        #"from\s+['"]([^'"]+)['"]"#,
        #"require\(\s*['"]([^'"]+)['"]"#,
        #"^\s*import\s+['"]([^'"]+)['"]"#,
        #"^\s*use\s+([A-Za-z0-9_\\]+)"#,
    ]

    private static func normalised(_ specifier: String) -> String? {
        var hint = specifier.replacingOccurrences(of: "\\", with: "/")
        // `@/components/Card.vue` and `./Card.vue` name the same file as
        // `components/Card.vue` once the alias and the walk are taken off.
        while hint.hasPrefix("./") || hint.hasPrefix("../") || hint.hasPrefix("@/") || hint.hasPrefix("/") {
            hint = String(hint.drop(while: { $0 == "." || $0 == "@" || $0 == "/" }))
        }
        return hint.isEmpty ? nil : hint
    }

    /// Whether a path is the thing a hint names.
    private static func mentions(_ path: String, _ hint: String) -> Bool {
        if path.contains("/\(hint)/") || path.hasSuffix("/\(hint)") { return true }
        return (path as NSString).deletingPathExtension.hasSuffix("/\(hint)")
    }

    private static func folder(of path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// How much of two paths is the same, counted in folders.
    private static func shared(_ first: String, _ second: String) -> Int {
        let left = (first as NSString).pathComponents
        let right = (second as NSString).pathComponents
        var count = 0
        while count < min(left.count, right.count), left[count] == right[count] { count += 1 }
        return count
    }
}
