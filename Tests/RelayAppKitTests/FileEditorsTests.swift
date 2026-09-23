import AppKit
import Foundation
import RelayProtocol
import SwiftUI
import Testing

@testable import RelayAppKit

@Suite("Open files")
@MainActor
struct FileEditorsTests {
    /// A real file in a real directory: what is being tested is whether the
    /// bytes reach the disk, which a fake file system would answer for itself.
    private func temporaryFile(contents: String = "one\ntwo\n") throws -> String {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("notes.swift")
        try contents.write(to: file, atomically: true, encoding: .utf8)
        return file.path
    }

    @Test("Opening reads the file and names its language")
    func opening() throws {
        let path = try temporaryFile()
        let editors = FileEditors()
        #expect(editors.open(path))
        let file = try #require(editors[path])

        #expect(file.text == "one\ntwo\n")
        #expect(file.isModified == false)
        #expect(file.language?.code.tsName == "swift")
    }

    @Test("Opening the same path twice is one buffer, not two")
    func openingTwice() throws {
        // Two panes on one file that each held their own copy would overwrite
        // each other, and the loser would be whichever was saved first.
        let path = try temporaryFile()
        let editors = FileEditors()
        #expect(editors.open(path))
        let first = try #require(editors[path])
        first.text = "edited"
        #expect(editors.open(path))
        let second = try #require(editors[path])

        #expect(second === first)
        #expect(second.text == "edited")
    }

    @Test("The tree keeps pointing at the file worked in")
    func recentSurvivesTheTerminal() throws {
        // Moving to a terminal sets no file as focused, and a tree that
        // blanked its mark then would be saying the window is not showing a
        // file when it plainly is.
        let path = try temporaryFile()
        let editors = FileEditors()
        editors.open(path)
        editors.focused = path

        editors.focused = nil
        #expect(editors.recent == path)

        editors.close(path)
        #expect(editors.recent == nil)
    }

    @Test("Opening another file closes the one that was open")
    func oneAtATime() throws {
        // The pane is somewhere to read and correct the file an agent is
        // working on, beside the agent — not a desk to stack documents on.
        let first = try temporaryFile()
        let second = try temporaryFile(contents: "two\n")
        let editors = FileEditors()
        #expect(editors.open(first))
        let opened = try #require(editors[first])
        opened.text = "edited\n"
        editors.focused = first

        editors.open(second)

        #expect(editors.openPaths == [second])
        #expect(editors.openPath == second)
        // And the one that went was written out on the way.
        #expect(try String(contentsOfFile: first, encoding: .utf8) == "edited\n")
    }

    @Test("A file that cannot be read is not opened at all")
    func missingFile() {
        let editors = FileEditors()
        #expect(editors.open("/definitely/not/here.swift") == false)
        #expect(editors.files.isEmpty)
    }

    @Test("Leaving a file writes it out")
    func savesOnLosingFocus() throws {
        // The rule the whole editor rests on: an agent reading the file in the
        // terminal beside it must not be reading a version that only exists in
        // the editor.
        let path = try temporaryFile()
        let editors = FileEditors()
        #expect(editors.open(path))
        let file = try #require(editors[path])
        editors.focused = path
        file.text = "changed on screen\n"

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "one\ntwo\n")

        editors.focused = nil

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "changed on screen\n")
        #expect(file.isModified == false)
    }

    @Test("Closing writes it out too")
    func savesOnClose() throws {
        let path = try temporaryFile()
        let editors = FileEditors()
        #expect(editors.open(path))
        let file = try #require(editors[path])
        file.text = "closed with changes\n"
        editors.close(path)

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "closed with changes\n")
        #expect(editors.files.isEmpty)
    }

    @Test("Saving an unchanged file does not touch it")
    func unchangedFileIsLeftAlone() throws {
        // Rewriting identical bytes still moves the modification date, and
        // anything watching the directory — a dev server, a test runner —
        // rebuilds for nothing.
        let path = try temporaryFile()
        let editors = FileEditors()
        editors.open(path)
        let before = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date

        editors.save(path)

        let after = try FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date
        #expect(before == after)
    }

    @Test("A file rewritten underneath can be taken again")
    func reloading() throws {
        let path = try temporaryFile()
        let editors = FileEditors()
        #expect(editors.open(path))
        let file = try #require(editors[path])
        try "written by an agent\n".write(toFile: path, atomically: true, encoding: .utf8)

        file.reload()

        #expect(file.text == "written by an agent\n")
        #expect(file.isModified == false)
    }
}

