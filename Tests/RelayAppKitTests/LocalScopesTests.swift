import Foundation
import Testing

@testable import RelayAppKit

@Suite("A name in its own scope")
struct LocalScopesTests {
    private func binding(_ source: String, at word: String, occurrence: Int = 1, path: String) -> LocalBinding? {
        guard let language = SourceLanguage.detect(path: path, contents: source) else { return nil }
        let text = source as NSString
        var range = NSRange(location: 0, length: 0)
        var found = 0
        var searched = 0
        while searched < text.length {
            let rest = NSRange(location: searched, length: text.length - searched)
            let match = text.range(of: word, range: rest)
            guard match.location != NSNotFound else { break }
            found += 1
            searched = NSMaxRange(match)
            if found == occurrence {
                range = match
                break
            }
        }
        guard found >= occurrence else { return nil }
        return LocalScopes.binding(at: range.location + 1, in: source, language: language)
    }

    @Test("A parameter is declared where it is written, not in another file")
    func parameter() throws {
        // The bug this exists for: ⌘-clicking `platform` in the body jumped
        // to a `platform` in some other file, when the one that was meant is
        // the parameter three lines up.
        let source = """
        const syncDocumentAttribute = (platform: Platform) => {
            if (typeof document === 'undefined') return;
            document.documentElement.dataset.platform = platform;
        };
        """
        let found = try #require(binding(source, at: "platform", occurrence: 3, path: "/p/platform.ts"))

        // The declaration is the parameter on the first line.
        #expect(found.definition == (source as NSString).range(of: "platform"))
        // And the uses are the parameter and the reading of it. The
        // `dataset.platform` in between is a property, not this name.
        #expect(found.ranges.count == 2)
        #expect(found.ranges.allSatisfy { (source as NSString).substring(with: $0) == "platform" })
    }

    @Test("A local declaration answers before the project does")
    func localConstant() throws {
        let source = """
        function draw() {
            const width = 10;
            return width * 2;
        }
        """
        let found = try #require(binding(source, at: "width", occurrence: 2, path: "/p/draw.js"))

        #expect(found.definition == (source as NSString).range(of: "width"))
        #expect(found.ranges.count == 2)
    }

    @Test("The nearest declaration wins, which is what shadowing is")
    func shadowing() throws {
        let source = """
        function outer(value) {
            function inner(value) {
                return value + 1;
            }
            return inner(value);
        }
        """
        // The `value` inside `inner` is the parameter of `inner`.
        let inner = try #require(binding(source, at: "value", occurrence: 3, path: "/p/shadow.js"))
        let declaration = (source as NSString).range(of: "value", options: [], range: NSRange(
            location: (source as NSString).range(of: "inner(value)").location,
            length: 20
        ))

        #expect(inner.definition == declaration)
    }

    @Test("A name nothing around it declares is not local")
    func notLocal() {
        // A top-level function is the index's business, and answering it from
        // here would stop the jump ever leaving the file.
        let source = "export function handle() {}\n"

        #expect(binding(source, at: "handle", path: "/p/a.ts") == nil)
    }

    @Test("A component's script is scoped like the script it is")
    func insideAComponent() throws {
        let source = """
        <script setup lang="ts">
        function submit(payload: string) {
            return send(payload);
        }
        </script>
        """
        let found = try #require(binding(source, at: "payload", occurrence: 2, path: "/p/Form.vue"))

        #expect(found.ranges.count == 2)
        #expect((source as NSString).substring(with: found.definition) == "payload")
    }
}

@Suite("A local name from the window")
@MainActor
struct LocalJumpTests {
    @Test("⌘-clicking a parameter stays in the file and marks its uses")
    func parameterJump() throws {
        let source = """
        const sync = (platform: string) => {
            document.dataset.platform = platform;
        };
        """
        let directory = try TemporaryDirectory()
        try directory.write(source, to: "platform.ts")
        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        model.addProject(at: directory.url)
        let project = try #require(model.projects.first)
        let path = directory.url.appendingPathComponent("platform.ts").path
        #expect(model.openFile(at: path, in: project.id))

        let text = source as NSString
        // The reading of it on the second line, which is the one that used to
        // send the caret to another file entirely.
        let use = text.range(of: "= platform").location + 2
        model.goToDefinition(at: use, in: path, projectID: project.id)

        let file = try #require(model.editors[path])
        let reveal = try #require(file.reveal)
        #expect(reveal.range == text.range(of: "platform"))
        #expect(file.occurrences.count == 2)
        #expect(model.canGoBackToOrigin)
        _ = directory
    }

    @Test("The marks go when the caret leaves them")
    func marksAreLetGo() throws {
        let directory = try TemporaryDirectory()
        try directory.write("function f(value) { return value; }\n", to: "a.js")
        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        model.addProject(at: directory.url)
        let project = try #require(model.projects.first)
        let path = directory.url.appendingPathComponent("a.js").path
        #expect(model.openFile(at: path, in: project.id))

        let text = try #require(model.editors[path]).text as NSString
        model.goToDefinition(at: text.range(of: "return value").location + 8, in: path, projectID: project.id)
        #expect(model.editors[path]?.occurrences.isEmpty == false)

        // Still inside one of them: the mark is the answer to where the caret
        // is, so it stays.
        model.focusFile(at: path, caret: text.range(of: "value").location + 1)
        #expect(model.editors[path]?.occurrences.isEmpty == false)

        model.focusFile(at: path, caret: 0)
        #expect(model.editors[path]?.occurrences.isEmpty == true)
        _ = directory
    }
}
