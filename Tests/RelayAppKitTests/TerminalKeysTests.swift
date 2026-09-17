import AppKit
import SwiftTerm
import Testing

@testable import RelayAppKit

/// Catches what the view sends to the program on the other end.
@MainActor
private final class RecordingDelegate: NSObject, @preconcurrency TerminalViewDelegate {
    var sent: [UInt8] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func bell(source: TerminalView) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}

@Suite("Terminal keys")
@MainActor
struct TerminalKeysTests {
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
        window.makeFirstResponder(view)
        return (view, delegate, window)
    }

    private func keyPress(
        _ keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        characters: String = "\r",
        in window: NSWindow
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    @Test("Shift-Return asks for another line instead of sending the prompt")
    func shiftReturnSendsEscapeReturn() {
        let terminal = terminal()
        let handled = terminal.view.handleTranslatedKey(for: keyPress(36, modifiers: .shift, in: terminal.window))

        #expect(handled)
        #expect(terminal.delegate.sent == [0x1B, 0x0D])
    }

    @Test("Return on its own is still Return")
    func plainReturnIsLeftAlone() {
        // The whole value of the previous behaviour: submitting a prompt must
        // keep working, and must not arrive twice.
        let terminal = terminal()
        let handled = terminal.view.handleTranslatedKey(for: keyPress(36, modifiers: [], in: terminal.window))

        #expect(!handled)
        #expect(terminal.delegate.sent.isEmpty)
    }

    @Test("Command-Delete clears the line")
    func commandDeleteKillsTheLine() {
        // ⌘ never reaches the program, so without this the shortcut every other
        // field on macOS answers did nothing at all.
        let terminal = terminal()
        let handled = terminal.view.handleTranslatedKey(
            for: keyPress(51, modifiers: .command, characters: "\u{7F}", in: terminal.window)
        )

        #expect(handled)
        #expect(terminal.delegate.sent == [0x15])
    }

    @Test("Delete on its own is still a backspace")
    func plainDeleteIsLeftAlone() {
        let terminal = terminal()
        let handled = terminal.view.handleTranslatedKey(
            for: keyPress(51, modifiers: [], characters: "\u{7F}", in: terminal.window)
        )

        #expect(!handled)
        #expect(terminal.delegate.sent.isEmpty)
    }

    @Test("A terminal nobody is typing into sends nothing")
    func onlyTheFocusedTerminalAnswers() {
        // Every view in the window is offered a key equivalent, so a window with
        // two panes would otherwise send one keystroke twice.
        let terminal = terminal()
        terminal.window.makeFirstResponder(nil)
        let handled = terminal.view.handleTranslatedKey(for: keyPress(36, modifiers: .shift, in: terminal.window))

        #expect(!handled)
        #expect(terminal.delegate.sent.isEmpty)
    }

    @Test("A program reporting keys itself keeps Shift-Return")
    func kittyProtocolIsLeftAlone() {
        // With the Kitty keyboard protocol negotiated the program is told about
        // the Shift outright; inventing a second meaning delivers it twice.
        #expect(!TerminalKeyTranslation.sendsSoftNewline(
            keyCode: 36,
            modifiers: .shift,
            isReportingKeysItself: true
        ))
        // ⌘ is different: no protocol carries it, so the translation always
        // applies.
        #expect(TerminalKeyTranslation.bytes(
            keyCode: 51,
            modifiers: .command,
            isReportingKeysItself: true
        ) == [0x15])
    }

    @Test("Command-Delete with anything else held means nothing")
    func otherModifiersAreNotGuessedAt() {
        #expect(!TerminalKeyTranslation.killsLine(keyCode: 51, modifiers: [.command, .option]))
        #expect(!TerminalKeyTranslation.killsLine(keyCode: 51, modifiers: [.command, .shift]))
        #expect(!TerminalKeyTranslation.killsLine(keyCode: 51, modifiers: [.control]))
    }

    @Test("A terminal told to stay on the CPU stays on it")
    func honoursTheCPUPreference() {
        let terminal = terminal()
        terminal.view.prefersAcceleratedRendering = false
        #expect(!terminal.view.isUsingMetalRenderer)
    }
}
