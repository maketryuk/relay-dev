import Foundation
import Testing

@testable import RelayAppKit

@Suite("Symbols a file declares")
struct SymbolTagsTests {
    private func definitions(_ source: String, path: String) -> [SymbolDefinition] {
        guard let language = SourceLanguage.detect(path: path, contents: source) else { return [] }
        return SymbolTags.definitions(in: source, language: language, path: path)
    }

    @Test("Go declares functions, methods and types")
    func go() {
        let found = definitions(
            """
            package main

            type Session struct {
                id string
            }

            func (s *Session) Close() error {
                return nil
            }

            func NewSession(id string) *Session {
                return &Session{id: id}
            }
            """,
            path: "/p/session.go"
        )

        #expect(found.contains { $0.name == "Session" && $0.kind == .type })
        #expect(found.contains { $0.name == "Close" && $0.kind == .method })
        #expect(found.contains { $0.name == "NewSession" && $0.kind == .function })
        // Calls are in the same query and are not declarations.
        #expect(!found.contains { $0.name == "nil" })
    }

    @Test("A definition carries the line a person would be told to look at")
    func lineNumbers() {
        let found = definitions(
            """
            package main

            func first() {}

            func second() {}
            """,
            path: "/p/lines.go"
        )

        #expect(found.first { $0.name == "first" }?.line == 3)
        #expect(found.first { $0.name == "second" }?.line == 5)
    }

    @Test("The range is the name itself, not the declaration around it")
    func rangeIsTheName() throws {
        let source = "package main\n\nfunc handle() {}\n"
        let found = definitions(source, path: "/p/range.go")
        let handle = try #require(found.first { $0.name == "handle" })
        #expect((source as NSString).substring(with: handle.range) == "handle")
    }

    @Test("PHP declares classes and the methods in them")
    func php() {
        let found = definitions(
            """
            <?php

            namespace App\\Http;

            class UserController
            {
                public function store(Request $request)
                {
                    return $this->users->create($request->all());
                }
            }
            """,
            path: "/p/UserController.php"
        )

        #expect(found.contains { $0.name == "UserController" && $0.kind == .type })
        #expect(found.contains { $0.name == "store" })
    }

    @Test("TypeScript declares what JavaScript's own query finds")
    func typescript() {
        // TypeScript's tags file covers its types and leaves functions,
        // classes and methods to JavaScript's, which it names as its parent.
        // Read on its own it finds almost nothing in an ordinary module.
        let found = definitions(
            """
            export interface Session {
                id: string
            }

            export class Bus {
                publish(event: string) {}
            }

            export function connect(url: string) {
                return new Bus()
            }
            """,
            path: "/p/bus.ts"
        )

        #expect(found.contains { $0.name == "Bus" })
        #expect(found.contains { $0.name == "connect" })
        #expect(found.contains { $0.name == "publish" })
    }

    @Test("Swift declares its own")
    func swift() {
        let found = definitions(
            """
            struct PaneLayout {
                func showing(_ item: String) -> String { item }
            }

            func focusNextPane() {}
            """,
            path: "/p/PaneLayout.swift"
        )

        #expect(found.contains { $0.name == "PaneLayout" })
        #expect(found.contains { $0.name == "focusNextPane" })
    }

    @Test("What a module binds is declared, not only what it defines")
    func modernTypeScript() {
        // The grammars' own queries list functions, classes and methods — a
        // table of contents. Half of a TypeScript codebase is none of those:
        // a store is a `const` holding a call, a type is an alias, and both
        // are things people go to far more often than they go to a class.
        let found = definitions(
            """
            export interface User { id: string }

            export type Role = 'admin' | 'user'

            export enum Status { Active, Gone }

            export const useUserStore = defineStore('user', () => {})

            export const MAX_USERS = 100

            const { translate } = useI18n()
            """,
            path: "/p/store.ts"
        )
        let names = Set(found.map(\.name))

        #expect(names.isSuperset(of: ["User", "Role", "Status", "useUserStore", "MAX_USERS", "translate"]))
    }

    @Test("What a module's own factory declares")
    func factoryMembers() {
        // A Pinia store is everything a Vue project is made of, and all of it
        // is a `const` inside a function that is an argument of a call: not
        // the top level of the file, and not a local of anybody's either.
        // A ⌘-click on one used to answer that nothing declares it.
        let found = definitions(
            """
            export const useSettingsStore = defineStore('platform', () => {
                const preferredTheme = useCookie('theme', { default: () => null });
                const isSwitching = computed(() => count.value > 0);

                function reset() {}

                return { preferredTheme, isSwitching, reset };
            });

            export const useThing = () => {
                const inside = ref(0);
                return { inside };
            };
            """,
            path: "/p/useSettingsStore.ts"
        )
        let names = Set(found.map(\.name))

        #expect(names.isSuperset(of: ["useSettingsStore", "preferredTheme", "isSwitching", "reset", "inside"]))
        // A member of what the module exports, not a function of its own.
        #expect(found.first { $0.name == "preferredTheme" }?.kind == .property)
    }

