import Foundation

/// A shell command that opens a file in whatever editor the user edits with.
///
/// The editor is resolved by the shell rather than by Relay: `$EDITOR` is
/// exported by a profile the app never reads, which is the same reason every
/// session is started through a login shell in the first place.
enum TerminalEditorCommand {
    /// Editors that read `+N` as "start at line N".
    ///
    /// The convention is `vi`'s, and nano and emacs took it; anything else
    /// would be handed `+12` as a second file to open, so the line is only
    /// offered to the editors known to want it.
    private static let understandsLineArgument = ["vi", "vim", "nvim", "view", "nano", "emacs"]

    private static let editor = "\"${VISUAL:-${EDITOR:-vi}}\""

    static func opening(_ path: String, atLine line: Int? = nil) -> String {
        let file = singleQuoted(path)
        guard let line, line > 0 else { return "exec \(editor) \(file)" }

        let known = understandsLineArgument.joined(separator: "|")
        return "editor=\(editor); case \"${editor##*/}\" in "
            + "\(known)) exec \"$editor\" \"+\(line)\" \(file) ;; "
            + "*) exec \"$editor\" \(file) ;; "
            + "esac"
    }

    private static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
