import Foundation
import Testing

@testable import RelayAppKit

@Suite("ESLint kept warm")
@MainActor
struct LintServiceTests {
    /// A stand-in for node: it prints the handshake and then answers every
    /// request with the same canned reply, which is all the service's side of
    /// the conversation needs to be tested against.
    private func project(answering reply: String) throws -> (TemporaryDirectory, String) {
        let directory = try TemporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory.url.appendingPathComponent("node_modules/eslint"),
            withIntermediateDirectories: true
        )
        let node = directory.url.appendingPathComponent("node.sh")
        // The requests are numbered from one and answered in order, so the
        // shim counts along with them: an answer to a question nobody asked
        // is an answer nobody is waiting for.
        try """
        #!/bin/sh
        printf '%s\\n' '{"ready":true}'
        id=0
        while IFS= read -r line; do
          id=$((id+1))
          printf '{"id":%s,%s\\n' "$id" '\(reply)'
        done
        """.write(to: node, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
        return (directory, node.path)
    }

    @Test("It answers, and goes on answering without starting again")
    func answers() async throws {
        let reply = #""output":"fixed\n","messages":"#
            + #"[{"ruleId":"semi","severity":2,"message":"Missing semicolon.","line":1,"column":5}]}"#
        let (directory, node) = try project(answering: reply)
        let service = LintService(node: node)
        defer { service.stopAll() }

        let path = directory.url.appendingPathComponent("a.ts").path
        let first = await service.answer(for: "const a = 1\n", path: path, root: directory.url.path, fix: true)

        #expect(first?.text == "fixed\n")
        #expect(first?.diagnostics?.count == 1)
        #expect(first?.diagnostics?.first?.severity == .error)

        // A second question asked of the same process, which is the whole
        // point of keeping it.
        let second = await service.answer(for: "const b = 2\n", path: path, root: directory.url.path, fix: false)
        #expect(second != nil)
    }

    @Test("A project with no ESLint of its own is not served")
    func withoutESLint() throws {
        let directory = try TemporaryDirectory()
        let service = LintService(node: "/bin/sh")

        #expect(!service.supports(path: directory.url.appendingPathComponent("a.ts").path, in: directory.url.path))
    }

    @Test("A file no linter claims is not served either")
    func otherLanguages() throws {
        let (directory, node) = try project(answering: "{}")
        let service = LintService(node: node)

        #expect(!service.supports(path: directory.url.appendingPathComponent("a.php").path, in: directory.url.path))
        #expect(service.supports(path: directory.url.appendingPathComponent("a.vue").path, in: directory.url.path))
    }

    @Test("A service that cannot start says so once rather than on every keystroke")
    func refusesQuietly() async throws {
        let directory = try TemporaryDirectory()
        try FileManager.default.createDirectory(
            at: directory.url.appendingPathComponent("node_modules/eslint"),
            withIntermediateDirectories: true
        )
        let service = LintService(node: "/definitely/not/here")
        let path = directory.url.appendingPathComponent("a.ts").path

        #expect(await service.answer(for: "", path: path, root: directory.url.path, fix: false) == nil)
        // And having failed, it stops offering: a broken config must not
        // start a node process for every letter typed.
        #expect(!service.supports(path: path, in: directory.url.path))
    }
}