@Suite("Panes holding files")
struct FilePaneLayoutTests {
    private let session = SessionID(rawValue: UUID().uuidString)

    @Test("A file can sit beside a session")
    func splittingWithAFile() {
        let layout = PaneNode.session(session)
        let split = PaneLayout.split(
            layout,
            target: .session(session),
            with: .file("/p/a.swift"),
            axis: .horizontal
        )

        #expect(PaneLayout.items(in: split) == [.session(session), .file("/p/a.swift")])
        #expect(PaneLayout.files(in: split) == ["/p/a.swift"])
        #expect(PaneLayout.sessions(in: split) == [session])
    }

    @Test("Closing a file collapses the split it was in")
    func removingAFile() {
        let split = PaneLayout.split(
            .session(session),
            target: .session(session),
            with: .file("/p/a.swift"),
            axis: .horizontal
        )
        let left = PaneLayout.removing(.file("/p/a.swift"), from: split)

        #expect(left == .session(session))
    }

    @Test("Pruning keeps open files and drops closed ones")
    func pruning() {
        // A layout restored from disk names files as well as sessions, and the
        // prune that runs on every session list is what would otherwise throw
        // every file pane away a second after launch.
        let split = PaneLayout.split(
            .session(session),
            target: .session(session),
            with: .file("/p/a.swift"),
            axis: .horizontal
        )

        let kept = PaneLayout.pruning(split, keeping: [session], openFiles: ["/p/a.swift"])
        #expect(kept == split)

        let dropped = PaneLayout.pruning(split, keeping: [session], openFiles: [])
        #expect(dropped == .session(session))
    }

    @Test("Selecting a session does not sweep away the file open beside it")
    func showingKeepsFiles() {
        // What happened: closing a terminal picks the next session, finds no
        // session pane to put it in — the only pane left is the editor — and
        // used to replace the whole arrangement with it. The file vanished, and
        // from the outside it looked as though the close button had shut the
        // editor rather than the terminal.
        let other = SessionID(rawValue: UUID().uuidString)
        let layout = PaneNode.file("/p/a.swift")

        let shown = PaneLayout.showing(.session(other), in: layout, focused: nil)

        #expect(PaneLayout.files(in: shown) == ["/p/a.swift"])
        #expect(PaneLayout.sessions(in: shown) == [other])
    }

    @Test("A session replaces the session being worked in, not a file")
    func showingReplacesItsOwnKind() {
        let old = SessionID(rawValue: UUID().uuidString)
        let new = SessionID(rawValue: UUID().uuidString)
        let layout = PaneLayout.split(
            .session(old),
            target: .session(old),
            with: .file("/p/a.swift"),
            axis: .horizontal
        )

        // The pane being worked in is gone — this is the state right after a
        // terminal was closed — so the newcomer takes the first pane of its own
        // kind instead.
        let shown = PaneLayout.showing(.session(new), in: layout, focused: nil)

        #expect(PaneLayout.sessions(in: shown) == [new])
        #expect(PaneLayout.files(in: shown) == ["/p/a.swift"])
    }

    @Test("A session already on screen is left where it is")
    func showingIsIdempotent() {
        let session = SessionID(rawValue: UUID().uuidString)
        let layout = PaneLayout.split(
            .session(session),
            target: .session(session),
            with: .file("/p/a.swift"),
            axis: .horizontal
        )

        #expect(PaneLayout.showing(.session(session), in: layout, focused: nil) == layout)
    }

    @Test("A saved layout of sessions still decodes")
    func decodesOlderLayouts() throws {
        // `file` was added to the enum after `session` and `split`. Every
        // workspace on disk was written before it existed.
        // The fixture is the encoding itself rather than a hand-written guess:
        // what has to keep working is that today's decoder reads what an older
        // build wrote, and the shape of that is whatever the enum encodes to
        // when `file` is not involved.
        let stored = try JSONEncoder().encode(PaneNode.session(session))
        let text = try #require(String(data: stored, encoding: .utf8))
        #expect(text.contains("session"))
        #expect(!text.contains("file"))

        let decoded = try JSONDecoder().decode(PaneNode.self, from: stored)
        #expect(decoded == .session(session))
    }
}

