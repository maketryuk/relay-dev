import Foundation
import Testing

@testable import RelayAppKit

@Suite("Todo records")
struct TodoRecordTests {
    @Test("A record is split into path, line and the rest of the text")
    func plainRecord() {
        let record = try! #require(TodoScanner.split(record: "Sources/App.swift:12:    // fix this"))
        #expect(record.path == "Sources/App.swift")
        #expect(record.line == 12)
        #expect(record.content == "    // fix this")
    }

    /// A colon is legal in a filename, and the first one is then not the
    /// separator. The line number is what tells them apart.
    @Test("A path containing a colon keeps it")
    func colonInPath() {
        let record = try! #require(TodoScanner.split(record: "docs/a:b.md:7:note"))
        #expect(record.path == "docs/a:b.md")
        #expect(record.line == 7)
    }

    @Test("A line with no number is not a record")
    func notARecord() {
        #expect(TodoScanner.split(record: "Binary file Sources/logo.png matches") == nil)
    }

    /// Text is allowed to contain colons of its own, and none of them are
    /// fields.
    @Test("Only the first two colons are separators")
    func colonsInText() {
        let record = try! #require(TodoScanner.split(record: "a.swift:3:url = \"https://x\""))
        #expect(record.content == "url = \"https://x\"")
    }
}

@Suite("Todo comments")
struct TodoCommentTests {
    private let markers = ["TODO", "FIXME", "HACK"]

    @Test("A marker in a comment is a note")
    func comment() {
        let note = try! #require(TodoScanner.note(in: "    // TODO: drop the shim", markers: markers))
        #expect(note.marker == "TODO")
        #expect(note.text == "drop the shim")
    }

    /// The search cannot read a language, so this is the judgement that keeps
    /// a list of remarks from filling with string constants.
    @Test("A marker outside a comment is not")
    func stringLiteral() {
        #expect(TodoScanner.note(in: "let label = \"TODO\"", markers: markers) == nil)
    }

    @Test("A marker is only a marker as a whole word")
    func wordBoundary() {
        #expect(TodoScanner.note(in: "// see AUTODOC for the rest", markers: markers) == nil)
    }

    @Test("A comment after code still counts")
    func trailingComment() {
        let note = try! #require(TodoScanner.note(in: "start() # FIXME racy", markers: markers))
        #expect(note.marker == "FIXME")
        #expect(note.text == "racy")
    }

    @Test("Whose note it is is dropped, and so is what closes the comment")
    func authorAndCloser() {
        let note = try! #require(TodoScanner.note(in: "/* TODO(nik): unwind this */", markers: markers))
        #expect(note.text == "unwind this")
    }

    @Test("A marker with nothing after it falls back to the line")
    func bareMarker() {
        let note = try! #require(TodoScanner.note(in: "   // HACK", markers: markers))
        #expect(note.text == "// HACK")
    }

    /// Two markers on one line is one note, and it is the one the comment
    /// opens with.
    @Test("The first marker on a line wins")
    func firstMarkerWins() {
        let note = try! #require(
            TodoScanner.note(in: "// FIXME: this HACK has to go", markers: markers)
        )
        #expect(note.marker == "FIXME")
    }

    /// Every project that has a panel like this has a comment explaining it,
    /// and that comment is not work to be done.
    @Test("A comment that merely mentions a marker is not a note")
    func prose() {
        #expect(
            TodoScanner.note(in: "/// The words the TODO panel looks for", markers: markers) == nil
        )
    }

    /// The case that put this project's own test data in its own panel: a
    /// string literal holding a quoted comment is a value, and the `//` inside
    /// it opens nothing.
    @Test("A comment quoted inside a string literal is not a note")
    func quotedComment() {
        let fixture = #"        "a.swift:90:// TODO: later","#
        #expect(TodoScanner.note(in: fixture, markers: markers) == nil)
    }

    /// The colon is enough to call a marker a note, so it must not be enough
    /// while the marker sits in quotes.
    @Test("Punctuation does not rescue a marker inside a string")
    func quotedMarkerWithColon() {
        let fixture = #"#require(TodoScanner.note(in: "// TODO: drop the shim"))"#
        #expect(TodoScanner.note(in: fixture, markers: markers) == nil)
    }

    /// The quotes closed before the comment began, so the comment is real.
    @Test("A comment after a string literal is still a comment")
    func commentAfterAString() {
        let note = try! #require(
            TodoScanner.note(in: #"print("hello") // TODO: drop this"#, markers: markers)
        )
        #expect(note.text == "drop this")
    }

    /// An apostrophe in prose is not an unterminated string literal, and must
    /// not swallow the rest of the line.
    @Test("An apostrophe inside a comment does not hide what follows")
    func apostropheInProse() {
        let note = try! #require(
            TodoScanner.note(in: "// it's here: TODO: unwind it", markers: markers)
        )
        #expect(note.marker == "TODO")
    }

    /// A raw string exists so that nothing inside it means anything, which is
    /// what a fixture holding a comment is counting on.
    @Test("A comment inside a raw string is not a note")
    func rawString() {
        let fixture = ##"let fixture = #"x:1:// TODO: later"#"##
        #expect(TodoScanner.note(in: fixture, markers: markers) == nil)
    }

    @Test("A raw string that never closes does not swallow a real note")
    func unterminatedRawString() {
        let note = try! #require(TodoScanner.note(in: ##"y = #"a  // TODO: fix it"##, markers: markers))
        #expect(note.marker == "TODO")
    }

    @Test("A marker not asked for is not found")
    func unknownMarker() {
        #expect(TodoScanner.note(in: "// XXX: nope", markers: markers) == nil)
    }
}

