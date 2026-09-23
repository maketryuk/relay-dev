import AppKit
import Foundation
import Testing

@testable import RelayAppKit

@Suite("Files dropped onto a terminal")
@MainActor
struct TerminalFileDropTests {
    private static let awkwardNames = [
        "/Users/me/My Project/notes (final).md",
        "/Users/me/it's \"quoted\".txt",
        "/tmp/$HOME & *.log",
        "/tmp/~tilde/#hash!;|<>`back`{}[]?^=\\slash",
        "/Users/me/Документы/отчёт.pdf",
    ]

    /// What a shell makes of `word`, read back out of it.
    private func shellReading(_ word: String, with shell: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        // To zsh `-f` means "read no startup files", so a `.zshenv` on the
        // machine cannot change the answer; to sh it means "no globbing",
        // which would hide half of what is being tested.
        let flags = shell.hasSuffix("zsh") ? ["-f"] : []
        process.arguments = flags + ["-c", "printf '%s' " + word]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @Test("A shell reads the escaped path back as the path", arguments: ["/bin/sh", "/bin/zsh"])
    func shellsReadThePathBack(shell: String) throws {
        // The spelling is only right if the thing on the other end agrees, so
        // it is asked rather than assumed.
        for name in Self.awkwardNames {
            #expect(try shellReading(TerminalFileDrop.escaped(name), with: shell) == name)
        }
    }

    @Test("A name beyond ASCII is left as it is written")
    func unicodeIsLeftAlone() {
        // A backslash before every letter would be what the agent has to read.
        #expect(TerminalFileDrop.escaped("/Users/me/Документы/отчёт.pdf") == "/Users/me/Документы/отчёт.pdf")
        #expect(TerminalFileDrop.escaped("/Users/me/My Project") == "/Users/me/My\\ Project")
    }

    @Test("Each path is its own paste when the program asked for pastes to be marked")
    func eachPathIsFramed() {
        let input = TerminalFileDrop.input(for: ["/tmp/a.png", "/tmp/b c.txt"], bracketedPaste: true)
        let expected = TerminalFileDrop.pasteStart + Array("/tmp/a.png ".utf8) + TerminalFileDrop.pasteEnd
            + TerminalFileDrop.pasteStart + Array("/tmp/b\\ c.txt ".utf8) + TerminalFileDrop.pasteEnd
        #expect(input == expected)
    }

    @Test("A program that never asked for marked pastes is not sent the markers")
    func unframedWithoutTheMode() {
        let input = TerminalFileDrop.input(for: ["/tmp/a.png", "/tmp/b c.txt"], bracketedPaste: false)
        #expect(input == Array("/tmp/a.png /tmp/b\\ c.txt ".utf8))
    }

    @Test("A name with a control character in it is left out, and the rest still go")
    func controlCharactersAreRefused() {
        // A newline would be Return to an agent, and an escape could close the
        // paste and have the rest of the name typed as keys.
        let input = TerminalFileDrop.input(
            for: ["/tmp/one\nrm -rf ~", "/tmp/\u{1B}[201~evil", "/tmp/kept"],
            bracketedPaste: false
        )
        #expect(input == Array("/tmp/kept ".utf8))
    }

    private func terminal() -> (view: RelayTerminalView, delegate: RecordingDelegate, window: NSWindow) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        let view = RelayTerminalView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let delegate = RecordingDelegate()
        view.terminalDelegate = delegate
        window.contentView?.addSubview(view)
        return (view, delegate, window)
    }

    @Test("The terminal marks the paste once the program has asked it to")
    func viewFollowsTheProgramsMode() {
        let terminal = terminal()
        terminal.view.insertDroppedPaths(["/tmp/a.png"])
        #expect(terminal.delegate.sent == Array("/tmp/a.png ".utf8))

        terminal.delegate.sent.removeAll()
        terminal.view.feed(text: "\u{1B}[?2004h")
        terminal.view.insertDroppedPaths(["/tmp/a.png"])
        #expect(terminal.delegate.sent == TerminalFileDrop.pasteStart + Array("/tmp/a.png ".utf8) + TerminalFileDrop.pasteEnd)
    }

    @Test("The pane the files landed in becomes the one being typed into")
    func dropTakesTheKeyboard() {
        let terminal = terminal()
        var reported = false
        terminal.view.onFilesDropped = { reported = true }

        terminal.view.insertDroppedPaths(["/tmp/a.txt"])

        #expect(terminal.window.firstResponder === terminal.view)
        #expect(reported)
    }

    @Test("A drop with nothing that can be spelled sends nothing and takes nothing")
    func emptyDropIsNotADrop() {
        let terminal = terminal()
        var reported = false
        terminal.view.onFilesDropped = { reported = true }

        terminal.view.insertDroppedPaths(["/tmp/one\ntwo"])

        #expect(terminal.delegate.sent.isEmpty)
        #expect(!reported)
    }
}
