import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("What a project declares")
@MainActor
struct SymbolIndexTests {
    @Test("Every file in the project is asked, and answers by name")
    func acrossFiles() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("package main\n\nfunc Handle() {}\n", to: "handler.go")
        try directory.write("package main\n\ntype Session struct{}\n", to: "inner/session.go")

        let index = SymbolIndex()
        await index.prepare(root: directory.url.path)

        #expect(index.isReady(directory.url.path))
        #expect(index.definitions(named: "Handle", in: directory.url.path).count == 1)
        #expect(index.definitions(named: "Session", in: directory.url.path).first?.kind == .type)
        #expect(index.definitions(named: "nothingAtAll", in: directory.url.path).isEmpty)
    }

    @Test("A project of components is read through to their scripts")
    func components() async throws {
        let directory = try TemporaryDirectory()
        try directory.write(
            "<script setup>\nfunction submit() {}\n</script>\n<template><b/></template>\n",
            to: "Editor.vue"
        )

        let index = SymbolIndex()
        await index.prepare(root: directory.url.path)

        #expect(index.definitions(named: "submit", in: directory.url.path).count == 1)
    }

    @Test("Somebody else's code is not read")
    func skipsDependencies() async throws {
        // A jump into `node_modules` lands in a bundle nobody wanted to read,
        // and reading them is most of what a scan would spend its time on.
        let directory = try TemporaryDirectory()
        try directory.write("package main\n\nfunc Mine() {}\n", to: "mine.go")
        try directory.write("package vendored\n\nfunc Mine() {}\n", to: "node_modules/pkg/theirs.go")
        try directory.write("package built\n\nfunc Mine() {}\n", to: ".build/generated.go")

        let index = SymbolIndex()
        await index.prepare(root: directory.url.path)

        let found = index.definitions(named: "Mine", in: directory.url.path)
        #expect(found.count == 1)
        #expect(found.first?.path.hasSuffix("mine.go") == true)
    }

    @Test("A file read again replaces what it used to declare")
    func replacingOneFile() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("package main\n\nfunc Before() {}\n", to: "one.go")

        let root = directory.url.path
        let index = SymbolIndex()
        await index.prepare(root: root)
        #expect(index.definitions(named: "Before", in: root).count == 1)

        let path = directory.url.appendingPathComponent("one.go").path
        let language = try #require(SourceLanguage.detect(path: path, contents: ""))
        let rewritten = "package main\n\nfunc After() {}\n"
        index.replace(
            SymbolTags.definitions(in: rewritten, language: language, path: path),
            for: path,
            in: root
        )

        #expect(index.definitions(named: "Before", in: root).isEmpty)
        #expect(index.definitions(named: "After", in: root).count == 1)
    }

    @Test("Forgetting a project makes it be read again")
    func invalidating() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("package main\n\nfunc First() {}\n", to: "one.go")

        let root = directory.url.path
        let index = SymbolIndex()
        await index.prepare(root: root)
        #expect(index.definitions(named: "Second", in: root).isEmpty)

        try directory.write("package main\n\nfunc Second() {}\n", to: "two.go")
        index.invalidate(root: root)
        #expect(!index.isReady(root))
        await index.prepare(root: root)

        #expect(index.definitions(named: "Second", in: root).count == 1)
    }
}

@Suite("Which declaration was meant")
struct DefinitionRankingTests {
    private func definition(_ path: String, kind: SymbolDefinition.Kind = .function) -> SymbolDefinition {
        SymbolDefinition(name: "handle", kind: kind, path: path, range: NSRange(location: 0, length: 6), line: 1)
    }

    @Test("The project answers before the things it depends on")
    func projectFirst() {
        let ranked = DefinitionRanking.ranked(
            [
                definition("/p/node_modules/vue/dist/vue.d.ts"),
                definition("/p/src/handlers.ts"),
            ],
            from: "/p/src/App.vue"
        )

        #expect(ranked.first?.path == "/p/src/handlers.ts")
    }

