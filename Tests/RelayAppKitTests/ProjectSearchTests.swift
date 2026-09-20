import Foundation
import RelayProtocol
import RelayUI
import Testing

@testable import RelayAppKit

@Suite("Finding a file by name")
struct FileMatchingTests {
    private let files = [
        "/p/Sources/Views/GitPanel.swift",
        "/p/Sources/Model/AppModel.swift",
        "/p/docs/SPEC.md",
        "/p/node_modules/vue/dist/vue.d.ts",
    ]

    @Test("The name is worth more than the folder it is in")
    func byName() {
        let found = FileMatching.matches("gitpanel", in: files, under: "/p", limit: 10)

        #expect(found.first?.path == "/p/Sources/Views/GitPanel.swift")
    }

    @Test("Letters scattered across a path are not a match")
    func notASubsequenceOfThePath() {
        // What this exists for: `useplatform` in a web project answered with
        // `types.ts`, whose path happened to carry those eleven letters in
        // that order among two hundred others. A name may be matched by its
        // parts; a path may only be matched by what is written out.
        let paths = [
            "/p/src/composables/usePlatform.ts",
            "/p/src/utils/serialisers/exporters/platform/layout/formatters/types.ts",
        ]
        let found = FileMatching.matches("useplatform", in: paths, under: "/p", limit: 10)

        #expect(found.map(\.path) == ["/p/src/composables/usePlatform.ts"])
    }

    @Test("A folder written out finds what is in it")
    func folderWrittenOut() {
        let paths = ["/p/src/composables/usePlatform.ts", "/p/src/views/App.vue"]
        let found = FileMatching.matches("composables", in: paths, under: "/p", limit: 10)

        #expect(found.map(\.path) == ["/p/src/composables/usePlatform.ts"])
    }

    @Test("A folder finds what is in it")
    func byFolder() {
        let found = FileMatching.matches("docs", in: files, under: "/p", limit: 10)

        #expect(found.contains { $0.path == "/p/docs/SPEC.md" })
    }

    @Test("Nothing matching is nothing, rather than everything")
    func noMatch() {
        #expect(FileMatching.matches("zzzz", in: files, under: "/p", limit: 10).isEmpty)
        #expect(FileMatching.matches(" ", in: files, under: "/p", limit: 10).isEmpty)
    }

    @Test("Only as many as asked for, best first")
    func limited() {
        let found = FileMatching.matches("s", in: files, under: "/p", limit: 2)

        #expect(found.count <= 2)
        #expect(found.first!.score >= found.last!.score)
    }

    @Test("The path as it reads inside the project")
    func relativePaths() {
        #expect(FileMatching.relative("/p/docs/SPEC.md", to: "/p") == "docs/SPEC.md")
        #expect(FileMatching.relative("/elsewhere/a.txt", to: "/p") == "/elsewhere/a.txt")
    }
}

@Suite("Walking a project for its files")
struct ProjectFilesTests {
    @Test("The project's own files, and not what it depends on")
    func walk() throws {
        let directory = try TemporaryDirectory()
        try directory.write("# notes\n", to: "README.md")
        try directory.write("A=1\n", to: ".env")
        try directory.write("struct A {}\n", to: "Sources/A.swift")
        try directory.write("module.exports = {}\n", to: "node_modules/pkg/index.js")
        try directory.write("ref: HEAD\n", to: ".git/HEAD")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: directory.url.appendingPathComponent("icon.png"))

        let found = Set(ProjectFiles.walk(root: directory.url.path).map { ($0 as NSString).lastPathComponent })

        // Dotfiles are files a person edits; dot directories are not.
        #expect(found == [".env", "README.md", "A.swift"])
    }
}

