import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("Changing the files themselves")
struct FileActionsTests {
    @Test("A rename is a move inside the folder")
    func rename() throws {
        let directory = try TemporaryDirectory()
        try directory.write("one\n", to: "notes.txt")
        let path = directory.url.appendingPathComponent("notes.txt").path

        let moved = try FileActions.rename(path, to: "readme.txt")

        #expect(moved == directory.url.appendingPathComponent("readme.txt").path)
        #expect(try String(contentsOfFile: moved, encoding: .utf8) == "one\n")
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("A name is a name, not a path")
    func names() throws {
        let directory = try TemporaryDirectory()
        try directory.write("one\n", to: "notes.txt")
        let path = directory.url.appendingPathComponent("notes.txt").path

        #expect(!FileActions.isValid(""))
        #expect(!FileActions.isValid("  "))
        #expect(!FileActions.isValid("a/b"))
        #expect(!FileActions.isValid(".."))
        #expect(FileActions.isValid(".env"))

        #expect(throws: FileActions.Failure.invalidName) {
            try FileActions.rename(path, to: "elsewhere/notes.txt")
        }
    }

    @Test("Nothing is renamed or created over something that is there")
    func collisions() throws {
        let directory = try TemporaryDirectory()
        try directory.write("one\n", to: "notes.txt")
        try directory.write("two\n", to: "readme.txt")
        let path = directory.url.appendingPathComponent("notes.txt").path

        #expect(throws: FileActions.Failure.alreadyExists("readme.txt")) {
            try FileActions.rename(path, to: "readme.txt")
        }
        #expect(throws: FileActions.Failure.alreadyExists("readme.txt")) {
            try FileActions.create("readme.txt", in: directory.url.path, isDirectory: false)
        }
        // And what was there is untouched.
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "one\n")
    }

    @Test("A new file is an empty file, and a new folder is a folder")
    func creating() throws {
        let directory = try TemporaryDirectory()

        let file = try FileActions.create("fresh.swift", in: directory.url.path, isDirectory: false)
        let folder = try FileActions.create("Views", in: directory.url.path, isDirectory: true)

        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: file, isDirectory: &isDirectory))
        #expect(!isDirectory.boolValue)
        #expect(try String(contentsOfFile: file, encoding: .utf8).isEmpty)
        #expect(FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
    }
}

@Suite("The tree changing a file under the panes")
@MainActor
struct FileTreeActionTests {
    private func project() throws -> (AppModel, Project, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        try directory.write("let value = 1\n", to: "Sources/A.swift")
        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        model.addProject(at: directory.url)
        return (model, try #require(model.projects.first), directory)
    }

    @Test("Renaming an open file takes the buffer and the pane with it")
    func renamingWhatIsOpen() throws {
        let (model, project, directory) = try project()
        let path = directory.url.appendingPathComponent("Sources/A.swift").path
        #expect(model.openFile(at: path, in: project.id))

        model.renameFile(at: path, to: "B.swift", in: project.id)
        let moved = directory.url.appendingPathComponent("Sources/B.swift").path

        #expect(model.editors[path] == nil)
        #expect(model.editors[moved]?.text == "let value = 1\n")
        #expect(model.editors.focused == moved)
        #expect(PaneLayout.files(in: try #require(model.paneLayout(for: project.id))) == [moved])
        _ = directory
    }

    @Test("Unsaved work goes with the file rather than back to the old name")
    func renamingWhatIsUnsaved() throws {
        // The save has to happen before the move: one that lands after it
        // writes the old path back into existence, and the tree then shows
        // the file twice.
        let (model, project, directory) = try project()
        let path = directory.url.appendingPathComponent("Sources/A.swift").path
        #expect(model.openFile(at: path, in: project.id))
        model.editors[path]?.text = "let value = 2\n"

        model.renameFile(at: path, to: "B.swift", in: project.id)
        let moved = directory.url.appendingPathComponent("Sources/B.swift").path

        #expect(try String(contentsOfFile: moved, encoding: .utf8) == "let value = 2\n")
        #expect(!FileManager.default.fileExists(atPath: path))
        _ = directory
    }

    @Test("Deleting closes what was showing it")
    func deleting() throws {
        let (model, project, directory) = try project()
        let path = directory.url.appendingPathComponent("Sources/A.swift").path
        #expect(model.openFile(at: path, in: project.id))

        model.deleteFile(at: path, in: project.id)

        #expect(model.editors[path] == nil)
        #expect(model.paneLayout(for: project.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: path))
        _ = directory
    }

    @Test("⌘+ resizes the file in front of you, and the terminal behind it otherwise")
    func fontSize() throws {
        // The same rule as ⌘W: the shortcut is about what the keyboard is in.
        let (model, project, directory) = try project()
        let terminal = model.terminalFontSize
        let path = directory.url.appendingPathComponent("Sources/A.swift").path

        model.stepFontSize(by: 1)
        #expect(model.terminalFontSize == terminal + 1)

        #expect(model.openFile(at: path, in: project.id))
        let editor = model.editorFontSize
        model.stepFontSize(by: 1)

        #expect(model.editorFontSize == editor + 1)
        #expect(model.terminalFontSize == terminal + 1)

        model.resetFontSize()
        #expect(model.editorFontSize == Double(TerminalZoom.defaultSize))
        _ = directory
    }

    @Test("A new file is made and opened; a new folder is made and not")
    func creating() throws {
        let (model, project, directory) = try project()
        let sources = directory.url.appendingPathComponent("Sources").path

        model.createFile(named: "C.swift", in: sources, isDirectory: false, in: project.id)
        model.createFile(named: "Views", in: sources, isDirectory: true, in: project.id)

        let made = (sources as NSString).appendingPathComponent("C.swift")
        #expect(model.editors[made] != nil)
        #expect(model.editors[(sources as NSString).appendingPathComponent("Views")] == nil)
        _ = directory
    }
}
