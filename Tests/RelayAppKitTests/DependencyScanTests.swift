import Foundation
import Testing

@testable import RelayAppKit

@Suite("Somebody else's code")
struct DependencyScanTests {
    @Test("A package is read as the declarations its manifest points at")
    func npmLayout() throws {
        let directory = try TemporaryDirectory()
        try directory.write(
            #"{ "name": "axios", "types": "dist/axios.d.ts" }"#,
            to: "node_modules/axios/package.json"
        )
        try directory.write("export declare function get(url: string): void;\n", to: "node_modules/axios/dist/axios.d.ts")

        let found = DependencyScan.declarations(under: directory.url.path)

        #expect(found.count == 1)
        #expect(found.first?.hasSuffix("dist/axios.d.ts") == true)
    }

    @Test("A package that names no types is read by its index")
    func indexFallback() throws {
        let directory = try TemporaryDirectory()
        try directory.write(#"{ "name": "tiny" }"#, to: "node_modules/tiny/package.json")
        try directory.write("export declare const answer: number;\n", to: "node_modules/tiny/index.d.ts")

        #expect(DependencyScan.declarations(under: directory.url.path).count == 1)
    }

    @Test("A pnpm store is read, links and leading dot and all")
    func pnpmLayout() throws {
        // pnpm puts a link at `node_modules/<name>` and the package itself
        // under `.pnpm`, which an ordinary walk misses twice over: once for
        // the dot and once for the link. A project installed this way had no
        // dependencies at all as far as this was concerned.
        let directory = try TemporaryDirectory()
        let store = "node_modules/.pnpm/@vue+runtime-core@3.5.39/node_modules/@vue/runtime-core"
        try directory.write(
            #"{ "name": "@vue/runtime-core", "types": "dist/runtime-core.d.ts" }"#,
            to: "\(store)/package.json"
        )
        try directory.write(
            "export declare function defineProps<T>(): T;\n",
            to: "\(store)/dist/runtime-core.d.ts"
        )

        let found = DependencyScan.declarations(under: directory.url.path)

        #expect(found.count == 1)
        #expect(found.first?.hasSuffix("runtime-core.d.ts") == true)
    }

    @Test("Composer packages are known by their file names")
    func composerClasses() throws {
        let directory = try TemporaryDirectory()
        try directory.write("<?php class Model {}\n", to: "vendor/laravel/framework/src/Model.php")
        try directory.write("<?php class ModelTest {}\n", to: "vendor/laravel/framework/tests/ModelTest.php")
        try directory.write("# not php\n", to: "vendor/laravel/framework/README.md")

        let found = DependencyScan.classFiles(under: directory.url.path).map { ($0 as NSString).lastPathComponent }

        #expect(found == ["Model.php"])
    }

    @Test("A generated file too big to be anybody's source is left alone")
    func generatedFiles() throws {
        // An autoload class map or an SDK's endpoint table written out as a
        // PHP array: megabytes of parsing for a file that declares nothing
        // anybody navigates to.
        let directory = try TemporaryDirectory()
        try directory.write("<?php class Small {}\n", to: "vendor/pkg/src/Small.php")
        try directory.write(
            "<?php return [" + String(repeating: "'key' => 'value',", count: 40_000) + "];\n",
            to: "vendor/pkg/src/Huge.php"
        )

        let found = DependencyScan.classFiles(under: directory.url.path).map { ($0 as NSString).lastPathComponent }

        #expect(found == ["Small.php"])
    }

    @Test("What counts as somebody else's")
    func belonging() {
        #expect(DependencyScan.isDependency("/p/node_modules/vue/dist/vue.d.ts"))
        #expect(DependencyScan.isDependency("/p/vendor/laravel/framework/src/Model.php"))
        #expect(!DependencyScan.isDependency("/p/src/components/Editor.vue"))
        // The word has to be a directory of its own, not part of a name.
        #expect(!DependencyScan.isDependency("/p/src/vendor-list.ts"))
    }
}
