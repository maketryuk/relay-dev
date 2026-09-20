import AppKit
import Foundation
import Testing

@testable import RelayAppKit

@Suite("Source languages")
struct SourceLanguageTests {
    @Test("A known extension names the language")
    func byExtension() {
        #expect(SourceLanguage.detect(path: "/p/SessionRuntime.swift", contents: "")?.code.tsName == "swift")
        #expect(SourceLanguage.detect(path: "/p/daemon.go", contents: "")?.code.tsName == "go")
        #expect(SourceLanguage.detect(path: "/p/Controller.php", contents: "")?.code.tsName == "php")
        #expect(SourceLanguage.detect(path: "/p/bus.ts", contents: "")?.code.tsName == "typescript")
        #expect(SourceLanguage.detect(path: "/p/compose.yaml", contents: "")?.code.tsName == "yaml")
    }

    @Test("A script with no extension is read from its shebang")
    func byShebang() {
        // `Scripts/release.sh` has an extension, but the files installed into a
        // path do not, and a shell script shown in one colour is a shell script
        // nobody can read.
        let language = SourceLanguage.detect(
            path: "/usr/local/bin/relay-release",
            contents: "#!/usr/bin/env bash\nset -euo pipefail\n"
        )
        #expect(language?.code.tsName == "bash")
    }

    @Test("Environment files are read as shell, which is what they are")
    func environmentFiles() {
        // `.env` has no grammar of its own anywhere. The shell's describes the
        // whole of the format: `# comment`, `KEY=value`, `${expansion}`.
        #expect(SourceLanguage.detect(path: "/p/.env", contents: "A=1")?.code.tsName == "bash")
        #expect(SourceLanguage.detect(path: "/p/.env.local", contents: "A=1")?.code.tsName == "bash")
    }

    @Test("A template is read as the language it is mostly made of")
    func templates() {
        // None of these has a grammar here. Read as their host they come out
        // almost entirely right; read as nothing they are a white page.
        #expect(SourceLanguage.detect(path: "/p/App.vue", contents: "<template></template>")?.code.tsName == "html")
        #expect(SourceLanguage.detect(path: "/p/Card.svelte", contents: "")?.code.tsName == "html")
        #expect(SourceLanguage.detect(path: "/p/page.twig", contents: "")?.code.tsName == "html")
        // Blade already ends in .php, and PHP injects HTML into itself.
        #expect(SourceLanguage.detect(path: "/p/page.blade.php", contents: "")?.code.tsName == "php")
    }

    @Test("A file nothing recognises has no language rather than a wrong one")
    func unknown() {
        #expect(SourceLanguage.detect(path: "/p/LICENSE", contents: "Copyright") == nil)
        #expect(SourceLanguage.detect(path: "/p/.gitignore", contents: "build/") == nil)
    }
}

@Suite("Syntax colouring")
@MainActor
struct SourceHighlighterTests {
    @Test("A capture name is matched by its head, not in full")
    func captureNames() {
        // Grammars invent their own tails — `keyword.function`,
        // `string.special.path`, `punctuation.bracket` — and a table that
        // matched them whole would colour half of every file plain.
        #expect(SourceHighlighter.role(for: "keyword.function") == .keyword)
        #expect(SourceHighlighter.role(for: "punctuation.bracket") == .punctuation)
        #expect(SourceHighlighter.role(for: "string.special.path") == .string)
        #expect(SourceHighlighter.role(for: "type.builtin") == .type)
    }

    @Test("An unclaimed capture is left plain rather than guessed at")
    func unknownCapture() {
        #expect(SourceHighlighter.role(for: "diff.plus") == .plain)
        #expect(SourceHighlighter.role(for: "") == .plain)
    }

    @Test("Comments lean")
    func commentsAreItalic() throws {
        let attributes = SourceHighlighter.attributes(for: "comment.line", fontSize: 12)
        let font = try #require(attributes[.font] as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.italic))
    }

    @Test("A keyword, a string and a comment come back as themselves")
    func spansName() throws {
        let text = """
        // one
        let a = "b"
        """
        let spans = SourceHighlighter.spans(in: text, language: SourceLanguage(code: .swift))
        let source = text as NSString
        let named = Dictionary(grouping: spans) { $0.role }
            .mapValues { $0.map { source.substring(with: $0.range) } }

        #expect(named[.keyword]?.contains("let") == true)
        #expect(named[.string]?.contains(where: { $0.contains("b") }) == true)
        #expect(named[.comment]?.contains(where: { $0.contains("one") }) == true)
    }

    @Test("Ranges land on the right characters in a file that is not ASCII")
    func offsetsSurviveNonASCII() throws {
        // The failure this exists for is silent and late: tree-sitter counts in
        // one unit, `NSTextStorage` in another, and a mismatch only shows on a
        // file with Cyrillic or an emoji in it — every ASCII file looks fine.
        let text = """
        // комментарий 🌍 про приветствие
        let приветствие = "мир 🌍"
        func main() {}
        """
        let spans = SourceHighlighter.spans(in: text, language: SourceLanguage(code: .swift))
        let source = text as NSString

        for span in spans {
            #expect(NSMaxRange(span.range) <= source.length)
        }

        let keywords = spans.filter { $0.role == .keyword }.map { source.substring(with: $0.range) }
        #expect(keywords.contains("func"))
        #expect(keywords.contains("let"))

        let strings = spans.filter { $0.role == .string }.map { source.substring(with: $0.range) }
        #expect(strings.contains(where: { $0.contains("мир") }))

        let functions = spans.filter { $0.role == .function }.map { source.substring(with: $0.range) }
        #expect(functions.contains("main"))
    }