    @Test("The module the file says it means")
    func importedModule() {
        // Two packages declare it and the file has already said which one it
        // is talking to. Nothing else here can tell them apart.
        let ranked = DefinitionRanking.ranked(
            [
                definition("/p/node_modules/reka-ui/dist/index.d.ts"),
                definition("/p/node_modules/@vue/runtime-core/dist/runtime-core.d.ts"),
            ],
            from: "/p/src/App.vue",
            hints: DefinitionRanking.hints(in: "import { ref } from '@vue/runtime-core'\n")
        )

        #expect(ranked.first?.path.contains("runtime-core") == true)
    }

    @Test("A namespace a PHP file imports is a path")
    func phpNamespace() {
        let hints = DefinitionRanking.hints(in: "<?php\n\nuse Illuminate\\Support\\Facades\\Route;\n")
        #expect(hints.contains("Illuminate/Support/Facades/Route"))

        let ranked = DefinitionRanking.ranked(
            [
                definition("/p/vendor/other/src/Route.php"),
                definition("/p/vendor/laravel/framework/src/Illuminate/Support/Facades/Route.php"),
            ],
            from: "/p/app/Http/Controllers/UserController.php",
            hints: hints
        )

        #expect(ranked.first?.path.contains("Illuminate/Support/Facades") == true)
    }

    @Test("A neighbour before a stranger")
    func nearest() {
        let ranked = DefinitionRanking.ranked(
            [
                definition("/p/src/deep/down/here/handlers.ts"),
                definition("/p/src/views/handlers.ts"),
            ],
            from: "/p/src/views/App.vue"
        )

        #expect(ranked.first?.path == "/p/src/views/handlers.ts")
    }

    @Test("A relative import names a file")
    func relativeImport() {
        let hints = DefinitionRanking.hints(in: "import UserCard from './cards/UserCard.vue'\n")
        #expect(hints.contains("cards/UserCard.vue"))
    }

    @Test("The same click gives the same answer")
    func stable() {
        let candidates = [definition("/p/b.ts"), definition("/p/a.ts"), definition("/p/c.ts")]
        let first = DefinitionRanking.ranked(candidates, from: "/p/x.ts").map(\.path)
        let again = DefinitionRanking.ranked(candidates.reversed(), from: "/p/x.ts").map(\.path)

        #expect(first == again)
    }
}

@Suite("Going to where a name comes from")
@MainActor
struct GoToDefinitionTests {
    private func project(_ files: [String: String]) throws -> (AppModel, Project, TemporaryDirectory) {
        let directory = try TemporaryDirectory()
        for (name, contents) in files {
            try directory.write(contents, to: name)
        }
        // Its own workspace file: a test must not write to the one the app the
        // developer is running keeps its projects in.
        let model = AppModel(store: WorkspaceStore(url: directory.url.appendingPathComponent("workspace.json")))
        model.addProject(at: directory.url)
        let project = try #require(model.projects.first)
        return (model, project, directory)
    }