@Suite("One file at a time")
@MainActor
struct SingleFilePaneTests {
    private func project() throws -> (AppModel, Project, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        try directory.write("one\n", to: "a.swift")
        try directory.write("two\n", to: "b.swift")
        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        model.addProject(at: directory.url)
        return (model, try #require(model.projects.first), directory)
    }

    @Test("The second file takes the first one's pane")
    func replacesThePane() throws {
        // Splitting again for every file somebody glances at leaves an
        // arrangement nobody arranged.
        let (model, project, directory) = try project()
        let first = directory.url.appendingPathComponent("a.swift").path
        let second = directory.url.appendingPathComponent("b.swift").path

        #expect(model.openFile(at: first, in: project.id))
        #expect(model.openFile(at: second, in: project.id))

        #expect(model.editors[first] == nil)
        #expect(model.editors.openPath == second)
        #expect(PaneLayout.files(in: try #require(model.paneLayout(for: project.id))) == [second])
        _ = directory
    }

    @Test("A file left open in another project goes with its pane")
    func acrossProjects() throws {
        let (model, first, directory) = try project()
        let other = try TemporaryDirectory()
        try other.write("three\n", to: "c.swift")
        model.addProject(at: other.url)
        let second = try #require(model.projects.last)

        let inFirst = directory.url.appendingPathComponent("a.swift").path
        let inSecond = other.url.appendingPathComponent("c.swift").path
        #expect(model.openFile(at: inFirst, in: first.id))
        #expect(model.openFile(at: inSecond, in: second.id))

        // Nothing is left behind saying the file is unavailable.
        #expect(model.paneLayout(for: first.id) == nil)
        #expect(PaneLayout.files(in: try #require(model.paneLayout(for: second.id))) == [inSecond])
        _ = (directory, other)
    }
}

@Suite("File tree")
struct FileTreeTests {
    private func directory(_ build: (URL) throws -> Void) throws -> String {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-tree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try build(root)
        return root.path
    }

    @Test("Folders come first, then names in the order a person reads them")
    func ordering() throws {
        let root = try directory { root in
            try Data().write(to: root.appendingPathComponent("zebra.swift"))
            try Data().write(to: root.appendingPathComponent("alpha.swift"))
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("Views"),
                withIntermediateDirectories: true
            )
        }

        let entries = try FileTree.entries(in: root)

        #expect(entries.map(\.name) == ["Views", "alpha.swift", "zebra.swift"])
        #expect(entries.first?.isDirectory == true)
    }

    @Test("Dotfiles are listed, because they are what a tree is opened for")
    func dotfilesAreVisible() throws {
        // `.env` and `.gitignore` are among the most-edited files in a project.
        // Hiding everything starting with a dot — what a file browser does —
        // would hide the half worth having.
        let root = try directory { root in
            try Data().write(to: root.appendingPathComponent(".env"))
            try Data().write(to: root.appendingPathComponent(".gitignore"))
        }

        #expect(try FileTree.entries(in: root).map(\.name) == [".env", ".gitignore"])
    }

    @Test("Git's own database and Finder's leavings are not")
    func noiseIsHidden() throws {
        let root = try directory { root in
            try Data().write(to: root.appendingPathComponent(".DS_Store"))
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".git"),
                withIntermediateDirectories: true
            )
            try Data().write(to: root.appendingPathComponent("README.md"))
        }

        #expect(try FileTree.entries(in: root).map(\.name) == ["README.md"])
    }

    @Test("The folders that have to be open for a file to be seen")
    func ancestors() {
        // A tree that reads a folder when it is opened cannot point at a file
        // four levels down without opening the four.
        #expect(
            FileTree.ancestors(of: "/p/Sources/Views/GitPanel.swift", under: "/p")
                == ["/p/Sources", "/p/Sources/Views"]
        )
        // Outermost first, because each one is opened by the one above it.
        #expect(FileTree.ancestors(of: "/p/README.md", under: "/p") == [])
        #expect(FileTree.ancestors(of: "/p/a/b.swift", under: "/p/") == ["/p/a"])
    }

    @Test("A file outside the project is nowhere in its tree")
    func outsideTheProject() {
        // Opened from a dependency, or from anywhere else on the disk: there
        // is no row to point at, and inventing folders to open would be
        // opening somebody else's.
        #expect(FileTree.ancestors(of: "/elsewhere/a.swift", under: "/p") == [])
        #expect(FileTree.ancestors(of: "/p-other/a.swift", under: "/p") == [])
    }

    @Test("A directory that cannot be read says so")
    func unreadableDirectory() {
        // Silence here reads as "this folder is empty", which is the one
        // answer that stops anybody looking for the real reason.
        #expect(throws: (any Error).self) {
            try FileTree.entries(in: "/definitely/not/here")
        }
    }
}

