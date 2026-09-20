import Foundation

/// The tags a template language adds to the language it is written in.
///
/// Blade, Vue, Twig and the rest have no grammar here, so a file of theirs is
/// read as its host — HTML, or PHP — and everything the host understands comes
/// out right. What the host has never heard of is the handful of tags the
/// template language is *for*: `@section`, `{{ $name }}`, `defineModel`. Those
/// are matched by pattern and painted over the parse.
///
/// Deliberately a short list of unmistakable shapes rather than an attempt at a
/// grammar. A directive is `@word` at the start of an expression, an
/// interpolation is a double brace: both are unambiguous enough to match by
/// eye, and neither is worth a parser. Anything subtler belongs to a real
/// grammar, not to this.
enum TemplateMarkup: Equatable, Sendable {
    case blade
    case vue
    case twig
    case erb
    case handlebars

    /// The file this markup belongs to, by extension.
    static func forFile(named name: String) -> TemplateMarkup? {
        let lowered = name.lowercased()
        if lowered.hasSuffix(".blade.php") { return .blade }

        return switch (lowered as NSString).pathExtension {
        case "vue", "svelte": .vue
        case "twig", "liquid", "njk": .twig
        case "erb", "ejs": .erb
        case "hbs", "handlebars", "mustache": .handlebars
        default: nil
        }
    }

    /// A pattern and what to paint what it finds.
    struct Rule {
        let pattern: String
        let role: SourceHighlighter.Role
    }

    var rules: [Rule] {
        switch self {
        case .blade:
            [
                // `@section`, `@endsection`, `@if`, `@foreach` — and `@@` which
                // is how a Blade file writes a literal at-sign.
                Rule(pattern: #"@@?[a-zA-Z_][a-zA-Z0-9_]*"#, role: .keyword),
                // `{{ … }}`, `{!! … !!}` and `{{-- … --}}`: only the braces, so
                // whatever the host made of the expression inside survives.
                Rule(pattern: #"\{\{--|--\}\}|\{!!|!!\}|\{\{|\}\}"#, role: .keyword),
            ]
        case .vue:
            [
                // Compiler macros. To JavaScript they are ordinary calls, which
                // is exactly what they are not: they only exist inside a
                // component and they are the first thing read in one.
                Rule(
                    pattern: #"\b(defineProps|defineEmits|defineModel|defineExpose|defineOptions|defineSlots|defineAsyncComponent|withDefaults)\b"#,
                    role: .keyword
                ),
                // `v-if`, `v-for`, `v-model:value` and the shorthands `:prop`
                // and `@click`, which HTML reads as attribute names it has
                // never seen.
                Rule(pattern: #"\bv-[a-zA-Z][a-zA-Z0-9-]*(:[a-zA-Z0-9.-]+)?"#, role: .keyword),
                Rule(pattern: #"(?<=\s)[:@#][a-zA-Z][a-zA-Z0-9.:-]*(?==)"#, role: .keyword),
            ]
        case .twig:
            [
                Rule(pattern: #"\{%-?|-?%\}|\{\{|\}\}|\{#|#\}"#, role: .keyword),
            ]
        case .erb:
            [
                Rule(pattern: #"<%={1,2}|<%-|<%#|<%|-?%>"#, role: .keyword),
            ]
        case .handlebars:
            [
                Rule(pattern: #"\{\{\{?[#/>!]?|\}?\}\}"#, role: .keyword),
            ]
        }
    }

    /// Everything these rules find in the text.
    func spans(in text: String) -> [SourceHighlighter.Span] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        return rules.flatMap { rule -> [SourceHighlighter.Span] in
            guard let expression = try? NSRegularExpression(pattern: rule.pattern) else { return [] }
            return expression.matches(in: text, range: full).map {
                SourceHighlighter.Span(range: $0.range, role: rule.role)
            }
        }
    }
}