@Suite("Todo scan")
struct TodoScanTests {
    private let markers = ["TODO", "FIXME"]

    private func output(_ records: [String]) -> String {
        records.joined(separator: "\n") + "\n"
    }

    @Test("Notes are ordered by file and then by line")
    func ordering() {
        let scan = TodoScanner.parse(output([
            "b.swift:4:// TODO: second file",
            "a.swift:90:// TODO: later",
            "a.swift:9:// TODO: earlier",
        ]), markers: markers)
        #expect(scan.items.map(\.path) == ["a.swift", "a.swift", "b.swift"])
        #expect(scan.items.map(\.line) == [9, 90, 4])
    }

    /// `grep` outside a repository is given an absolute root and answers with
    /// absolute paths; an agent is told where a file is relative to the project.
    @Test("An absolute path is reported relative to the root")
    func relativePaths() {
        let scan = TodoScanner.parse(
            output(["/Users/x/proj/Sources/App.swift:3:// TODO: move"]),
            markers: markers,
            strippingPrefix: "/Users/x/proj"
        )
        #expect(scan.items.first?.path == "Sources/App.swift")
    }

    @Test("Lines that only look like notes are dropped")
    func filtered() {
        let scan = TodoScanner.parse(output([
            "a.swift:1:let key = \"TODO\"",
            "a.swift:2:// TODO: real one",
        ]), markers: markers)
        #expect(scan.items.count == 1)
        #expect(scan.items.first?.line == 2)
    }

    @Test("A list longer than the cap says so")
    func truncation() {
        let records = (1 ... TodoScanner.limit + 10).map { "a.swift:\($0):// TODO: \($0)" }
        let scan = TodoScanner.parse(output(records), markers: markers)
        #expect(scan.items.count == TodoScanner.limit)
        #expect(scan.isTruncated)
    }

    @Test("A list within the cap does not")
    func notTruncated() {
        let scan = TodoScanner.parse(output(["a.swift:1:// TODO: one"]), markers: markers)
        #expect(!scan.isTruncated)
    }

    @Test("Counts are per marker, and silent about the ones that found nothing")
    func counts() {
        let scan = TodoScanner.parse(output([
            "a.swift:1:// TODO: one",
            "a.swift:2:// TODO: two",
            "a.swift:3:// FIXME: three",
        ]), markers: markers)
        let counts = scan.counts(for: ["TODO", "FIXME", "HACK"])
        #expect(counts.map(\.marker) == ["TODO", "FIXME"])
        #expect(counts.map(\.count) == [2, 1])
    }
}

@Suite("Todo markers")
struct TodoMarkerTests {
    @Test("Markers are upper-cased and deduplicated")
    func normalised() {
        #expect(TodoScanner.normalise([" todo ", "TODO", "FixMe"]) == ["TODO", "FIXME"])
    }

    /// The markers reach a regular expression, so anything that is not a word
    /// is a pattern the user did not mean to write.
    @Test("A marker that is not a word is refused")
    func refusesPatterns() {
        #expect(TodoScanner.normalise([".*", "TODO|.*", "", "TODO"]) == ["TODO"])
    }

    /// The rule the settings field and the panel's own list both store through,
    /// so neither can mean something the other does not.
    @Test("Choosing nothing stores the usual words rather than none")
    func emptyFallsBack() {
        #expect(TodoScanner.markers(from: []) == TodoScanner.defaultMarkers)
        #expect(TodoScanner.markers(from: ["  ", "!"]) == TodoScanner.defaultMarkers)
    }

    @Test("A chosen set is stored as it will be searched for")
    func storedAsSearched() {
        #expect(TodoScanner.markers(from: ["fixme", " todo "]) == ["FIXME", "TODO"])
    }
}

@Suite("Todo transcript")
struct TodoTranscriptTests {
    private let todo = TodoItem(
        path: "Sources/App.swift",
        line: 12,
        marker: "TODO",
        text: "drop the shim"
    )

    @Test("A note carries its file, its line and what it says")
    func block() {
        #expect(TodoTranscript.compose([todo], instruction: "") == """
        File: Sources/App.swift
        Line: 12
        TODO: drop the shim
        """)
    }

    /// Once, at the end: it is what the notes are being handed over for, not
    /// something said about each of them.
    @Test("The instruction is written once")
    func instruction() {
        let other = TodoItem(path: "Sources/App.swift", line: 40, marker: "FIXME", text: "racy")
        let transcript = TodoTranscript.compose([todo, other], instruction: "do both")
        #expect(transcript.components(separatedBy: "What to do:").count == 2)
        #expect(transcript.hasSuffix("What to do: do both"))
    }

    @Test("Notes are ordered the way the list shows them")
    func ordering() {
        let earlier = TodoItem(path: "Sources/App.swift", line: 3, marker: "TODO", text: "first")
        let transcript = TodoTranscript.compose([todo, earlier], instruction: "")
        #expect(transcript.hasPrefix("File: Sources/App.swift\nLine: 3"))
    }
}
