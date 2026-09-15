import Foundation
import Testing

@testable import RelayDaemonCore

@Suite("Terminal text extraction")
struct TerminalTextTests {
    private func plain(_ raw: String) -> String {
        TerminalText.plainText(from: Data(raw.utf8))
    }

    @Test("CSI colour sequences are removed")
    func stripsColours() {
        #expect(plain("\u{1B}[31mred\u{1B}[0m text") == "red text")
    }

    @Test("CSI cursor movement is removed")
    func stripsCursorMovement() {
        #expect(plain("a\u{1B}[2Ab\u{1B}[1;32Hc") == "abc")
    }

    @Test("OSC sequences terminated by BEL or ST are removed")
    func stripsOSC() {
        #expect(plain("\u{1B}]0;window title\u{07}visible") == "visible")
        #expect(plain("\u{1B}]8;;https://example.com\u{1B}\\link") == "link")
    }

    @Test("Charset selection escapes are removed")
    func stripsCharsetSelection() {
        #expect(plain("\u{1B}(Bplain") == "plain")
    }

    @Test("Carriage-return overdraw keeps only the final paint")
    func collapsesSpinnerRepaints() {
        // A spinner rewrites one line repeatedly; only the last state is real.
        #expect(plain("Thinking |\rThinking /\rThinking -\rDone") == "Done")
    }

    @Test("Overdraw is collapsed per line, not across the whole stream")
    func collapsePerLine() {
        #expect(plain("first\rFIRST\nsecond\rSECOND") == "FIRST\nSECOND")
    }

    @Test("Plain text passes through untouched")
    func passthrough() {
        #expect(plain("nothing to strip") == "nothing to strip")
    }

    @Test("Unicode survives stripping")
    func unicode() {
        #expect(plain("\u{1B}[32m✔ готово 日本語\u{1B}[0m") == "✔ готово 日本語")
    }

    @Test("Escape processing must see whole lines, not per-chunk fragments")
    func collapsingIsNotChunkSafe() {
        // A PTY splits output at arbitrary byte boundaries. Processing each
        // chunk separately loses overdraw that spans a split, so classification
        // would depend on packet timing. Sessions therefore accumulate raw bytes
        // and convert once, and this test pins the reason why.
        let whole = plain("Thinking...\rDone")
        #expect(whole == "Done")

        let piecewise = plain("Thinking...") + plain("\rDone")
        #expect(piecewise == "Thinking...Done")
        #expect(piecewise != whole)
    }

    @Test("The tail is bounded to the requested length")
    func tailIsBounded() {
        let long = String(repeating: "x", count: 5000)
        #expect(TerminalText.tail(of: long, limit: 100).count == 100)
        #expect(TerminalText.tail(of: "short", limit: 100) == "short")
    }

    @Test("The last meaningful line skips trailing blank lines")
    func lastMeaningfulLine() {
        #expect(TerminalText.lastMeaningfulLine(of: "a\nb\n   \n\n") == "b")
        #expect(TerminalText.lastMeaningfulLine(of: "  prompt $  ") == "prompt $")
        #expect(TerminalText.lastMeaningfulLine(of: "") == "")
    }
}
