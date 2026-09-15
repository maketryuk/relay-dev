import Foundation
import Testing

@testable import RelayUI

@Suite("Localisation", .serialized)
@MainActor
struct LocalizationTests {
    private func withLanguage(_ language: AppLanguage, _ body: () -> Void) {
        let previous = Localization.shared.language
        Localization.shared.language = language
        body()
        Localization.shared.language = previous
    }

    @Test("English returns the key itself, since the key is the English text")
    func englishIsTheSource() {
        withLanguage(.english) {
            #expect(relayLocalized("Sessions") == "Sessions")
            #expect(relayLocalized("Waiting for you") == "Waiting for you")
        }
    }

    @Test("Russian returns a translation")
    func russianTranslates() {
        withLanguage(.russian) {
            #expect(relayLocalized("Sessions") == "Сессии")
            #expect(relayLocalized("Waiting for you") == "Ждёт вас")
            #expect(relayLocalized("Settings") == "Настройки")
        }
    }

    @Test("An untranslated string degrades to readable English, not to a raw key")
    func missingTranslationFallsBack() {
        // The point of using the English text as the key: a gap in the table is
        // a missing translation, never a visible identifier.
        withLanguage(.russian) {
            #expect(relayLocalized("Not in any table") == "Not in any table")
        }
    }

    @Test("Switching language changes the result immediately")
    func switchingTakesEffect() {
        withLanguage(.english) { #expect(relayLocalized("Ports") == "Ports") }
        withLanguage(.russian) { #expect(relayLocalized("Ports") == "Порты") }
    }

    @Test("Every language has a name written in itself")
    func languageNames() {
        #expect(AppLanguage.english.displayName == "English")
        #expect(AppLanguage.russian.displayName == "Русский")
        #expect(AppLanguage.system.code == nil)
    }

    @Test("The Russian table covers everything the English one declares")
    func tablesAgree() throws {
        // A key present in one table and absent from the other is a translation
        // that silently shows English to a Russian user.
        func keys(_ language: String) throws -> Set<String> {
            let path = try #require(RelayUIResources.bundle.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
            let contents = try String(contentsOf: url, encoding: .utf8)
            var result = Set<String>()
            for line in contents.split(separator: "\n") {
                guard line.hasPrefix("\"") else { continue }
                let parts = line.split(separator: "\" = \"")
                guard let first = parts.first else { continue }
                result.insert(String(first.dropFirst()))
            }
            return result
        }
        let english = try keys("en")
        let russian = try keys("ru")
        #expect(!english.isEmpty)
        #expect(english == russian, "tables differ: \(english.symmetricDifference(russian))")
    }

    @Test("Every phrase the app looks up has a translation")
    func everyLookupIsTranslated() throws {
        // The two tables agreeing with each other is not enough. A phrase that
        // was never added to either is invisible to that check and simply shows
        // English in a Russian window — which is exactly how "All hosts"
        // survived being localised twice over.
        let sources = Self.repositoryRoot.appendingPathComponent("Sources")
        let english = try Self.tableKeys("en")

        var missing = Set<String>()
        for file in Self.swiftFiles(under: sources) {
            let contents = try String(contentsOf: file, encoding: .utf8)
            for phrase in Self.localizedPhrases(in: contents) where !english.contains(phrase) {
                missing.insert(phrase)
            }
        }
        #expect(missing.isEmpty, "no entry for: \(missing.sorted())")
    }

    // MARK: - Reading the source

    /// The checkout, found from this file rather than from the working
    /// directory, which a test runner does not promise anything about.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func swiftFiles(under directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    private static func tableKeys(_ language: String) throws -> Set<String> {
        let path = try #require(RelayUIResources.bundle.path(forResource: language, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        let url = try #require(bundle.url(forResource: "Localizable", withExtension: "strings"))
        let contents = try String(contentsOf: url, encoding: .utf8)
        var keys = Set<String>()
        for line in contents.split(separator: "\n") where line.hasPrefix("\"") {
            guard let key = line.split(separator: "\" = \"").first else { continue }
            keys.insert(String(key.dropFirst()))
        }
        return keys
    }

    /// Every literal handed to the table, including the two arms of a ternary —
    /// the form that hides a phrase from a naive search.
    ///
    /// `localized(` as well as `relayLocalized(`, because the notification
    /// policy takes its lookup as a parameter to stay off the main actor, and a
    /// format string it never registered would reach the user as English.
    static func localizedPhrases(in source: String) -> [String] {
        ["relayLocalized(", "localized("].flatMap { phrases(in: source, calledWith: $0) }
    }

    private static func phrases(in source: String, calledWith name: String) -> [String] {
        var phrases: [String] = []
        let characters = Array(source)
        var index = 0
        let call = Array(name)

        while index + call.count < characters.count {
            guard Array(characters[index ..< index + call.count]) == call else {
                index += 1
                continue
            }
            var cursor = index + call.count
            var depth = 1

            while cursor < characters.count, depth > 0 {
                switch characters[cursor] {
                case "(": depth += 1
                case ")": depth -= 1
                case "\"":
                    var text = ""
                    cursor += 1
                    while cursor < characters.count, characters[cursor] != "\"" {
                        // A literal carrying an interpolation is not a key.
                        if characters[cursor] == "\\" { cursor += 1 }
                        text.append(characters[cursor])
                        cursor += 1
                    }
                    phrases.append(text)
                default: break
                }
                cursor += 1
            }
            index = cursor
        }
        return phrases
    }
}
