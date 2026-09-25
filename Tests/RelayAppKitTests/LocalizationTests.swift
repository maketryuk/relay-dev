import Foundation
import Testing

@testable import RelayAppKit
@testable import RelayProtocol
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
        let english = try Set(Self.table("en").keys)
        let russian = try Set(Self.table("ru").keys)
        #expect(!english.isEmpty)
        #expect(english == russian, "tables differ: \(english.symmetricDifference(russian))")
    }

    @Test("Every phrase the app looks up has a translation")
    func everyLookupIsTranslated() throws {
        // The two tables agreeing with each other is not enough. A phrase that
        // was never added to either is invisible to that check and simply shows
        // English in a Russian window — which is exactly how "All hosts"
        // survived being localised twice over.
        let known = try Self.allKeys("en")
        var missing = Set<String>()
        for file in try Self.appSources() {
            for literal in Self.lookedUp(in: file) where !known.contains(literal.text) {
                missing.insert(literal.text)
            }
        }
        #expect(missing.isEmpty, "no entry for: \(missing.sorted())")
    }

    @Test("No label is a literal SwiftUI would look up in the app's own bundle")
    func noLabelIsLeftToSwiftUI() throws {
        // `Text("Sessions")` is a `LocalizedStringKey`, and SwiftUI looks it up
        // in the main bundle — which has no string table and does not know the
        // language Relay was set to. Such a label is English whatever the
        // setting, and it compiles, runs and reads fine to whoever wrote it.
        var offenders: [String] = []
        for file in try Self.appSources() {
            for name in Self.labelledByKey {
                for arguments in file.arguments(ofCallsTo: name) {
                    let first = file.firstArgument(of: arguments)
                    let written = String(file.characters[first]).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !written.hasPrefix("verbatim:") else { continue }
                    for literal in file.literals(in: first) where file.isTopLevel(literal, in: first) {
                        let words = literal.text.replacingOccurrences(of: "\\(…)", with: "")
                        guard words.contains(where: \.isLetter) else { continue }
                        offenders.append("\(file.location(of: literal.start)) \(name)(\"\(literal.text)\")")
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "looked up in the main bundle: \(offenders)")
    }

    @Test("A phrase the table translates is looked up where it is written")
    func translatedPhrasesAreLookedUp() throws {
        // A key handed to a view as a plain String is shown as it is: in
        // English. The table having the phrase proves nothing if the code never
        // asks for it, and no lookup check can see a lookup that is not there.
        // Single words are left out — "User" is also an ssh keyword, "ours" a
        // git label — and so are the names the model hands over to be looked
        // up later: the arms of a switch, and the names the test below asks
        // each type for.
        let russian = try Self.table("ru")
        let english = try Self.table("en")
        let phrases = Set(english.keys.filter { key in
            key.contains(" ") && russian[key] != english[key]
        }).subtracting(Self.handedOverNames)
        var offenders: [String] = []
        for file in try Self.appSources() {
            let lookedUp = Set(Self.lookedUp(in: file).map(\.start))
            for literal in file.literals where phrases.contains(literal.text) && !lookedUp.contains(literal.start) {
                if let arm = file.lineEndingInColon(before: literal),
                   arm.hasPrefix("case ") || arm.hasPrefix("default") { continue }
                offenders.append("\(file.location(of: literal.start)) \"\(literal.text)\"")
            }
        }
        #expect(offenders.isEmpty, "shown without being looked up: \(offenders)")
    }

    @Test("Every entry in the tables is still asked for")
    func everyEntryIsAskedFor() throws {
        // An entry nothing asks for is how a reworded phrase loses its
        // translation without anyone noticing: the code says something new, the
        // table keeps translating the old words, and both tests above stay
        // green. A key that is not a literal anywhere in the tree cannot be
        // asked for — least of all one the code builds by interpolation.
        var written = Set<String>()
        for file in try SwiftSourceFile.all(under: Self.repositoryRoot.appendingPathComponent("Sources")) {
            for literal in file.literals where !literal.isInterpolated {
                written.insert(literal.text)
            }
        }
        let stale = try Self.allKeys("en").subtracting(written)
        #expect(stale.isEmpty, "nothing asks for: \(stale.sorted())")
    }

    @Test("Both tables leave the same blanks for the same things")
    func blanksAgree() throws {
        // `String(format:)` fills blanks by position and type. A translation
        // with one blank fewer drops a name; one with `%@` where the key has
        // `%d` takes a number for an object, and crashes.
        var mismatched: [String] = []
        for language in ["en", "ru"] {
            for (key, wordings) in try Self.wordings(language) {
                let expected = Self.blanks(in: key)
                for wording in wordings where Self.blanks(in: wording) != expected {
                    mismatched.append("\(language): \"\(key)\" = \"\(wording)\"")
                }
            }
        }
        #expect(mismatched.isEmpty, "blanks differ: \(mismatched)")
    }

    @Test("Every name a type hands to the table has an entry")
    func everyNameHasAnEntry() throws {
        // These are looked up through a variable — `relayLocalized(title)` —
        // which no reading of the source can follow to its values. Asking each
        // type for all of them can.
        let known = try Self.allKeys("en")
        let missing = Self.handedOverNames.subtracting(known)
        #expect(missing.isEmpty, "no entry for: \(missing.sorted())")
    }

    /// Every name a type of the model hands to `relayLocalized` through a
    /// variable.
    private static var handedOverNames: Set<String> {
        var names = Set<String>()
        names.formUnion(RelayCommand.allCases.map(\.title))
        names.formUnion(ShortcutCategory.allCases.map(\.title))
        names.formUnion(RightSidebarTab.allCases.map(\.title))
        names.formUnion(RuntimeStatus.allCases.map(\.displayName))
        names.formUnion(ServiceState.allCases.map(\.displayName))
        names.formUnion(SessionKind.allCases.map(\.displayName))
        names.formUnion(ComposeAction.allCases.map(\.title))
        names.formUnion(ContainerAction.allCases.map(\.title))
        names.formUnion(GitActions.Remote.allCases.map(\.title))
        names.formUnion(SessionPresets.suppliedNames)
        return names
    }

    @Test("A count takes the form its language gives it")
    func countsTakeTheirForm() {
        // Russian has three forms where English has two, and chooses by the
        // last digits: 21 takes the form of 1, 11 the form of 5.
        withLanguage(.russian) {
            #expect(relayLocalized("%d branches", count: 1) == "1 ветка")
            #expect(relayLocalized("%d branches", count: 3) == "3 ветки")
            #expect(relayLocalized("%d branches", count: 5) == "5 веток")
            #expect(relayLocalized("%d branches", count: 11) == "11 веток")
            #expect(relayLocalized("%d branches", count: 21) == "21 ветка")
        }
        withLanguage(.english) {
            #expect(relayLocalized("%d branches", count: 1) == "1 branch")
            #expect(relayLocalized("%d branches", count: 2) == "2 branches")
        }
    }

    @Test("Every phrase with a count has each form its language needs")
    func pluralsAreComplete() throws {
        // A missing form falls back to "other", which Russian keeps for
        // fractions: "5 ветки" rather than "5 веток".
        let needed: [String: Set<String>] = ["en": ["one", "other"], "ru": ["one", "few", "many", "other"]]
        let english = try Self.pluralTable("en")
        let russian = try Self.pluralTable("ru")
        #expect(!english.isEmpty)
        #expect(Set(english.keys) == Set(russian.keys))
        for (language, table) in [("en", english), ("ru", russian)] {
            for (key, forms) in table {
                #expect(Set(forms.keys) == needed[language], "\(language): \(key)")
            }
        }
        // A phrase in both files has a plain entry nothing will read.
        let plain = try Set(Self.table("en").keys)
        #expect(plain.isDisjoint(with: english.keys), "in both: \(plain.intersection(english.keys))")
    }

    @Test("Sizes and times are written in the interface's language, not the system's")
    func formatsFollowTheInterface() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let earlier = now.addingTimeInterval(-2 * 3600)
        withLanguage(.russian) {
            #expect(relayByteCount(2_500_000).contains("МБ"))
            #expect(relayRelativeTime(earlier, relativeTo: now).contains("назад"))
        }
        withLanguage(.english) {
            #expect(relayByteCount(2_500_000).contains("MB"))
            #expect(relayRelativeTime(earlier, relativeTo: now).contains("ago"))
        }
    }

    // MARK: - Reading the tables

    /// The checkout, found from this file rather than from the working
    /// directory, which a test runner does not promise anything about.
    static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The tables as they ship, read from the built bundle rather than from a
    /// copy that could drift from it.
    private static func lproj(_ language: String) throws -> Bundle {
        let path = try #require(RelayUIResources.bundle.path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    static func table(_ language: String) throws -> [String: String] {
        let url = try #require(lproj(language).url(forResource: "Localizable", withExtension: "strings"))
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        return try #require(plist as? [String: String])
    }

    /// The forms of every phrase with a count in it, by plural category:
    /// `"one": "%d ветка"`, `"few": "%d ветки"` and so on.
    static func pluralTable(_ language: String) throws -> [String: [String: String]] {
        guard let url = try lproj(language).url(forResource: "Localizable", withExtension: "stringsdict") else { return [:] }
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        let entries = try #require(plist as? [String: [String: Any]])
        return try entries.mapValues { entry in
            let format = try #require(entry["NSStringLocalizedFormatKey"] as? String)
            let variable = try #require(entry.first { $0.key != "NSStringLocalizedFormatKey" })
            let rules = try #require(variable.value as? [String: String])
            var forms: [String: String] = [:]
            for (category, form) in rules where !category.hasPrefix("NSString") {
                forms[category] = format.replacingOccurrences(of: "%#@\(variable.key)@", with: form)
            }
            return forms
        }
    }

    static func allKeys(_ language: String) throws -> Set<String> {
        try Set(table(language).keys).union(pluralTable(language).keys)
    }

    /// Every wording a key can end up as, plural forms included.
    private static func wordings(_ language: String) throws -> [String: [String]] {
        var wordings = try table(language).mapValues { [$0] }
        for (key, forms) in try pluralTable(language) {
            wordings[key, default: []] += forms.values
        }
        return wordings
    }

    /// The blanks a format string leaves, in the order they are filled.
    static func blanks(in format: String) -> [String] {
        let pattern = #"%(?:(\d+)\$)?[-+ 0#']*\d*(?:\.\d+)?(?:hh|h|ll|l|q|z|t|j)?([@dDiuUxXoOfeEgGcCsSpaAF%])"#
        let expression = try? NSRegularExpression(pattern: pattern)
        let whole = NSRange(format.startIndex..., in: format)
        var ordered: [(position: Int, type: String)] = []
        for (index, match) in (expression?.matches(in: format, range: whole) ?? []).enumerated() {
            guard let typeRange = Range(match.range(at: 2), in: format), format[typeRange] != "%" else { continue }
            let position = Range(match.range(at: 1), in: format).flatMap { Int(format[$0]) } ?? index + 1
            ordered.append((position, String(format[typeRange])))
        }
        return ordered.sorted { $0.position < $1.position }.map(\.type)
    }

    // MARK: - Reading the source

    /// The targets with an interface. The daemon, the hook and the `relay`
    /// command speak English on purpose: what they print is read by agents and
    /// by scripts, and none of them links the tables.
    static func appSources() throws -> [SwiftSourceFile] {
        let sources = repositoryRoot.appendingPathComponent("Sources")
        return try ["RelayApp", "RelayAppKit", "RelayUI"].flatMap {
            try SwiftSourceFile.all(under: sources.appendingPathComponent($0))
        }
    }

    /// The calls that take a key and look it up.
    ///
    /// `localized(` as well as `relayLocalized(`, because the notification
    /// policy takes its lookup as a parameter to stay off the main actor, and a
    /// format string it never registered would reach the user as English.
    private static let lookups = ["relayLocalized", "localized", "relaySearchTerms"]

    /// Every literal handed to the table: anything inside a lookup — both arms
    /// of a ternary included, the form that hides a phrase from a naive search —
    /// and the `titleKey:` of a palette entry, which looks itself up.
    ///
    /// An interpolated literal is kept rather than skipped: it can never match
    /// a key, and saying so is the point.
    static func lookedUp(in file: SwiftSourceFile) -> [SwiftSourceFile.Literal] {
        var found = lookups.flatMap { name in
            file.arguments(ofCallsTo: name).flatMap { file.literals(in: $0) }
        }
        found += file.literals.filter { file.codeBefore($0, length: 9) == "titleKey:" }
        return found
    }

    /// The SwiftUI initialisers and modifiers whose first argument, when it is a
    /// literal, is a `LocalizedStringKey`.
    private static let labelledByKey = [
        "Text", "Button", "Label", "Toggle", "Menu", "Section", "Picker", "TextField", "SecureField",
        "Link", "CommandMenu", "LabeledContent", "GroupBox", "DisclosureGroup", "Stepper",
        "NavigationLink", "ContentUnavailableView",
        ".help", ".navigationTitle", ".accessibilityLabel", ".accessibilityHint", ".accessibilityValue",
        ".confirmationDialog", ".alert", ".badge",
    ]
}
