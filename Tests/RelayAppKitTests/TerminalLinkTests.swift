import Foundation
import SwiftTerm
import Testing

@testable import RelayAppKit

/// A terminal with nobody on the other end, for reading what it holds.
private final class Unattended: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

@Suite("Links clicked in a terminal")
@MainActor
struct TerminalLinkTests {
    /// Real files in a real directory: what is being decided is what the disk
    /// has, which a fake file system would answer for itself.
    private func temporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    private func file(_ relative: String, in directory: URL) throws -> String {
        let url = directory.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "one\ntwo\n".write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test("An absolute path is the file")
    func absolutePath() throws {
        let path = try file("notes.md", in: try temporaryDirectory())
        #expect(TerminalLink.destination(of: path, from: []) == .file(path: path, line: nil, column: nil))
    }

    @Test("A relative path is read from the first directory that has it")
    func relativePath() throws {
        let shell = try temporaryDirectory()
        let project = try temporaryDirectory()
        let path = try file("Sources/App.swift", in: project)

        let found = TerminalLink.destination(of: "Sources/App.swift", from: [shell.path, project.path])
        #expect(found == .file(path: path, line: nil, column: nil))
    }

    @Test("A path that climbs out of the directory is followed out of it")
    func climbingPath() throws {
        let root = try temporaryDirectory()
        let path = try file("docs/notes.md", in: root)
        let found = TerminalLink.destination(of: "../docs/notes.md", from: [root.appendingPathComponent("Sources").path])
        #expect(found == .file(path: path, line: nil, column: nil))
    }

    @Test("A line and a column after the path say where in the file")
    func lineAndColumn() throws {
        let directory = try temporaryDirectory()
        let path = try file("App.swift", in: directory)

        #expect(TerminalLink.destination(of: "App.swift:12", from: [directory.path])
            == .file(path: path, line: 12, column: nil))
        #expect(TerminalLink.destination(of: "\(path):12:4", from: [])
            == .file(path: path, line: 12, column: 4))
    }

    @Test("A file named with a line is not taken for one with a line after it")
    func colonInTheName() throws {
        let directory = try temporaryDirectory()
        let path = try file("backup:12", in: directory)
        #expect(TerminalLink.destination(of: "backup:12", from: [directory.path])
            == .file(path: path, line: nil, column: nil))
    }

    @Test("A path with a line is not taken for an address")
    func lineIsNotAScheme() throws {
        // `URL(string:)` reads this as the scheme `readme.md`, and that is
        // what the link used to be handed to macOS as.
        let directory = try temporaryDirectory()
        let path = try file("README.md", in: directory)
        #expect(TerminalLink.destination(of: "README.md:3", from: [directory.path])
            == .file(path: path, line: 3, column: nil))
    }

    @Test("The full stop of the sentence a path ended is not part of it")
    func sentencePunctuation() throws {
        let directory = try temporaryDirectory()
        let path = try file("notes.md", in: directory)
        #expect(TerminalLink.destination(of: "notes.md.", from: [directory.path])
            == .file(path: path, line: nil, column: nil))
        #expect(TerminalLink.destination(of: "notes.md:3.", from: [directory.path])
            == .file(path: path, line: 3, column: nil))
    }

    @Test("A folder is a folder")
    func folder() throws {
        let directory = try temporaryDirectory()
        try file("Sources/App.swift", in: directory)
        #expect(TerminalLink.destination(of: "Sources/", from: [directory.path])
            == .folder(directory.appendingPathComponent("Sources").path))
    }

    @Test("A file URL is the file it names")
    func fileURL() throws {
        let path = try file("with space.md", in: try temporaryDirectory())
        let link = URL(fileURLWithPath: path).absoluteString
        #expect(link.contains("%20"))
        #expect(TerminalLink.destination(of: link, from: []) == .file(path: path, line: nil, column: nil))
    }

    @Test("An address is left to whatever opens it")
    func address() throws {
        let directory = try temporaryDirectory()
        let url = try #require(URL(string: "https://example.com/docs"))
        #expect(TerminalLink.destination(of: url.absoluteString, from: [directory.path]) == .external(url))
    }

    @Test("A path that is not there goes nowhere")
    func missingPath() throws {
        let directory = try temporaryDirectory()
        #expect(TerminalLink.destination(of: "Sources/Missing.swift", from: [directory.path]) == nil)
        #expect(TerminalLink.destination(of: "/nowhere-\(UUID().uuidString)/notes.md", from: []) == nil)
    }

    @Test("A session on another machine opens addresses and never files")
    func anotherMachine() throws {
        let path = try file("notes.md", in: try temporaryDirectory())
        #expect(TerminalLink.address(of: path) == nil)
        #expect(TerminalLink.address(of: URL(fileURLWithPath: path).absoluteString) == nil)
        #expect(TerminalLink.address(of: "https://example.com") == URL(string: "https://example.com"))
    }

    /// Lays text out the way Claude Code does: wrapped by the program itself
    /// and each line after the first indented, so the terminal is handed
    /// separate lines rather than one that ran over its edge.
    private func wrappedByTheProgram(_ text: String, width: Int, indent: String = "  ") -> [String] {
        var rest = Substring(text)
        var lines = [String(rest.prefix(width))]
        rest = rest.dropFirst(width)
        while !rest.isEmpty {
            let room = width - indent.count
            lines.append(indent + rest.prefix(room))
            rest = rest.dropFirst(room)
        }
        return lines
    }

    @Test("A path an agent wrapped onto the next line opens whole, from either line")
    func pathWrappedByTheAgent() throws {
        let path = try file(
            "claude-501/-Users-someone-Developer-projects-frontend/bf408979-cc5f-4fbe-9b3f-d34facebe8fd/scratchpad/libraries.md",
            in: try temporaryDirectory()
        )
        let width = 80
        let lines = wrappedByTheProgram("● Список готов: " + path, width: width)
        try #require(lines.count >= 2)

        let delegate = Unattended()
        let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: width, rows: 10))
        terminal.feed(text: lines.joined(separator: "\r\n"))

        for position in [Position(col: width - 3, row: 0), Position(col: 4, row: lines.count - 1)] {
            let link = try #require(terminal.link(at: .screen(position), mode: .explicitAndImplicit))
            #expect(TerminalLink.destination(of: link, from: []) == .file(path: path, line: nil, column: nil))
        }
    }

    @Test("A shell is found in the directory it is in, not the one it started in")
    func currentDirectory() throws {
        let started = try temporaryDirectory()
        let moved = try temporaryDirectory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Says when it has moved, then waits on its input rather than on a
        // timer, so it is still there to be asked however long that takes.
        process.arguments = ["-c", "cd \"$1\" && echo moved && read -r _", "sh", moved.path]
        process.currentDirectoryURL = started
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        defer {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
        #expect(!output.fileHandleForReading.availableData.isEmpty)

        // The kernel spells the directory with its links followed:
        // `/private/var`, where the temporary directory says `/var`.
        let resolved = try #require(realpath(moved.path, nil))
        defer { free(resolved) }
        #expect(KernelProcessTable().currentDirectory(of: process.processIdentifier) == String(cString: resolved))
    }

    @Test("A line and a column are found in the text")
    func offsetOfLine() {
        let text = "one\ntwo\nthree"
        #expect(OpenFile.offset(ofLine: 1, column: nil, in: text) == 0)
        #expect(OpenFile.offset(ofLine: 2, column: 2, in: text) == 5)
        #expect(OpenFile.offset(ofLine: 3, column: nil, in: text) == 8)
        // Never past the end of the line it names, nor of the file.
        #expect(OpenFile.offset(ofLine: 2, column: 40, in: text) == 7)
        #expect(OpenFile.offset(ofLine: 40, column: nil, in: text) == 13)
    }
}
