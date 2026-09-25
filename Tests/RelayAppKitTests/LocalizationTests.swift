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

    static func allKeys(_ language: String) throws -> Set<String> {
        try Set(table(language).keys)
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
