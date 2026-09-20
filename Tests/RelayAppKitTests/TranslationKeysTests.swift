import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("A key written as a string")
struct TranslationKeysTests {
    /// The layout a real Nuxt project uses: `i18n/locales/<language>/<file>.json`,
    /// where the file is named after the key's first segment.
    private func project() throws -> TemporaryDirectory {
        let directory = try TemporaryDirectory()
        try directory.write(
            """
            {
                "seo": {
                    "title": "Example",
                    "subtitle": "Everything in one place"
                }
            }
            """,
            to: "i18n/locales/ru/common.json"
        )
        try directory.write(
            """
            {
                "seo": {
                    "subtitle": "Landing pages"
                }
            }
            """,
            to: "i18n/locales/ru/landings.json"
        )
        try directory.write(#"{ "name": "probe" }"#, to: "package.json")
        return directory
    }

    @Test("The file is named after the first segment of the key")
    func namespacedByFile() throws {
        // `common.seo.subtitle` lives in `common.json` as
        // `seo.subtitle`, which no index of names will ever find.
        let directory = try project()
        let files = ProjectFiles.walk(root: directory.url.path)

        let found = TranslationKeys.find("common.seo.subtitle", in: files)

        #expect(found.count == 1)
        let first = try #require(found.first)
        #expect(first.path.hasSuffix("i18n/locales/ru/common.json"))
        #expect(first.line == 4)
        #expect(first.name == "subtitle")
    }

    @Test("A key written out in full is found as written")
    func fullPath() throws {
        let directory = try TemporaryDirectory()
        try directory.write(
            """
            {
                "common": {
                    "seo": {
                        "subtitle": "x"
                    }
                }
            }
            """,
            to: "locales/en.json"
        )

        let found = TranslationKeys.find(
            "common.seo.subtitle",
            in: ProjectFiles.walk(root: directory.url.path)
        )

        #expect(found.count == 1)
        #expect(found.first?.line == 4)
    }

    @Test("A file that merely contains the words does not define the key")
    func noFalsePositives() throws {
        // `seo` and `subtitle` turn up in half the locale files a
        // project has; what settles it is the path being there.
        let directory = try project()
        let files = ProjectFiles.walk(root: directory.url.path)

        #expect(TranslationKeys.find("landings.seo.title", in: files).isEmpty)
        #expect(TranslationKeys.find("common.seo.missing", in: files).isEmpty)
    }

    @Test("Only the files a project keeps translations in are read")
    func onlyLocaleFiles() throws {
        let directory = try project()
        let files = ProjectFiles.walk(root: directory.url.path)

        let candidates = TranslationKeys.candidates(among: files)
        #expect(candidates.count == 2)
        #expect(!candidates.contains { $0.hasSuffix("package.json") })
    }

    @Test("Two files defining one key are both offered")
    func several() throws {
        let directory = try project()
        let files = ProjectFiles.walk(root: directory.url.path)

        // `seo.subtitle` without a namespace matches both files.
        #expect(TranslationKeys.find("seo.subtitle", in: files).count == 2)
    }
}

@Suite("The string under the caret")
struct StringLiteralTests {
    @Test("What is between the quotes")
    func inside() throws {
        let text = "const x = t('common.seo.subtitle')\n"
        let offset = (text as NSString).range(of: "subtitle").location + 2
        let literal = try #require(SymbolWord.literal(in: text, at: offset))

        #expect(literal.text == "common.seo.subtitle")
    }

    @Test("Outside a string is not a string")
    func outside() {
        let text = "const x = t('a.b')\n"
        #expect(SymbolWord.literal(in: text, at: 2) == nil)
        // Nor is an opening quote with nothing closing it.
        #expect(SymbolWord.literal(in: "const x = 'open\n", at: 12) == nil)
    }

    @Test("Double quotes and backticks count too")
    func everyQuote() {
        #expect(SymbolWord.literal(in: "t(\"a.b\")\n", at: 4)?.text == "a.b")
        #expect(SymbolWord.literal(in: "t(`a.b`)\n", at: 4)?.text == "a.b")
    }
}

@Suite("What is worth ⌘-clicking")
struct LinkRangeTests {
    @Test("A word in code is a link; a word in a plain string is not")
    func plainStrings() {
        // `platform: 'theme_preference'` is a value: nothing declares it
        // anywhere, and a link under it promises a jump that cannot exist.
        let text = "export const KEYS = { platform: 'theme_preference' };\n"
        let inString = (text as NSString).range(of: "theme_preference").location + 3
        let inCode = (text as NSString).range(of: "KEYS").location + 1

        #expect(CodeTextView.linkRange(in: text, at: inString) == nil)
        #expect(CodeTextView.linkRange(in: text, at: inCode) != nil)
    }

    @Test("A word in the second string of a line is still in a string")
    func severalStringsOnOneLine() {
        // The line that showed this up: a ⌘-click on `max` jumped to a
        // `const max` in another file, which has nothing to do with it.
        let text = "const isPlatform = (value: unknown) => value === 'telegram' || value === 'max';\n"
        let inSecond = (text as NSString).range(of: "'max'").location + 2

        #expect(SymbolWord.literal(in: text, at: inSecond)?.text == "max")
        #expect(CodeTextView.linkRange(in: text, at: inSecond) == nil)
    }

    @Test("A string that names something still is one")
    func keysAndPaths() {
        // A key with dots and a path with slashes both resolve, so both keep
        // their link.
        let key = "t('common.seo.title')\n"
        #expect(CodeTextView.linkRange(in: key, at: (key as NSString).range(of: "title").location + 1) != nil)

        let path = "import Card from './cards/UserCard.vue'\n"
        #expect(CodeTextView.linkRange(in: path, at: (path as NSString).range(of: "UserCard").location + 1) != nil)
    }
}