@Suite("Searching what is in the files")
struct TextSearchTests {
    @Test("Every line that has it, with the line a person would be told")
    func lines() {
        let text = "let a = 1\nlet needle = 2\nlet b = 3\nprint(needle)\n"
        let found = TextSearch.hits(of: "needle", in: text, path: "/p/a.swift")

        #expect(found.map(\.line) == [2, 4])
        #expect(found.first?.text == "let needle = 2")
    }

    @Test("The range is the match in the file, for putting the caret on it")
    func ranges() throws {
        let text = "one\ntwo needle three\n"
        let hit = try #require(TextSearch.hits(of: "needle", in: text, path: "/p/a.swift").first)

        #expect((text as NSString).substring(with: hit.range) == "needle")
        #expect((hit.text as NSString).substring(with: hit.inLine) == "needle")
    }

    @Test("Case is not what anybody means by searching for a word")
    func caseInsensitive() {
        let found = TextSearch.hits(of: "todo", in: "// TODO: fix\n", path: "/p/a.swift")

        #expect(found.count == 1)
        #expect(found.first?.inLine.location == 3)
    }

    @Test("A line too long to read is shown around the match")
    func longLines() throws {
        // A minified bundle is one line of a hundred thousand characters, and
        // a row of a result list is one line of about a hundred.
        let padding = String(repeating: "x", count: 5_000)
        let text = padding + "needle" + padding
        let hit = try #require(TextSearch.hits(of: "needle", in: text, path: "/p/bundle.js").first)

        #expect(hit.text.count < 200)
        #expect((hit.text as NSString).substring(with: hit.inLine) == "needle")
        // And the caret still lands on the real one, not on the window.
        #expect((text as NSString).substring(with: hit.range) == "needle")
    }

    @Test("One file cannot be the whole answer")
    func perFileLimit() {
        let text = String(repeating: "needle\n", count: 100)
        #expect(TextSearch.hits(of: "needle", in: text, path: "/p/a.swift").count == TextSearch.perFile)
    }

    @Test("Nothing to look for finds nothing")
    func empty() {
        #expect(TextSearch.hits(of: "", in: "anything", path: "/p/a.swift").isEmpty)
        #expect(TextSearch.hits(of: "x", in: "", path: "/p/a.swift").isEmpty)
    }

    @Test("Case, whole words and a pattern, when they are asked for")
    func options() {
        let text = "let value = 1\nlet Value = 2\nlet values = 3\n"

        #expect(TextSearch.hits(of: "value", in: text, path: "/p/a.swift").count == 3)
        #expect(
            TextSearch.hits(
                of: "value",
                in: text,
                path: "/p/a.swift",
                options: TextSearch.Options(isCaseSensitive: true)
            ).count == 2
        )
        // `values` is another word, however much of this one it starts with.
        #expect(
            TextSearch.hits(
                of: "value",
                in: text,
                path: "/p/a.swift",
                options: TextSearch.Options(matchesWholeWords: true)
            ).count == 2
        )
        #expect(
            TextSearch.hits(
                of: "val[a-z]+s",
                in: text,
                path: "/p/a.swift",
                options: TextSearch.Options(isRegularExpression: true)
            ).count == 1
        )
    }

    @Test("A pattern that does not compile finds nothing rather than crashing")
    func brokenPattern() {
        // Half-typed is the normal state of a regular expression in a field
        // that searches as you type.
        #expect(
            TextSearch.hits(
                of: "val[",
                in: "value\n",
                path: "/p/a.swift",
                options: TextSearch.Options(isRegularExpression: true)
            ).isEmpty
        )
    }
}

@Suite("Finding in the file in front of you")
@MainActor
struct FindInFileTests {
    @Test("Every match, not one line's worth")
    func everyMatch() {
        // Two on one line are two matches: what a find bar walks through is
        // matches, and the line they are on is not the unit.
        let text = "needle and needle\nand a needle\n"
        let found = TextSearch.ranges(of: "needle", in: text)

        #expect(found.count == 3)
        #expect(found.allSatisfy { (text as NSString).substring(with: $0).lowercased() == "needle" })
    }

