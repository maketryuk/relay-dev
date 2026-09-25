import Foundation
import Testing

@testable import RelayAppKit

@Suite("Transcripts read once until written to")
final class TranscriptReadingsTests {
    private let folder: URL

    init() throws {
        folder = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-transcripts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    private func write(_ lines: [String], to name: String) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func append(_ line: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    @Test("A transcript nobody has written to since is not read again")
    func unchangedIsNotReadAgain() throws {
        let url = try write(["{}"], to: "a.jsonl")
        let readings = TranscriptReadings<Int>()
        var reads = 0
        let read: (URL) -> Int? = { _ in
            reads += 1
            return reads
        }

        #expect(readings.value(of: url, reading: read) == 1)
        #expect(readings.value(of: URL(fileURLWithPath: url.path), reading: read) == 1)
        #expect(reads == 1)
    }

    @Test("A transcript written to since is read again")
    func changedIsReadAgain() throws {
        let url = try write(["{}"], to: "a.jsonl")
        let readings = TranscriptReadings<String>()
        let read: (URL) -> String? = { try? String(contentsOf: $0, encoding: .utf8) }

        #expect(readings.value(of: url, reading: read) == "{}\n")
        try append("{\"b\":1}", to: url)
        // The same `URL` value, which remembers what it was last told about
        // the file unless it is made to ask again.
        #expect(readings.value(of: url, reading: read) == "{}\n{\"b\":1}\n")
    }

    @Test("Only the transcripts of the latest listing are kept")
    func keepsOneListing() throws {
        let first = try write(["{}"], to: "a.jsonl")
        let second = try write(["{}"], to: "b.jsonl")
        let readings = TranscriptReadings<Int>()
        _ = readings.value(of: first) { _ in 1 }
        _ = readings.value(of: second) { _ in 2 }

        readings.keep(only: [second])
        #expect(readings.count == 1)
        #expect(readings.value(of: second) { _ in 3 } == 2)
    }

    @Test("The History list shows what a transcript says now, not what it said when first listed")
    func listingFollowsTheTranscript() throws {
        let projects = folder.appendingPathComponent("projects", isDirectory: true)
        let project = projects.appendingPathComponent("-Users-me-shop", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("0b1d4c66.jsonl")
        try "{\"type\":\"ai-title\",\"aiTitle\":\"Fix the login\"}\n".write(to: transcript, atomically: true, encoding: .utf8)

        let readings = TranscriptReadings<Conversation>()
        let first = ClaudeConversationReader.list(forDirectory: "/Users/me/shop", projects: projects, readings: readings)
        #expect(first.map(\.title) == ["Fix the login"])
        #expect(ClaudeConversationReader.list(forDirectory: "/Users/me/shop", projects: projects, readings: readings)
            .map(\.title) == ["Fix the login"])

        try append("{\"type\":\"ai-title\",\"aiTitle\":\"Fix the login and the signup\"}", to: transcript)
        let later = ClaudeConversationReader.list(forDirectory: "/Users/me/shop", projects: projects, readings: readings)
        #expect(later.map(\.title) == ["Fix the login and the signup"])
    }
}