@Suite("File tree drawing", .serialized)
@MainActor
struct FileTreeRenderingTests {
    /// The tree opens itself down to the file being worked in.
    ///
    /// Measured by how much of a document the scroll view ends up with, which
    /// is the only thing about a drawn tree a test can get hold of: SwiftUI
    /// draws a run of rows into one view, so counting views says the same for
    /// four rows as for two.
    @Test("Opening a file opens the folders it is in")
    func revealsTheOpenFile() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("# notes\n", to: "README.md")
        try directory.write("struct GitPanel {}\n", to: "Sources/Views/GitPanel.swift")

        let closed = try await documentHeight(in: directory, opening: nil)
        let open = try await documentHeight(
            in: directory,
            opening: directory.url.appendingPathComponent("Sources/Views/GitPanel.swift").path
        )

        // Two rows at the root either way; two more when the folders between
        // the root and the file have been opened.
        #expect(open > closed, Comment(rawValue: "closed \(closed), open \(open)"))
    }

    private func documentHeight(in directory: TemporaryDirectory, opening path: String?) async throws -> CGFloat {
        // The workspace file goes somewhere else: written into the project it
        // becomes a row in the tree being measured, and appears between the
        // two measurements rather than in both.
        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        model.addProject(at: directory.url)
        let project = try #require(model.projects.first)
        if let path { #expect(model.openFile(at: path, in: project.id)) }

        let hosting = NSHostingView(rootView: FileTreePane(project: project).environment(model))
        // Deliberately short: a scroll view whose content fits inside it
        // reports the height of the viewport whatever is in it, and both
        // trees would measure the same.
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 90)
        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        // The reads are `task`s, and the one that opens the folders waits for
        // the rows of the folder above it to exist.
        for _ in 0 ..< 10 {
            try? await Task.sleep(for: .milliseconds(100))
            hosting.layoutSubtreeIfNeeded()
        }

        func scrollViews(in view: NSView) -> [NSScrollView] {
            var found: [NSScrollView] = []
            if let scroll = view as? NSScrollView { found.append(scroll) }
            for subview in view.subviews { found.append(contentsOf: scrollViews(in: subview)) }
            return found
        }
        let scroll = try #require(scrollViews(in: hosting).first)
        return scroll.documentView?.frame.height ?? 0
    }

    /// Draws one level of the tree off-screen and measures how tall it came out.
    ///
    /// The bug this exists for cannot be caught any other way: a modifier on a
    /// transparent container — a bare `ForEach`, or a `Group` — is applied to
    /// each child rather than to the whole, so the read that fills the tree
    /// never ran and the pane came up empty. It compiled, every other test
    /// passed, and the panel was blank.
    ///
    /// Height rather than a count of subviews: SwiftUI draws a list of rows
    /// into one view, so counting views says the same thing for four files as
    /// for none.
    private func height(ofLevelIn directory: String) async -> CGFloat {
        let model = AppModel()
        let project = Project(name: "probe", rootPath: directory)
        let level = FileTreeLevel(
            directory: directory,
            depth: 0,
            project: project,
            state: FileTreeState()
        )
        let hosting = NSHostingView(rootView: level.environment(model).frame(width: 320))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()

        // The read is a `task`, so it lands a turn of the run loop later.
        try? await Task.sleep(for: .milliseconds(400))
        hosting.layoutSubtreeIfNeeded()

        let height = hosting.fittingSize.height
        window.orderOut(nil)
        return height
    }

    @Test("A folder with files in it draws taller than an empty one")
    func drawsRows() async throws {
        let manager = FileManager.default
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-empty-\(UUID().uuidString)")
        try manager.createDirectory(at: empty, withIntermediateDirectories: true)

        let full = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-full-\(UUID().uuidString)")
        try manager.createDirectory(at: full, withIntermediateDirectories: true)
        for name in ["a.swift", "b.swift", "c.swift", "d.swift"] {
            try Data().write(to: full.appendingPathComponent(name))
        }

        let emptyHeight = await height(ofLevelIn: empty.path)
        let fullHeight = await height(ofLevelIn: full.path)

        #expect(fullHeight > emptyHeight, "the tree drew nothing for a folder with four files in it")
    }
}
