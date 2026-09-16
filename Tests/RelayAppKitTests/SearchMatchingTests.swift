import Foundation
import Testing

@testable import RelayUI

@Suite("Command search", .serialized)
@MainActor
struct SearchMatchingTests {
    private func withLanguage(_ language: AppLanguage, _ body: () -> Void) {
        let previous = Localization.shared.language
        Localization.shared.language = language
        body()
        Localization.shared.language = previous
    }

    /// What the palette actually holds for the branch command.
    private var branchTerms: [String] {
        relaySearchTerms("Switch Branch")
    }

    @Test("A key carries every shipped wording, not just the visible one")
    func termsCoverBothLanguages() {
        withLanguage(.russian) {
            let terms = branchTerms
            #expect(terms.first == "Переключить ветку")
            #expect(terms.contains("Switch Branch"))
        }
    }

    @Test("The English name finds the command while the interface is in Russian")
    func englishNameFindsRussianCommand() {
        withLanguage(.russian) {
            #expect(RelaySearchQuery("branch").matches(branchTerms))
            #expect(RelaySearchQuery("switch br").matches(branchTerms))
        }
    }

    @Test("The Russian name finds the command while the interface is in English")
    func russianNameFindsEnglishCommand() {
        withLanguage(.english) {
            #expect(RelaySearchQuery("ветка").matches(branchTerms))
            #expect(RelaySearchQuery("переключить").matches(branchTerms))
        }
    }

    @Test("English typed on a Russian layout still finds the command")
    func wrongLayoutStillMatches() {
        withLanguage(.russian) {
            // What "branch" produces with the Russian layout active.
            #expect(RelaySearchQuery("икфтср").matches(branchTerms))
            // And "порты" with the Latin one.
            #expect(RelaySearchQuery("gjhns").matches(relaySearchTerms("Ports")))
        }
        withLanguage(.english) {
            #expect(RelaySearchQuery("dtnrf").matches(branchTerms))
        }
    }

    @Test("Russian written in Latin letters finds the Russian wording")
    func transliterationMatches() {
        withLanguage(.russian) {
            #expect(RelaySearchQuery("vetka").matches(branchTerms))
            #expect(RelaySearchQuery("nastroyki").matches(relaySearchTerms("Settings")))
        }
    }

    @Test("A Russian ending is not part of the name")
    func stemsMatchInflectedTitles() {
        // The palette says «Переключить ветку»; nobody types the accusative.
        #expect(RelaySearchQuery("ветка").matches(["Переключить ветку"]))
        #expect(RelaySearchQuery("настройки").matches(["Настройка проекта"]))
        // Giving up an ending is not licence to match anything: three letters
        // of stem have to survive.
        #expect(RelaySearchQuery("ветка").matches(["Порты"]) == false)
    }

    @Test("Letters in order but not together are a match")
    func subsequenceMatches() {
        #expect(RelaySearchQuery("swbr").matches(["Switch Branch"]))
        #expect(RelaySearchQuery("opfin").matches(["Open Project in Finder"]))
        #expect(RelaySearchQuery("zzz").matches(["Switch Branch"]) == false)
    }

    @Test("Case and «ё» are not something anyone searches by")
    func foldingIsForgiving() {
        #expect(RelaySearchQuery("BRANCH").matches(["Switch Branch"]))
        #expect(RelaySearchQuery("ждет").matches(["Ждёт вас"]))
    }

    @Test("An empty query matches everything, so the palette lists everything")
    func emptyQueryMatchesEverything() {
        let search = RelaySearchQuery("   ")
        #expect(search.isEmpty)
        #expect(search.matches(["anything at all"]))
    }

    @Test("What was typed literally outranks a guess at the layout")
    func literalMatchesOutrankTransformedOnes() {
        let search = RelaySearchQuery("branch")
        let literal = search.score(["Switch Branch"])
        let viaLayout = RelaySearchQuery("икфтср").score(["Switch Branch"])
        #expect(literal != nil)
        #expect(viaLayout != nil)
        #expect(literal! > viaLayout!)
    }

    @Test("The title outranks the subtitle it sits above")
    func titleOutranksSubtitle() {
        let search = RelaySearchQuery("main")
        let inTitle = search.score(["main", "Switch Branch"])
        let inSubtitle = search.score(["Switch Branch", "main"])
        #expect(inTitle != nil)
        #expect(inSubtitle != nil)
        #expect(inTitle! > inSubtitle!)
    }

    @Test("A match at the start of a word beats one buried in the middle")
    func wordStartsRankHigher() {
        let search = RelaySearchQuery("port")
        let atStart = search.score(["Ports"])
        let buried = search.score(["Transport layer"])
        #expect(atStart != nil)
        #expect(buried != nil)
        #expect(atStart! > buried!)
    }
}
