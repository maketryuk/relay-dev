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
}