    /// The jump is answered off the main actor — the project has to be read
    /// first — so the test waits for it rather than assuming it has happened.
    private func settle(_ condition: () -> Bool) async {
        for _ in 0 ..< 200 where !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private func offset(of word: String, in text: String) throws -> Int {
        let range = (text as NSString).range(of: word)
        try #require(range.location != NSNotFound)
        return range.location + 1
    }

    @Test("A call reaches the file that declares it")
    func acrossFiles() async throws {
        let (model, project, directory) = try project([
            "main.go": "package main\n\nfunc main() {\n    Handle(\"x\")\n}\n",
            "handler.go": "package main\n\nfunc Handle(name string) {}\n",
        ])
        let caller = directory.url.appendingPathComponent("main.go").path
        let declarer = directory.url.appendingPathComponent("handler.go").path

        #expect(model.openFile(at: caller, in: project.id))
        let where_ = try offset(of: "Handle(\"x\")", in: try #require(model.editors[caller]).text)
        model.goToDefinition(at: where_, in: caller, projectID: project.id)

        await settle { model.editors[declarer]?.reveal != nil }

        let arrived = try #require(model.editors[declarer])
        let reveal = try #require(arrived.reveal)
        #expect((arrived.text as NSString).substring(with: reveal.range) == "Handle")
        #expect(PaneLayout.files(in: try #require(model.paneLayout(for: project.id))).contains(declarer))
        _ = directory
    }

    @Test("A name the file declares itself is answered by the file")
    func withinOneFile() async throws {
        let (model, project, directory) = try project([
            "main.go": "package main\n\nfunc helper() {}\n\nfunc main() {\n    helper()\n}\n",
        ])
        let path = directory.url.appendingPathComponent("main.go").path
        #expect(model.openFile(at: path, in: project.id))

        let text = try #require(model.editors[path]).text
        model.goToDefinition(at: try offset(of: "helper()\n}", in: text), in: path, projectID: project.id)
        await settle { model.editors[path]?.reveal != nil }

        let reveal = try #require(model.editors[path]?.reveal)
        #expect(reveal.range.location == (text as NSString).range(of: "helper").location)
        _ = directory
    }

    @Test("Two files declaring one name is still one jump")
    func ambiguous() async throws {
        // The index knows names, not types, so a popular name comes back from
        // more than one place. Asking every time is exact and useless: it
        // goes to the likeliest and says, quietly, that there were others.
        let (model, project, directory) = try project([
            "main.go": "package main\n\nfunc main() {\n    Handle()\n}\n",
            "first.go": "package first\n\nfunc Handle() {}\n",
            "second.go": "package second\n\nfunc Handle() {}\n",
        ])
        let caller = directory.url.appendingPathComponent("main.go").path
        #expect(model.openFile(at: caller, in: project.id))

        let text = try #require(model.editors[caller]).text
        model.goToDefinition(at: try offset(of: "Handle()\n}", in: text), in: caller, projectID: project.id)
        await settle { model.definitionMatches.count > 1 }

        #expect(model.activeModal == nil)
        #expect(model.definitionMatches.count == 2)
        let arrived = try #require(model.definitionMatches.first)
        #expect(model.editors[arrived.path]?.reveal != nil)

        // The others are one press away rather than in the way.
        let toast = try #require(model.toasts.last)
        let show = try #require(toast.action)
        show.handler()
        #expect(model.activeModal == .definitions(projectID: project.id, name: "Handle"))

        let picked = try #require(model.definitionMatches.last)
        model.openDefinition(picked)
        #expect(model.activeModal == nil)
        #expect(model.editors[picked.path]?.reveal != nil)
        _ = directory
    }

    @Test("A component is the file that is named after it")
    func componentFile() async throws {
        // Nothing inside `UserCard.vue` declares `UserCard`; the file existing
        // is the declaration, and a tags query will never say so.
        let (model, project, directory) = try project([
            "App.vue": "<script setup>\nimport UserCard from './UserCard.vue'\n</script>\n",
            "UserCard.vue": "<script setup>\nconst id = ref('')\n</script>\n",
        ])
        let app = directory.url.appendingPathComponent("App.vue").path
        let card = directory.url.appendingPathComponent("UserCard.vue").path
        #expect(model.openFile(at: app, in: project.id))

        let text = try #require(model.editors[app]).text
        model.goToDefinition(at: try offset(of: "UserCard from", in: text), in: app, projectID: project.id)
        await settle { model.editors[card] != nil }

        #expect(model.editors[card] != nil)
        // The only toast allowed here is the one saying the project is being
        // read; "no definition found" would mean the file was not the answer.
        #expect(!model.toasts.contains { $0.message == "UserCard" })
        _ = directory
    }

    @Test("A framework's own name is found in the framework")
    func inDependencies() async throws {
        // `defineProps` is a compiler macro: nothing in the project declares
        // it, and it is not a file either. It is declared in the type
        // declarations of a package, which is the last place asked and the
        // only place it could be.
        let (model, project, directory) = try project([
            "App.vue": "<script setup>\nconst props = defineProps(['id'])\n</script>\n",
            "node_modules/@vue/runtime-core/package.json": #"{ "types": "dist/runtime-core.d.ts" }"#,
            "node_modules/@vue/runtime-core/dist/runtime-core.d.ts":
                "export declare function defineProps<T>(): T;\n",
        ])
        let app = directory.url.appendingPathComponent("App.vue").path
        let declaration = directory.url
            .appendingPathComponent("node_modules/@vue/runtime-core/dist/runtime-core.d.ts").path
        #expect(model.openFile(at: app, in: project.id))

        let text = try #require(model.editors[app]).text
        model.goToDefinition(at: try offset(of: "defineProps", in: text), in: app, projectID: project.id)
        await settle { model.editors[declaration] != nil }

        let opened = try #require(model.editors[declaration])
        let reveal = try #require(opened.reveal)
        #expect((opened.text as NSString).substring(with: reveal.range) == "defineProps")
        // Opened to be read: an edit here is undone by the next install,
        // without a word said about it.
        #expect(opened.isVendored)
        _ = directory
    }

    @Test("⌘W closes the file in front of you, not the session behind it")
    func closesTheFocusedPane() async throws {
        // It closed the selected session whatever was in front of it, so the
        // key every window on the machine closes things with took down the
        // agent in the pane next door.
        let (model, project, directory) = try project(["main.go": "package main\n"])
        let path = directory.url.appendingPathComponent("main.go").path
        #expect(model.openFile(at: path, in: project.id))
        #expect(model.editors.focused == path)

        model.closeFocusedPane()

        #expect(model.editors[path] == nil)
        #expect(model.paneLayout(for: project.id) == nil)
        _ = directory
    }

    @Test("A translation key opens the locale file that defines it")
    func translationKeys() async throws {
        let (model, project, directory) = try project([
            "app/app.vue": "<script setup>\nconst heading = t('common.seo.title');\n</script>\n",
            "i18n/locales/ru/common.json": "{\n    \"seo\": {\n        \"title\": \"Example\"\n    }\n}\n",
        ])
        let page = directory.url.appendingPathComponent("app/app.vue").path
        let locale = directory.url.appendingPathComponent("i18n/locales/ru/common.json").path
        #expect(model.openFile(at: page, in: project.id))

        let text = try #require(model.editors[page]).text
        model.goToDefinition(at: try offset(of: "seo.title", in: text) + 4, in: page, projectID: project.id)
        await settle { model.editors[locale] != nil }

        let opened = try #require(model.editors[locale])
        let reveal = try #require(opened.reveal)
        #expect((opened.text as NSString).substring(with: reveal.range) == "\"title\"")
        _ = directory
    }

    @Test("A ⌘-click on a plain string says nothing at all")
    func stringsAreQuiet() async throws {
        // There is nowhere for a definition of `theme_preference` to come
        // from: it is the text of a cookie's name, written where it is used.
        // Complaining about it is a complaint about the question.
        let (model, project, directory) = try project([
            "keys.ts": "export const KEYS = { platform: 'theme_preference' };\n",
        ])
        let path = directory.url.appendingPathComponent("keys.ts").path
        #expect(model.openFile(at: path, in: project.id))

        let text = try #require(model.editors[path]).text
        model.goToDefinition(at: try offset(of: "theme_preference", in: text), in: path, projectID: project.id)
        try? await Task.sleep(for: .milliseconds(400))

        #expect(model.toasts.isEmpty)
        #expect(model.activeModal == nil)
        _ = directory
    }

    @Test("And goes nowhere, however tempting the name looks")
    func stringsGoNowhere() async throws {
        // What this is for: a ⌘-click on `max` inside `value === 'max'`
        // jumped to a `const max` in another file, which has nothing to do
        // with it. Saying nothing about it was only half the answer.
        let (model, project, directory) = try project([
            "guard.ts": "export const isPlatform = (value: string) => value === 'telegram' || value === 'max';\n",
            "channel.ts": "export const max = { platform: 'max' };\n",
        ])
        let path = directory.url.appendingPathComponent("guard.ts").path
        let elsewhere = directory.url.appendingPathComponent("channel.ts").path
        #expect(model.openFile(at: path, in: project.id))

        let text = try #require(model.editors[path]).text
        let inString = (text as NSString).range(of: "'max'").location + 2
        model.goToDefinition(at: inString, in: path, projectID: project.id)
        try? await Task.sleep(for: .milliseconds(500))

        #expect(model.editors[elsewhere] == nil)
        #expect(model.editors.openPath == path)
        #expect(model.toasts.isEmpty)
        _ = directory
    }

    @Test("A name nothing declares says so and goes nowhere")
    func nothingDeclaresIt() async throws {
        let (model, project, directory) = try project([
            "main.go": "package main\n\nfunc main() {\n    missingThing()\n}\n",
        ])
        let path = directory.url.appendingPathComponent("main.go").path
        #expect(model.openFile(at: path, in: project.id))

        let text = try #require(model.editors[path]).text
        model.goToDefinition(at: try offset(of: "missingThing", in: text), in: path, projectID: project.id)
        await settle { model.toasts.contains { $0.message == "missingThing" } }

        // One toast rather than two: saying the project is being read and then
        // saying what came of it is one answer, given twice.
        #expect(model.toasts.count == 1)
        #expect(model.toasts.first?.message == "missingThing")
        #expect(model.activeModal == nil)
        #expect(model.editors[path]?.reveal == nil)
        _ = directory
    }

    @Test("Back returns to the name that was clicked")
    func back() async throws {
        let (model, project, directory) = try project([
            "main.go": "package main\n\nfunc main() {\n    Handle(\"x\")\n}\n",
            "handler.go": "package main\n\nfunc Handle(name string) {}\n",
        ])
        let caller = directory.url.appendingPathComponent("main.go").path
        let declarer = directory.url.appendingPathComponent("handler.go").path
        #expect(model.openFile(at: caller, in: project.id))

        let text = try #require(model.editors[caller]).text
        let clicked = (text as NSString).range(of: "Handle(\"x\")")
        model.goToDefinition(at: clicked.location + 1, in: caller, projectID: project.id)
        await settle { model.editors[declarer]?.reveal != nil }

        #expect(model.canGoBackToOrigin)
        model.goBackToOrigin()

        let returned = try #require(model.editors[caller]?.reveal)
        #expect(returned.range == NSRange(location: clicked.location, length: 6))
        #expect(!model.canGoBackToOrigin)
        _ = directory
    }

    @Test("Saving a file makes what it now declares findable")
    func savingReindexes() async throws {
        let (model, project, directory) = try project([
            "main.go": "package main\n\nfunc main() {}\n",
        ])
        let path = directory.url.appendingPathComponent("main.go").path
        #expect(model.openFile(at: path, in: project.id))
        await model.symbols.prepare(root: directory.url.path)
        #expect(model.symbols.definitions(named: "Added", in: directory.url.path).isEmpty)

        model.editors[path]?.text = "package main\n\nfunc Added() {}\n\nfunc main() {}\n"
        model.saveFocusedFile()
        // Saving asks the project's formatter first now, so it lands a turn
        // or two later than the keystroke that asked for it.
        await settle { !model.symbols.definitions(named: "Added", in: directory.url.path).isEmpty }

        #expect(model.symbols.definitions(named: "Added", in: directory.url.path).count == 1)
        _ = directory
    }
}
