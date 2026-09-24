import Foundation
import Testing

@testable import RelayProtocol

@Suite("A worktree's note, as it is written down")
struct WorktreeNoteCodingTests {
    private static let noon = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("The statuses are spelled the way the command line takes them")
    func rawValues() {
        // Typed by agents and stored in the workspace file: renaming one is a
        // break for both, however the Swift name reads.
        #expect(WorktreeWorkStatus.allCases.map(\.rawValue) == ["todo", "in-progress", "in-review", "completed"])
    }

    @Test("A note comes back as it went in")
    func roundTrip() throws {
        let note = WorktreeNote(status: .inReview, comment: "fix implemented; running tests", updatedAt: Self.noon)
        let decoded = try JSONDecoder().decode(WorktreeNote.self, from: JSONEncoder().encode(note))
        #expect(decoded == note)
    }

    @Test("What was not said is left out, and reads back as not said")
    func absentFieldsAreOmitted() throws {
        let note = WorktreeNote(comment: "blocked on the API", updatedAt: Self.noon)
        let json = try #require(String(data: JSONEncoder().encode(note), encoding: .utf8))
        #expect(!json.contains("status"))
        #expect(try JSONDecoder().decode(WorktreeNote.self, from: Data(json.utf8)) == note)
    }

    @Test("A status from a later build is dropped, and the comment beside it kept")
    func unknownStatusKeepsTheComment() throws {
        let json = #"{"status":"blocked","comment":"waiting on design","updatedAt":811692800}"#
        let note = try JSONDecoder().decode(WorktreeNote.self, from: Data(json.utf8))
        #expect(note.status == nil)
        #expect(note.comment == "waiting on design")
    }

    @Test("A note with neither a status nor a comment is empty")
    func emptiness() {
        #expect(WorktreeNote().isEmpty)
        #expect(WorktreeNote(comment: "").isEmpty)
        #expect(!WorktreeNote(status: .todo).isEmpty)
        #expect(!WorktreeNote(comment: "started").isEmpty)
    }
}