    @Test("One declaration is one candidate, whatever caught it")
    func oneDeclarationOnce() {
        // `const handler = () => {}` answers both the grammar's own pattern
        // for a function and ours for a binding. Counted twice it becomes a
        // panel asking which of two identical places was meant.
        let found = definitions("const handler = () => {}\n", path: "/p/one.js")

        #expect(found.filter { $0.name == "handler" }.count == 1)
    }

    @Test("A class constant and an enum are declarations in PHP")
    func phpConstants() {
        let found = definitions(
            """
            <?php

            class Limits
            {
                public const MAX = 10;
            }

            enum Status: string { case Active = 'active'; }
            """,
            path: "/p/Limits.php"
        )
        let names = Set(found.map(\.name))

        #expect(names.isSuperset(of: ["Limits", "MAX", "Status", "Active"]))
    }

    @Test("A component written in TypeScript is read as TypeScript")
    func typedComponent() {
        // The HTML grammar names every script JavaScript. Read that way, a
        // type argument turns into a chain of comparisons and takes the
        // declarations on either side of it with it — which showed up as an
        // index that missed things for no reason anybody could see.
        let found = definitions(
            """
            <script setup lang="ts">
            const props = defineProps<{ id: string }>()
            const model = defineModel<string>()
            const count = ref(0)
            </script>
            """,
            path: "/p/Typed.vue"
        )
        let names = Set(found.map(\.name))

        #expect(names.isSuperset(of: ["props", "model", "count"]))
    }

    @Test("A single-file component declares what the script inside it declares")
    func vue() throws {
        // `.vue` has no grammar anywhere and is read as the page it is: the
        // names are all inside its `script`, which the HTML grammar points at.
        // Read as the host alone the file comes back with nothing in it.
        let source = """
        <script setup>
        import { ref } from 'vue'

        const model = defineModel()

        function submit() {
            model.value = ''
        }
        </script>

        <template>
          <button @click="submit">Go</button>
        </template>
        """
        let found = definitions(source, path: "/p/Editor.vue")
        let submit = try #require(found.first { $0.name == "submit" })

        #expect(submit.kind == .function)
        // Counted in the file rather than in the script inside it.
        #expect(submit.line == 6)
        #expect((source as NSString).substring(with: submit.range) == "submit")
    }

    @Test("A language whose grammar has no tags file declares nothing")
    func withoutTags() {
        // YAML has no tags query, and the answer to that is an empty list
        // rather than a guess made with a regular expression.
        #expect(definitions("services:\n  web:\n    image: nginx\n", path: "/p/compose.yaml").isEmpty)
    }
}

@Suite("The word under the caret")
struct SymbolWordTests {
    @Test("The identifier the click landed in")
    func inside() throws {
        let text = "return handleRequest(payload)"
        let word = try #require(SymbolWord.identifier(in: text, at: 10))
        #expect(word.text == "handleRequest")
        #expect(word.range == NSRange(location: 7, length: 13))
    }

    @Test("A caret against either edge of a word still means that word")
    func edges() {
        let text = "let total = sum(a)"
        #expect(SymbolWord.identifier(in: text, at: 12)?.text == "sum")
        #expect(SymbolWord.identifier(in: text, at: 15)?.text == "sum")
    }

    @Test("Punctuation and empty space are not names")
    func notAWord() {
        #expect(SymbolWord.identifier(in: "a + b", at: 2) == nil)
        #expect(SymbolWord.identifier(in: "   ", at: 1) == nil)
        #expect(SymbolWord.identifier(in: "", at: 0) == nil)
    }

    @Test("A number is not something to look up")
    func numbers() {
        #expect(SymbolWord.identifier(in: "timeout = 3600", at: 12) == nil)
    }

    @Test("PHP's sigil is not part of the name it declares")
    func phpVariables() {
        // `$request` is declared as `request`, so the sigil has to be left out
        // of the word or nothing matches.
        #expect(SymbolWord.identifier(in: "$request->all()", at: 3)?.text == "request")
    }

    @Test("A name with non-ASCII before it is still found where it is")
    func offsets() throws {
        let text = "// счётчик\nfunc tick() {}"
        let word = try #require(SymbolWord.identifier(in: text, at: 16))
        #expect(word.text == "tick")
        #expect((text as NSString).substring(with: word.range) == "tick")
    }
}
