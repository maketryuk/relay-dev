import Foundation
import Testing

@testable import RelayAppKit

@Suite("The PATH a terminal would have")
struct LoginPathTests {
    @Test("The answer is taken from the noise an interactive shell makes")
    func parsing() {
        // The bug this exists for: a GUI application is launched with
        // `/usr/bin:/bin:/usr/sbin:/sbin`, so `node_modules/.bin/eslint` —
        // whose first line is `#!/usr/bin/env node` — did not start at all,
        // and the linter looked switched off rather than broken.
        let output = """
        nvm is installed
        Welcome back!
        \(LoginPath.marker)/opt/homebrew/bin:/usr/bin:/bin
        """

        #expect(LoginPath.parse(output) == "/opt/homebrew/bin:/usr/bin:/bin")
        #expect(LoginPath.parse("no marker here\n") == nil)
        #expect(LoginPath.parse("\(LoginPath.marker)\n") == nil)
    }

    @Test("A tool is looked for in every place the PATH names")
    func findingATool() throws {
        let directory = try TemporaryDirectory()
        let bin = directory.url.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent("madeuptool")
        try "#!/bin/sh\nexit 0\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let path = "/nowhere:\(bin.path):/also/nowhere"

        #expect(LoginPath.tool(named: "madeuptool", in: path) == tool.path)
        #expect(LoginPath.tool(named: "notinstalled", in: path) == nil)
        // A file that is there but cannot be run is not a tool.
        let text = bin.appendingPathComponent("notexecutable")
        try "hello\n".write(to: text, atomically: true, encoding: .utf8)
        #expect(LoginPath.tool(named: "notexecutable", in: path) == nil)
    }
}
