import Foundation
import Testing

@testable import RelayAppKit

@Suite("Opening a file in the terminal editor")
struct TerminalEditorCommandTests {
    @Test("Without a line, the editor is simply handed the file")
    func opensAFile() {
        #expect(
            TerminalEditorCommand.opening("/Users/me/.ssh/config")
                == "exec \"${VISUAL:-${EDITOR:-vi}}\" '/Users/me/.ssh/config'"
        )
    }

    @Test("The line is offered only to the editors that read it")
    func offersTheLineWhereItIsUnderstood() {
        let command = TerminalEditorCommand.opening("/Users/me/.ssh/config", atLine: 12)
        // `+12` is vi's convention; an editor that does not know it would treat
        // the argument as a second file to open, called `+12`.
        #expect(command.contains("vi|vim|nvim|view|nano|emacs) exec \"$editor\" \"+12\""))
        #expect(command.contains("*) exec \"$editor\" '/Users/me/.ssh/config' ;;"))
        #expect(command.hasPrefix("editor=\"${VISUAL:-${EDITOR:-vi}}\";"))
    }

    @Test("A line nobody could go to is not asked for")
    func ignoresAnImpossibleLine() {
        // Line numbers are one-based, so a zero is a caller that counted wrong
        // rather than a request to open the top of the file.
        #expect(TerminalEditorCommand.opening("/tmp/config", atLine: 0) == TerminalEditorCommand.opening("/tmp/config"))
    }

    @Test("A path the shell would misread is quoted")
    func quotesThePath() {
        #expect(
            TerminalEditorCommand.opening("/Users/me/it's here/config")
                == "exec \"${VISUAL:-${EDITOR:-vi}}\" '/Users/me/it'\\''s here/config'"
        )
    }

    @Test("The command runs one line, so no amount of quoting can split it")
    func staysOnOneLine() {
        // It reaches the shell through two levels of quoting: the login shell
        // Relay starts, then `sh -c`.
        #expect(!TerminalEditorCommand.opening("/tmp/config", atLine: 3).contains("\n"))
    }
}