    @Test("Case is ignored here too")
    func caseInsensitive() {
        #expect(TextSearch.ranges(of: "todo", in: "// TODO and todo\n").count == 2)
    }

    @Test("Nothing to look for finds nothing")
    func empty() {
        #expect(TextSearch.ranges(of: "", in: "anything").isEmpty)
        #expect(TextSearch.ranges(of: "x", in: "").isEmpty)
    }

    @Test("A file of nothing else does not become the whole answer")
    func limited() {
        let text = String(repeating: "a", count: 5_000)
        #expect(TextSearch.ranges(of: "a", in: text, limit: 10).count == 10)
    }

    @Test("The walk wraps at both ends")
    func stepping() {
        // A find that stops at the bottom of the file has to be started again
        // to go on, which is the one thing nobody wants from a find.
        let found = CodeTextView.FindMatches(
            ranges: [NSRange(location: 0, length: 1), NSRange(location: 5, length: 1)],
            current: 0
        )

        #expect(found.stepped(1).current == 1)
        #expect(found.stepped(1).stepped(1).current == 0)
        #expect(found.stepped(-1).current == 1)
        #expect(CodeTextView.FindMatches().stepped(1).current == 0)
    }

    @Test("The counter says which of how many, and nothing before it is asked")
    func counter() {
        let two = CodeTextView.FindMatches(
            ranges: [NSRange(location: 0, length: 1), NSRange(location: 5, length: 1)],
            current: 1
        )

        #expect(two.counter(for: "a") == "2/2")
        #expect(two.counter(for: "") == "")
        #expect(CodeTextView.FindMatches().counter(for: "zzz") == "0")
    }

    @Test("⌘F asks the pane being worked in, and the project when none is")
    func routing() throws {
        let directory = try TemporaryDirectory()
        try directory.write("let needle = 1\n", to: "A.swift")
        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        model.addProject(at: directory.url)
        let project = try #require(model.projects.first)

        // No file open: the panel that searches everything is the only honest
        // thing to offer somebody who pressed find in a terminal.
        model.findInFocusedFile()
        #expect(model.activeModal == .search(project.id))
        model.dismissModal()

        #expect(model.openFile(at: directory.url.appendingPathComponent("A.swift").path, in: project.id))
        let before = model.findRequest
        model.findInFocusedFile()

        #expect(model.findRequest == before + 1)
        #expect(model.activeModal == nil)
    }
}

@Suite("Search from the window")
@MainActor
struct ProjectSearchTests {
    @Test("A search finds the lines and opening one puts the caret on the match")
    func searching() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("let value = 1\nlet needle = 2\n", to: "Sources/A.swift")
        try directory.write("# nothing here\n", to: "README.md")

        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        model.addProject(at: directory.url)
        let project = try #require(model.projects.first)

        model.searchQuery = "needle"
        model.search(in: project.id)
        for _ in 0 ..< 100 where model.searchHits.isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let hit = try #require(model.searchHits.first)
        #expect(hit.line == 2)
        #expect(hit.path.hasSuffix("Sources/A.swift"))

        model.open(hit, in: project.id)
        let opened = try #require(model.editors[hit.path])
        let reveal = try #require(opened.reveal)
        #expect((opened.text as NSString).substring(with: reveal.range) == "needle")
    }

    @Test("One letter is not a question")
    func tooShort() async throws {
        // It matches most of a codebase, and answering it is a window full of
        // lines nobody asked about.
        let directory = try TemporaryDirectory()
        try directory.write("let needle = 2\n", to: "A.swift")
        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        model.addProject(at: directory.url)
        let project = try #require(model.projects.first)

        model.searchQuery = "n"
        model.search(in: project.id)
        try? await Task.sleep(for: .milliseconds(400))

        #expect(model.searchHits.isEmpty)
        #expect(!model.isSearching)
    }
}
