import Foundation
import Testing

@testable import RelayDaemonCore

@Suite("Terminal title parsing")
struct TerminalTitleParserTests {
    private func title(_ raw: String) -> String? {
        var parser = TerminalTitleParser()
        return parser.consume(Data(raw.utf8))
    }

    @Test("OSC 0 terminated by BEL sets a title")
    func osc0WithBell() {
        #expect(title("\u{1B}]0;fix the failing tests\u{07}") == "fix the failing tests")
    }

    @Test("OSC 2 terminated by ST sets a title")
    func osc2WithStringTerminator() {
        #expect(title("\u{1B}]2;~/projects/relay\u{1B}\\") == "~/projects/relay")
    }

    @Test("OSC 1 sets an icon title, which is still a name")
    func osc1() {
        #expect(title("\u{1B}]1;relay\u{07}") == "relay")
    }

    @Test("Other OSC codes are ignored")
    func ignoresOtherCodes() {
        // OSC 8 is a hyperlink, OSC 7 the working directory; neither is a title.
        #expect(title("\u{1B}]8;;https://example.com\u{07}") == nil)
        #expect(title("\u{1B}]7;file://host/tmp\u{07}") == nil)
    }

    @Test("The last title in a chunk wins")
    func lastTitleWins() {
        #expect(title("\u{1B}]0;first\u{07}output\u{1B}]0;second\u{07}") == "second")
    }

    @Test("A title split across reads is still assembled")
    func titleSpanningChunks() {
        // A PTY splits wherever it likes; a title straddling two reads is normal.
        var parser = TerminalTitleParser()
        #expect(parser.consume(Data("\u{1B}]0;build".utf8)) == nil)
        #expect(parser.consume(Data("ing the app\u{07}".utf8)) == "building the app")
    }

    @Test("An escape split from its bracket is handled")
    func escapeSplitFromBracket() {
        var parser = TerminalTitleParser()
        #expect(parser.consume(Data([0x1B])) == nil)
        #expect(parser.consume(Data("]0;late\u{07}".utf8)) == "late")
    }

    @Test("Ordinary output produces no title")
    func plainOutput() {
        #expect(title("just some terminal output\n") == nil)
        #expect(title("") == nil)
    }

    @Test("Colour sequences are not mistaken for titles")
    func ignoresCSI() {
        #expect(title("\u{1B}[31mred\u{1B}[0m") == nil)
    }

    @Test("An empty title is rejected rather than blanking the session name")
    func rejectsEmptyTitle() {
        #expect(title("\u{1B}]0;\u{07}") == nil)
        #expect(title("\u{1B}]0;   \u{07}") == nil)
    }

    @Test("Control characters inside a title are stripped")
    func stripsControlCharacters() {
        #expect(title("\u{1B}]0;clean\u{01}title\u{07}") == "cleantitle")
    }

    @Test("Unicode titles survive")
    func unicodeTitle() {
        #expect(title("\u{1B}]0;✳ Claude — рефакторинг\u{07}") == "✳ Claude — рефакторинг")
    }

    @Test("An over-long title is truncated instead of filling the sidebar")
    func truncatesLongTitles() {
        let long = String(repeating: "x", count: 400)
        let result = title("\u{1B}]0;\(long)\u{07}")
        #expect(result != nil)
        #expect((result?.count ?? 0) <= 97)
        #expect(result?.hasSuffix("…") == true)
    }

    @Test("An unterminated sequence cannot grow without bound")
    func boundedBuffer() {
        var parser = TerminalTitleParser()
        // A program that opens an OSC and never closes it must not leak memory.
        #expect(parser.consume(Data(("\u{1B}]0;" + String(repeating: "y", count: 5000)).utf8)) == nil)
        // The parser recovers for the next well-formed sequence.
        #expect(parser.consume(Data("\u{1B}]0;recovered\u{07}".utf8)) == "recovered")
    }
}