    @Test("A grammar that inherits its rules is coloured by all of them")
    func inheritedQueries() {
        // TypeScript's own query file describes type annotations and nothing
        // else; everything about functions, properties and constants is in
        // JavaScript's, which it names as its parent. Read alone it colours the
        // types and leaves the rest of the file white — which is what shipped.
        let text = """
        import { storeToRefs } from 'pinia';

        const service = useAnalyticsService();
        const init = (channelId: string) => service.fetch(channelId);
        """
        let spans = SourceHighlighter.spans(in: text, language: SourceLanguage(code: .typescript))
        let roles = Set(spans.map(\.role))

        #expect(roles.contains(.keyword))
        #expect(roles.contains(.string))
        #expect(roles.contains(.type))
        #expect(roles.contains(.function), "calls are left plain, so the parent query is missing")
        #expect(roles.contains(.property), "properties are left plain, so the parent query is missing")
    }

    @Test("Markup inside PHP is coloured, which is what a template mostly is")
    func injectedMarkup() {
        // To PHP the markup around its tags is one undifferentiated run of
        // text, and its highlight query says nothing about it. A Blade
        // template — markup with a handful of directives and often not one
        // `<?php` tag — came back with nothing coloured at all.
        let blade = """
        <div class="card">
            @if ($user->isAdmin())
                <span>{{ $user->name }}</span>
            @endif
        </div>
        """
        let spans = SourceHighlighter.spans(in: blade, language: SourceLanguage(code: .php))
        #expect(!spans.isEmpty, "a template with no PHP tags in it is not coloured at all")

        let regions = SourceHighlighter.injectedRegions(in: blade, language: SourceLanguage(code: .php))
        #expect(regions.contains { $0.language == "html" })
    }

    @Test("Script and style inside a page are coloured as what they are")
    func injectedScriptAndStyle() {
        let page = """
        <div id="app"></div>
        <script>const total = items.length;</script>
        <style>.card { color: red; }</style>
        """
        let regions = SourceHighlighter.injectedRegions(in: page, language: SourceLanguage(code: .html))
        let languages = Set(regions.map(\.language))

        #expect(languages.contains("javascript"))
        #expect(languages.contains("css"))
    }

    @Test("A fenced code block is coloured as the language the fence names")
    func injectedFences() {
        let document = """
        Text before.

        ```go
        func main() {}
        ```
        """
        let regions = SourceHighlighter.injectedRegions(in: document, language: SourceLanguage(code: .markdown))
        #expect(regions.contains { $0.language == "go" })
    }

    @Test("The grammars can actually be read from the bundle")
    func grammarsLoad() throws {
        // The failure this catches is silent: `CodeEditLanguages` builds its
        // query path one directory too deep under SwiftPM, every query fails to
        // compile, and the only symptom is a file drawn in one colour.
        #expect(SourceHighlighter.grammarsAreReachable)

        let language = try #require(SourceLanguage.detect(path: "/p/a.swift", contents: ""))
        let tsLanguage = try #require(language.code.language)
        let queryURL = try #require(language.code.queryURL)
        let query = try tsLanguage.query(contentsOf: queryURL)
        #expect(query.patternCount > 0)
    }
}

@Suite("Template tags")
@MainActor
struct TemplateMarkupTests {
    @Test("Blade directives and echoes are coloured")
    func blade() {
        // To PHP — and to the HTML it injects — `@section` is a stray at-sign
        // followed by a word, and `{{ }}` is two braces. Both are the whole
        // point of the file.
        let text = """
        @extends('components.layout.main')
        @section('content')
            <div>{{ $client->name }}</div>
        @endsection
        """
        let language = try! #require(SourceLanguage.detect(path: "/p/index.blade.php", contents: text))
        #expect(language.markup == .blade)

        let spans = SourceHighlighter.spans(in: text, language: language)
        let source = text as NSString
        let keywords = spans.filter { $0.role == .keyword }.map { source.substring(with: $0.range) }

        #expect(keywords.contains("@extends"))
        #expect(keywords.contains("@section"))
        #expect(keywords.contains("@endsection"))
        #expect(keywords.contains("{{"))
        #expect(keywords.contains("}}"))
    }

    @Test("Vue's compiler macros and directives are coloured")
    func vue() {
        // `defineModel` is an ordinary function call as far as JavaScript is
        // concerned, and it is the first thing anybody reads in a component.
        let text = """
        <template>
            <input v-model="title" :disabled="busy" @click="save" />
        </template>
        <script setup>
        const title = defineModel('title');
        const props = defineProps({ busy: Boolean });
        </script>
        """
        let language = try! #require(SourceLanguage.detect(path: "/p/Card.vue", contents: text))
        #expect(language.markup == .vue)

        let spans = SourceHighlighter.spans(in: text, language: language)
        let source = text as NSString
        let keywords = spans.filter { $0.role == .keyword }.map { source.substring(with: $0.range) }

        #expect(keywords.contains("defineModel"))
        #expect(keywords.contains("defineProps"))
        #expect(keywords.contains("v-model"))
    }

    @Test("A plain file has no template markup to paint")
    func plainFiles() {
        #expect(TemplateMarkup.forFile(named: "SessionRuntime.swift") == nil)
        #expect(TemplateMarkup.forFile(named: "Controller.php") == nil)
        #expect(TemplateMarkup.forFile(named: "index.blade.php") == .blade)
        #expect(TemplateMarkup.forFile(named: "page.twig") == .twig)
    }
}
