import Foundation
import RelayTracker

/// A person being named in a reply: the `@` just typed and what follows it.
///
/// Measured in UTF-16, the units a text view's selection is counted in, so the
/// range can be handed straight back to it to be replaced.
struct MentionQuery: Equatable {
    /// Of the whole `@partial`, the `@` included.
    var range: NSRange
    /// What has been typed after the `@`.
    var text: String

    /// The mention the caret is at the end of, if it is at one.
    ///
    /// An `@` counts only at the start of a word — `name@example.com` is an
    /// address, not somebody being called — and the word after it only while
    /// it could still be a login.
    static func find(in text: String, caret: Int) -> MentionQuery? {
        let source = text as NSString
        guard caret >= 0, caret <= source.length else { return nil }
        var start = caret
        while start > 0, let scalar = UnicodeScalar(source.character(at: start - 1)), isLoginCharacter(scalar) {
            start -= 1
        }
        guard start > 0, source.character(at: start - 1) == 0x40 else { return nil }
        let at = start - 1
        if at > 0, let before = UnicodeScalar(source.character(at: at - 1)), !opensAWord(before) {
            return nil
        }
        return MentionQuery(
            range: NSRange(location: at, length: caret - at),
            text: source.substring(with: NSRange(location: start, length: caret - start))
        )
    }

    /// Whoever the typed part could be, closest first: the login or a name
    /// starting with it before one merely containing it.
    static func matches(_ people: [TrackerUser], for typed: String, limit: Int = 6) -> [TrackerUser] {
        let wanted = typed.lowercased()
        guard !wanted.isEmpty else { return Array(people.prefix(limit)) }
        func rank(_ person: TrackerUser) -> Int? {
            let login = person.login.lowercased()
            let name = person.name.lowercased()
            if login.hasPrefix(wanted) { return 0 }
            if name.hasPrefix(wanted) || name.split(separator: " ").contains(where: { $0.hasPrefix(wanted) }) { return 1 }
            if login.contains(wanted) || name.contains(wanted) { return 2 }
            return nil
        }
        return people
            .compactMap { person in rank(person).map { (person, $0) } }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    /// What replaces the query: YouTrack's own way of naming somebody, and a
    /// space, so the next word is not taken for more of the login.
    static func insertion(for person: TrackerUser) -> String {
        "@\(person.login) "
    }

    private static func isLoginCharacter(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "." || scalar == "_" || scalar == "-"
    }

    private static func opensAWord(_ scalar: UnicodeScalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar) || "([{\"'«".unicodeScalars.contains(scalar)
    }
}
