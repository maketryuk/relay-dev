import Foundation

/// What a file dragged onto a terminal becomes on the other end: its full path.
///
/// The terminal cannot know whether a shell or an agent is reading, so the
/// spelling has to be one both take for a path. That is the one Terminal.app
/// and iTerm2 use — a backslash before anything a shell reads as syntax, and a
/// space after, so the next word does not run into it — and the one Claude
/// Code and Codex are written against: both undo the backslashes, and attach
/// the file as an image when it is one.
///
/// Pure, and away from the view, for the same reason `TerminalKeyTranslation`
/// is: the spelling is a decision, and the view cannot be made without a
/// window.
enum TerminalFileDrop {
    static let pasteStart: [UInt8] = Array("\u{1B}[200~".utf8)
    static let pasteEnd: [UInt8] = Array("\u{1B}[201~".utf8)

    /// Printable ASCII that no shell reads as syntax. The rest of ASCII is
    /// escaped and everything past it is not: a Cyrillic name is syntax to
    /// nobody, and a backslash before each of its letters is what the agent
    /// would then have to read.
    private static let literal = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._-+,:@%".unicodeScalars)

    /// The bytes to send for `paths`, each one pasted on its own.
    ///
    /// One paste per path because Codex attaches an image only when a paste is
    /// that one path and nothing else, while Claude Code splits a paste of
    /// several into one each — so separate pastes cost one agent nothing and
    /// are what the other needs.
    ///
    /// Framed only for a program that has asked for pastes to be marked:
    /// without the markers an agent sees the path typed out, and a typed path
    /// is text rather than an attachment; with them, a program that never
    /// asked would print them.
    static func input(for paths: [String], bracketedPaste: Bool) -> [UInt8] {
        paths.filter(isSpellable).flatMap { path -> [UInt8] in
            let text = Array((escaped(path) + " ").utf8)
            return bracketedPaste ? pasteStart + text + pasteEnd : text
        }
    }

    /// Whether a path can be sent at all.
    ///
    /// Not one with a control character in it. No spelling of a newline is
    /// read as part of a name by everything on the other end — a shell takes
    /// a backslash before one as a continued line, an agent takes it as
    /// Return — and an escape can close a marked paste early and have the rest
    /// of the name typed as keys.
    static func isSpellable(_ path: String) -> Bool {
        !path.isEmpty && !path.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    static func escaped(_ path: String) -> String {
        var result = ""
        for scalar in path.unicodeScalars {
            if scalar.isASCII, !literal.contains(scalar) {
                result.unicodeScalars.append("\\")
            }
            result.unicodeScalars.append(scalar)
        }
        return result
    }
}
