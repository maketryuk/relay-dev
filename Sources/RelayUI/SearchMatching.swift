import Foundation

/// How a typed query becomes a match.
///
/// `contains(query)` is wrong in an app that ships in two languages on a Mac
/// that has two keyboard layouts, and it is wrong in three different ways at
/// once:
///
/// - the interface is in Russian and the word the person knows is the English
///   one, so "branch" has to find «Переключить ветку»;
/// - the layout is Russian and the word typed is English, so "branch" arrives
///   as "икфтср" and nothing at all is found;
/// - the layout is Latin and the word is Russian, typed the way it sounds, so
///   "vetka" has to find «ветка».
///
/// Each of those is a mechanical transformation of what was typed, never of
/// what is being searched. So the query is expanded into every reading of it,
/// each reading is scored against every candidate, and the best score wins —
/// with a penalty on the transformed readings, so that what someone typed
/// exactly still beats what they might have meant.
public struct RelaySearchQuery: Sendable {
    private struct Reading: Sendable {
        let characters: [Character]
        /// Subtracted from the score, so a literal match ranks above a guess
        /// at which keyboard the query was typed on.
        let penalty: Int
    }

    private let readings: [Reading]

    public let isEmpty: Bool

    public init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        isEmpty = trimmed.isEmpty

        var readings: [Reading] = []
        var seen: Set<String> = []
        for (candidate, penalty) in RelaySearchQuery.spellings(of: trimmed) {
            let folded = RelaySearchQuery.fold(candidate)
            guard !folded.isEmpty, seen.insert(String(folded)).inserted else { continue }
            readings.append(Reading(characters: folded, penalty: penalty))
        }
        self.readings = readings
    }

    /// The best score across every reading of the query and every candidate,
    /// or nil when nothing matches.
    ///
    /// - Parameter candidates: in descending order of importance. A title is
    ///   worth more than the subtitle underneath it, so later ones are docked.
    public func score(_ candidates: [String]) -> Int? {
        guard !readings.isEmpty else { return nil }

        var best: Int?
        for (rank, candidate) in candidates.enumerated() {
            let folded = RelaySearchQuery.fold(candidate)
            guard !folded.isEmpty else { continue }
            for reading in readings {
                guard let score = RelaySearchQuery.score(reading.characters, in: folded) else { continue }
                let adjusted = score - reading.penalty - rank * Self.candidateRankPenalty
                if best == nil || adjusted > best! { best = adjusted }
            }
        }
        return best
    }

    public func matches(_ candidates: [String]) -> Bool {
        isEmpty || score(candidates) != nil
    }

    private static let candidateRankPenalty = 6

    // MARK: - Readings of the query

    /// Every way the typed characters could have been meant, cheapest first.
    private static func spellings(of query: String) -> [(String, Int)] {
        let lowered = query.lowercased()
        return [
            (lowered, 0),
            (mapped(lowered, through: cyrillicToLatinKeys), 40),
            (mapped(lowered, through: latinToCyrillicKeys), 40),
            (transliterated(lowered, using: latinToCyrillicSounds), 70),
            (transliterated(lowered, using: latinToCyrillicSoundsWithShortI), 70),
            (transliterated(lowered, using: cyrillicToLatinSounds), 70),
        ]
    }

    /// The same physical keys read on the other layout. Letters only: the
    /// punctuation shared by both layouts maps ambiguously, and a query is far
    /// more likely to contain a real full stop than a mistyped «ю».
    private static func mapped(_ text: String, through table: [Character: Character]) -> String {
        String(text.map { table[$0] ?? $0 })
    }

    /// The same sounds written in the other alphabet. Greedy and longest-first,
    /// because "shch" is one letter and "s" is another.
    private static func transliterated(_ text: String, using table: [(String, String)]) -> String {
        var result = ""
        var index = text.startIndex
        outer: while index < text.endIndex {
            for (source, replacement) in table where text[index...].hasPrefix(source) {
                result += replacement
                index = text.index(index, offsetBy: source.count)
                continue outer
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    // MARK: - Scoring

    /// Case and accents are not something anyone searches by, and folding «ё»
    /// onto «е» — which is what diacritic folding does to Cyrillic — is the
    /// behaviour every Russian search box already has.
    private static func fold(_ text: String) -> [Character] {
        Array(text.lowercased().folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil))
    }

    /// Russian inflects, so the word someone searches for and the word in the
    /// title are usually different words: «ветка» is typed, «ветку» is on
    /// screen. What they share is the stem, so when the whole query fails the
    /// ending is given up a letter at a time — at a price, so that a title
    /// containing the query whole always wins.
    private static func score(_ needle: [Character], in haystack: [Character]) -> Int? {
        if let score = literalScore(needle, in: haystack) { return score }

        var stem = needle
        for dropped in 1 ... maximumEnding where stem.count > minimumStem {
            stem.removeLast()
            if let score = literalScore(stem, in: haystack) { return score - dropped * endingPenalty }
        }
        return nil
    }

    private static let minimumStem = 3
    private static let maximumEnding = 3
    private static let endingPenalty = 45

    private static func literalScore(_ needle: [Character], in haystack: [Character]) -> Int? {
        guard !needle.isEmpty, needle.count <= haystack.count else { return nil }

        if let start = firstRange(of: needle, in: haystack) {
            var score = contiguousScore - start * 4
            if start == 0 { score += 200 }
            else if isBoundary(haystack[start - 1]) { score += 120 }
            if needle.count == haystack.count { score += 200 }
            return score
        }

        return subsequenceScore(needle, in: haystack)
    }

    private static let contiguousScore = 800

    private static func firstRange(of needle: [Character], in haystack: [Character]) -> Int? {
        let last = haystack.count - needle.count
        guard last >= 0 else { return nil }
        for start in 0...last {
            var offset = 0
            while offset < needle.count, haystack[start + offset] == needle[offset] { offset += 1 }
            if offset == needle.count { return start }
        }
        return nil
    }

    /// The letters in order but not together — "swbr" for "Switch Branch".
    /// Scored by how well the run of matches lines up with the words it lands
    /// in, so a match on the initials of a title outranks one on its middles.
    private static func subsequenceScore(_ needle: [Character], in haystack: [Character]) -> Int? {
        var score = 0
        var next = 0
        var previous = -1

        for (index, character) in haystack.enumerated() {
            guard next < needle.count else { break }
            guard character == needle[next] else { continue }

            score += 4
            if previous == index - 1 { score += 12 }
            if index == 0 { score += 24 }
            else if isBoundary(haystack[index - 1]) { score += 18 }
            previous = index
            next += 1
        }

        guard next == needle.count else { return nil }
        // A short title that contains the query says more than a long one.
        return score - min(haystack.count - needle.count, 40)
    }

    private static func isBoundary(_ character: Character) -> Bool {
        !character.isLetter && !character.isNumber
    }

    // MARK: - Tables

    private static let latinToCyrillicKeys: [Character: Character] = [
        "q": "й", "w": "ц", "e": "у", "r": "к", "t": "е", "y": "н",
        "u": "г", "i": "ш", "o": "щ", "p": "з",
        "a": "ф", "s": "ы", "d": "в", "f": "а", "g": "п", "h": "р",
        "j": "о", "k": "л", "l": "д",
        "z": "я", "x": "ч", "c": "с", "v": "м", "b": "и", "n": "т", "m": "ь",
    ]

    private static let cyrillicToLatinKeys: [Character: Character] = {
        var table: [Character: Character] = [:]
        for (latin, cyrillic) in latinToCyrillicKeys { table[cyrillic] = latin }
        return table
    }()

    private static let latinToCyrillicSounds: [(String, String)] = [
        ("shch", "щ"), ("sch", "щ"),
        ("zh", "ж"), ("kh", "х"), ("ts", "ц"), ("ch", "ч"), ("sh", "ш"),
        ("yo", "ё"), ("yu", "ю"), ("ya", "я"), ("ye", "е"), ("eh", "э"),
        ("jo", "ё"), ("ju", "ю"), ("ja", "я"),
        ("a", "а"), ("b", "б"), ("v", "в"), ("g", "г"), ("d", "д"),
        ("e", "е"), ("z", "з"), ("i", "и"), ("j", "й"), ("k", "к"),
        ("l", "л"), ("m", "м"), ("n", "н"), ("o", "о"), ("p", "п"),
        ("r", "р"), ("s", "с"), ("t", "т"), ("u", "у"), ("f", "ф"),
        ("h", "х"), ("c", "ц"), ("y", "ы"), ("w", "в"), ("q", "к"),
        ("x", "кс"),
    ]

    /// The same table read with "y" as «й» rather than «ы», which is the other
    /// half of the one letter Latin spellings of Russian never agree on:
    /// "nastroyki" and "vy" want opposite answers.
    private static let latinToCyrillicSoundsWithShortI: [(String, String)] = latinToCyrillicSounds.map { source, replacement in
        replacement == "ы" ? (source, "й") : (source, replacement)
    }

    private static let cyrillicToLatinSounds: [(String, String)] = [
        ("а", "a"), ("б", "b"), ("в", "v"), ("г", "g"), ("д", "d"),
        ("е", "e"), ("ё", "yo"), ("ж", "zh"), ("з", "z"), ("и", "i"),
        ("й", "y"), ("к", "k"), ("л", "l"), ("м", "m"), ("н", "n"),
        ("о", "o"), ("п", "p"), ("р", "r"), ("с", "s"), ("т", "t"),
        ("у", "u"), ("ф", "f"), ("х", "kh"), ("ц", "ts"), ("ч", "ch"),
        ("ш", "sh"), ("щ", "shch"), ("ъ", ""), ("ы", "y"), ("ь", ""),
        ("э", "e"), ("ю", "yu"), ("я", "ya"),
    ]
}
