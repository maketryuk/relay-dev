import Foundation
import Testing

@testable import RelayAppKit

@Suite("Reading what a checker said")
struct DiagnosticParsingTests {
    @Test("ESLint's JSON, as it actually prints it")
    func eslint() throws {
        // Captured from the real thing: `eslint --format json --stdin`.
        let output = """
        [{"filePath":"/p/a.ts","messages":[\
        {"ruleId":"@stylistic/semi","severity":2,"message":"Missing semicolon.","line":1,"column":12,\
        "endLine":2,"endColumn":1},\
        {"ruleId":"@typescript-eslint/no-unused-vars","severity":1,\
        "message":"'a' is assigned a value but never used.","line":2,"column":7,"endLine":2,"endColumn":8}\
        ]}]
        """
        let found = DiagnosticParsing.eslint(output)

        #expect(found.count == 2)
        #expect(found.first?.severity == .error)
        #expect(found.first?.line == 1)
        #expect(found.first?.column == 12)
        #expect(found.first?.rule == "@stylistic/semi")
        // Severity 1 is a warning and 2 is an error, which is ESLint's own
        // numbering and nobody else's.
        #expect(found.last?.severity == .warning)
    }

    @Test("A file with nothing wrong with it")
    func eslintClean() {
        #expect(DiagnosticParsing.eslint(#"[{"filePath":"/p/a.ts","messages":[]}]"#).isEmpty)
        #expect(DiagnosticParsing.eslint("").isEmpty)
        #expect(DiagnosticParsing.eslint("not json at all").isEmpty)
    }

    @Test("oxlint's JSON, which is a different shape from ESLint's")
    func oxlint() throws {
        // Captured from the real thing: one list for the whole run, and the
        // place in a label's span rather than on the message.
        let output = """
        { "diagnostics": [{"message": "Variable 'a' is declared but never used.",\
        "code": "eslint(no-unused-vars)","severity": "warning","filename": "probe.ts",\
        "labels": [{"label": "'a' is declared here","span": {"offset": 6,"length": 1,"line": 1,"column": 7}}]}],
        "number_of_files": 1 }
        """
        let found = DiagnosticParsing.oxlint(output)

        #expect(found.count == 1)
        let first = try #require(found.first)
        #expect(first.line == 1)
        #expect(first.column == 7)
        #expect(first.severity == .warning)
        #expect(first.rule == "eslint(no-unused-vars)")
    }

    @Test("php -l, which says one thing and stops")
    func phpLint() throws {
        let output = """
        PHP Parse error:  syntax error, unexpected token "{", expecting variable in Standard input code on line 2

        Parse error: syntax error, unexpected token "{", expecting variable in Standard input code on line 2
        """
        let found = DiagnosticParsing.phpLint(output)

        #expect(found.count == 1)
        let first = try #require(found.first)
        #expect(first.line == 2)
        #expect(first.severity == .error)
        #expect(first.message == #"syntax error, unexpected token "{", expecting variable"#)
    }

    @Test("php -l on a file it is happy with")
    func phpClean() {
        #expect(DiagnosticParsing.phpLint("No syntax errors detected in Standard input code\n").isEmpty)
    }

    @Test("A compiler's line, which every compiler on this machine prints")
    func compiler() throws {
        let output = """
        /tmp/a.swift:2:15: error: expected initial value after '='
        2 |   let x: Int =
          |               `- error: expected initial value after '='
        /tmp/a.swift:4:1: warning: variable 'y' was never used
        """
        let found = DiagnosticParsing.compiler(output, path: "/tmp/a.swift")

        #expect(found.count == 2)
        #expect(found.first?.line == 2)
        #expect(found.first?.column == 15)
        #expect(found.first?.message == "expected initial value after '='")
        #expect(found.last?.severity == .warning)
    }

    @Test("The same line without a severity, which is how gofmt says it")
    func gofmt() throws {
        // Captured from the real thing. A tool that prints a place and a
        // complaint and no word for how bad it is means an error.
        let found = DiagnosticParsing.compiler(
            "probe.go:2:15: expected ';', found 'EOF'\n",
            path: "/tmp/probe.go"
        )

        #expect(found.count == 1)
        #expect(found.first?.line == 2)
        #expect(found.first?.column == 15)
        #expect(found.first?.severity == .error)
        #expect(found.first?.message == "expected ';', found 'EOF'")
    }

    @Test("And without a column, which is how ruby says it")
    func ruby() throws {
        let found = DiagnosticParsing.compiler(
            "probe.rb:1: syntax error, unexpected end-of-input\n",
            path: "/tmp/probe.rb"
        )

        #expect(found.count == 1)
        #expect(found.first?.line == 1)
        #expect(found.first?.column == 0)
        #expect(found.first?.severity == .error)
    }

    @Test("Shellcheck, whose note is a warning and whose code is a rule")
    func shellcheck() throws {
        let found = DiagnosticParsing.compiler(
            "probe.sh:2:6: note: Double quote to prevent globbing and word splitting. [SC2086]\n",
            path: "/tmp/probe.sh"
        )

        let first = try #require(found.first)
        #expect(first.severity == .warning)
        #expect(first.rule == "SC2086")
        #expect(first.message == "Double quote to prevent globbing and word splitting.")
    }

    @Test("Ruby saying nothing is wrong")
    func rubyClean() {
        #expect(DiagnosticParsing.compiler("Syntax OK\n", path: "/tmp/a.rb").isEmpty)
    }

    @Test("Python's traceback, which says the place in the middle of itself")
    func python() throws {
        let output = """
          File "probe.py", line 1
            def a(:
                  ^
        SyntaxError: invalid syntax
        """
        let found = DiagnosticParsing.pythonSyntax(output)

        #expect(found.count == 1)
        #expect(found.first?.line == 1)
        #expect(found.first?.message == "SyntaxError: invalid syntax")
        #expect(DiagnosticParsing.pythonSyntax("").isEmpty)
    }
}

@Suite("Where a problem is")
struct DiagnosticRangeTests {
    @Test("A line and a column become a range in the text")
    func ranges() throws {
        let text = "const a = 1\nconst bbb = 2\n"
        let diagnostic = Diagnostic(severity: .error, line: 2, column: 7, message: "unused")
        let range = try #require(diagnostic.range(in: text))

        // Without an end, what is underlined is the word: one character is
        // too small to see and the whole line says nothing about which part
        // of it is wrong.
        #expect((text as NSString).substring(with: range) == "bbb")
    }

    @Test("An end given is the end used")
    func explicitEnd() throws {
        let text = "const a = 1\n"
        let diagnostic = Diagnostic(
            severity: .warning,
            line: 1,
            column: 1,
            endLine: 1,
            endColumn: 6,
            message: "prefer let"
        )
        let range = try #require(diagnostic.range(in: text))

        #expect((text as NSString).substring(with: range) == "const")
    }

    @Test("A parser that gave up marks the line it gave up on")
    func syntaxErrors() throws {
        // The real thing: a string opened with one quote and closed with
        // another. ESLint reports it at the comma after the string —
        // `fatal: true`, column 24 — and one character there is a dot nobody
        // reads as a mark.
        let text = "link: [\n\t\t\ttype: 'image/x-icon\",\n]\n"
        let diagnostic = Diagnostic(
            severity: .error,
            line: 2,
            column: 24,
            message: "Parsing error: Unterminated string literal.",
            isSyntax: true
        )
        let range = try #require(diagnostic.range(in: text))

        // The line itself, without the indentation in front of it.
        #expect((text as NSString).substring(with: range) == "type: 'image/x-icon\",")
    }

    @Test("Punctuation is marked to the end of its line, a word only as a word")
    func wordsAndPunctuation() throws {
        // What is wrong with punctuation is never the punctuation on its own,
        // so the mark runs to the end of the line rather than under one comma.
        let text = "const value = compute(, 42);\n"

        let onPunctuation = Diagnostic(severity: .error, line: 1, column: 23, message: "unexpected")
        #expect((text as NSString).substring(with: try #require(onPunctuation.range(in: text))) == ", 42);")

        // A rule that names a variable still marks the variable.
        let onWord = Diagnostic(severity: .warning, line: 1, column: 7, message: "unused")
        #expect((text as NSString).substring(with: try #require(onWord.range(in: text))) == "value")
    }

    @Test("A complaint about blank space is shown on what the space follows")
    func blankSpace() throws {
        // The real numbers: ESLint's `vue/block-tag-newline` said 36:5 to
        // 39:1 about the two empty lines before `</script>`, which underlines
        // nothing at all and reads as a complaint with no place.
        let text = "useHead();\n}));\n\n\n</script>\n"
        let diagnostic = Diagnostic(
            severity: .error,
            line: 2,
            column: 5,
            endLine: 5,
            endColumn: 1,
            message: "Expected 1 line break before '</script>', but 3 line breaks found."
        )
        let range = try #require(diagnostic.range(in: text))

        #expect((text as NSString).substring(with: range) == "}));")
    }

    @Test("And on the first thing after it when there is nothing before")
    func blankSpaceAtTheTop() throws {
        let text = "\n\nimport a from 'b';\n"
        let diagnostic = Diagnostic(severity: .warning, line: 1, column: 1, endLine: 2, endColumn: 1, message: "")
        let range = try #require(diagnostic.range(in: text))

        #expect((text as NSString).substring(with: range) == "import")
    }

    @Test("A line the file does not have is nowhere")
    func outsideTheFile() {
        // A checker reading a buffer that has since been typed into says
        // things about lines that are no longer there.
        let diagnostic = Diagnostic(severity: .error, line: 99, column: 1, message: "gone")
        #expect(diagnostic.range(in: "one\ntwo\n") == nil)
    }
}

@Suite("Which checker a file gets")
struct FileCheckerChoiceTests {
    @Test("ESLint only when the project has its own")
    func eslintIsTheProjects() throws {
        // A linter installed beside Relay would be a second opinion nobody
        // asked for: a checkout is linted by the rules it carries.
        let directory = try TemporaryDirectory()
        let path = directory.url.appendingPathComponent("a.ts").path

        #expect(FileCheckers.checker(for: path, in: directory.url.path)?.name != "ESLint")

        let bin = directory.url.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let eslint = bin.appendingPathComponent("eslint")
        try "#!/bin/sh\nexit 0\n".write(to: eslint, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: eslint.path)

        let checker = try #require(FileCheckers.checker(for: path, in: directory.url.path))
        #expect(checker.name == "ESLint")
        #expect(checker.executable == eslint.path)
        // The real name goes with the buffer, or ESLint cannot tell which
        // config governs the file.
        #expect(checker.arguments.contains(path))
    }

    @Test("oxlint when the project has it and no ESLint")
    func oxlintIsUsed() throws {
        let directory = try TemporaryDirectory()
        let bin = directory.url.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let oxlint = bin.appendingPathComponent("oxlint")
        try "#!/bin/sh\nexit 0\n".write(to: oxlint, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: oxlint.path)

        let path = directory.url.appendingPathComponent("App.vue").path
        let checker = try #require(FileCheckers.checker(for: path, in: directory.url.path))
        #expect(checker.name == "oxlint")

        // And ESLint takes it back when the project has both: it is the one
        // the project's rules are written for.
        let eslint = bin.appendingPathComponent("eslint")
        try "#!/bin/sh\nexit 0\n".write(to: eslint, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: eslint.path)
        #expect(FileCheckers.checker(for: path, in: directory.url.path)?.name == "ESLint")
    }

    @Test("Vue and React files are ESLint's too")
    func frontEndExtensions() throws {
        let directory = try TemporaryDirectory()
        let bin = directory.url.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let eslint = bin.appendingPathComponent("eslint")
        try "#!/bin/sh\nexit 0\n".write(to: eslint, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: eslint.path)

        for name in ["App.vue", "Button.tsx", "store.ts", "main.js"] {
            let path = directory.url.appendingPathComponent(name).path
            #expect(FileCheckers.checker(for: path, in: directory.url.path)?.name == "ESLint")
        }
        // And a file no linter here claims gets none.
        let readme = directory.url.appendingPathComponent("README.md").path
        #expect(FileCheckers.checker(for: readme, in: directory.url.path) == nil)
    }

    @Test("The buffer is what is checked, not the file on disk")
    func checksTheBuffer() throws {
        // Everything else would report the problem that was fixed a keystroke
        // ago and stay quiet about the one just typed.
        let directory = try TemporaryDirectory()
        try directory.write("<?php\n$a = 1;\n", to: "a.php")
        let path = directory.url.appendingPathComponent("a.php").path

        guard let checker = FileCheckers.checker(for: path, in: directory.url.path) else { return }
        let found = FileCheck.run(
            checker,
            on: "<?php\nfunction a( {\n",
            path: path,
            root: directory.url.path
        )

        #expect(found.first?.line == 2)
        #expect(found.first?.severity == .error)
    }
}

@Suite("Correcting what can be corrected")
struct FileFixerTests {
    private func project(_ shim: String, named name: String) throws -> TemporaryDirectory {
        let directory = try TemporaryDirectory()
        let bin = directory.url.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let tool = bin.appendingPathComponent(name)
        try shim.write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return directory
    }

    @Test("ESLint's dry run gives back the corrected text and touches nothing")
    func eslintDryRun() throws {
        // The shape is the real one: `--fix-dry-run --format json` answers
        // with an `output` field, and only when it changed something.
        let shim = """
        #!/bin/sh
        cat > /dev/null
        printf '%s' '[{"filePath":"/p/a.ts","output":"const a = 1;\\n","messages":[]}]'
        """
        let directory = try project(shim, named: "eslint")
        let path = directory.url.appendingPathComponent("a.ts").path
        let fixer = try #require(FileCheckers.fixer(for: path, in: directory.url.path))

        #expect(fixer.name == "ESLint")
        #expect(fixer.arguments.contains("--fix-dry-run"))
        let fixed = FileCheck.fix(fixer, on: "const a = 1\n", path: path, root: directory.url.path)
        #expect(fixed?.text == "const a = 1;\n")
    }

    @Test("One run answers both questions")
    func fixAndCheckTogether() throws {
        // Asking ESLint to correct a file and then asking it what is still
        // wrong is two node processes for one question, and a node process on
        // a large project measured at most of a second.
        let json = #"[{"filePath":"/p/a.ts","output":"const a = 1;\n","messages":"#
            + #"[{"ruleId":"no-unused-vars","severity":1,"message":"unused","line":1,"column":7}]}]"#
        let shim = """
        #!/bin/sh
        cat > /dev/null
        printf '%s' '\(json)'
        """
        let directory = try project(shim, named: "eslint")
        let path = directory.url.appendingPathComponent("a.ts").path
        let fixer = try #require(FileCheckers.fixer(for: path, in: directory.url.path))

        let fixed = try #require(FileCheck.fix(fixer, on: "const a = 1\n", path: path, root: directory.url.path))

        #expect(fixed.text == "const a = 1;\n")
        #expect(fixed.diagnostics?.count == 1)
        #expect(fixed.diagnostics?.first?.severity == .warning)
    }

    @Test("Nothing to correct is nothing done")
    func nothingToFix() throws {
        let shim = """
        #!/bin/sh
        cat > /dev/null
        printf '%s' '[{"filePath":"/p/a.ts","messages":[]}]'
        """
        let directory = try project(shim, named: "eslint")
        let path = directory.url.appendingPathComponent("a.ts").path
        let fixer = try #require(FileCheckers.fixer(for: path, in: directory.url.path))

        #expect(FileCheck.fix(fixer, on: "const a = 1;\n", path: path, root: directory.url.path)?.text == nil)
    }

    @Test("A formatter that prints its answer")
    func printedOutput() throws {
        // gofmt's shape: the buffer in, the formatted source out.
        let shim = """
        #!/bin/sh
        cat > /dev/null
        printf 'package main\\n'
        """
        let directory = try project(shim, named: "oxlint")
        // Borrowing the shim for the shape rather than the tool: what is
        // under test is reading what a fixer printed.
        let fixer = FileFixer(
            name: "probe",
            executable: directory.url.appendingPathComponent("node_modules/.bin/oxlint").path,
            arguments: [],
            input: .standardInput,
            result: .standardOutput
        )

        #expect(
            FileCheck.fix(fixer, on: "package  main\n", path: "/p/a.go", root: directory.url.path)?.text
                == "package main\n"
        )
    }

    @Test("A tool that rewrites the file it was given")
    func rewrittenFile() throws {
        let directory = try TemporaryDirectory()
        let tool = directory.url.appendingPathComponent("fixer.sh")
        try "#!/bin/sh\nprintf 'fixed\\n' > \"$1\"\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let fixer = FileFixer(
            name: "probe",
            executable: tool.path,
            arguments: ["%@"],
            input: .temporaryFile,
            result: .rewrittenFile
        )

        #expect(FileCheck.fix(fixer, on: "raw\n", path: "/p/a.php", root: directory.url.path)?.text == "fixed\n")
    }

    @Test("A file no tool here corrects is left alone")
    func noFixer() throws {
        let directory = try TemporaryDirectory()
        let path = directory.url.appendingPathComponent("README.md").path

        #expect(FileCheckers.fixer(for: path, in: directory.url.path) == nil)
    }
}

@Suite("Saving corrects the file")
@MainActor
struct FixOnSaveTests {
    @Test("⌘S runs the project's fixer and writes the result once")
    func fixesOnSave() async throws {
        let directory = try TemporaryDirectory()
        try directory.write("const a = 1\n", to: "a.ts")
        let bin = directory.url.appendingPathComponent("node_modules/.bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let eslint = bin.appendingPathComponent("eslint")
        try """
        #!/bin/sh
        cat > /dev/null
        printf '%s' '[{"filePath":"/p/a.ts","output":"const a = 1;\\n","messages":[]}]'
        """.write(to: eslint, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: eslint.path)

        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        model.addProject(at: directory.url)
        let project = try #require(model.projects.first)
        let path = directory.url.appendingPathComponent("a.ts").path
        #expect(model.openFile(at: path, in: project.id))

        model.saveFocusedFile()
        // Written before the formatter is even asked: ⌘S is not a wait.
        #expect(model.editors[path]?.isModified == false)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "const a = 1\n")

        for _ in 0 ..< 100 where model.editors[path]?.text != "const a = 1;\n" {
            try? await Task.sleep(for: .milliseconds(20))
        }

        // The buffer holds what the tool gave back, and the disk holds the
        // same thing: one save, one change to the file.
        #expect(model.editors[path]?.text == "const a = 1;\n")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "const a = 1;\n")
        #expect(model.editors[path]?.isModified == false)
        // And what it said about the corrected text came from the same run:
        // there is no second one to wait for.
        #expect(model.checkerName == "ESLint")
        _ = directory
    }

    @Test("A file from a dependency is saved without being corrected")
    func vendoredFilesAreLeftAlone() throws {
        // It is read-only in the first place, and rewriting somebody else's
        // package with this project's rules is the last thing to do to it.
        let directory = try TemporaryDirectory()
        try directory.write("const a = 1\n", to: "node_modules/pkg/index.d.ts")
        let store = try TemporaryDirectory()
        let model = AppModel(store: WorkspaceStore(url: store.url.appendingPathComponent("workspace.json")))
        model.addProject(at: directory.url)
        let project = try #require(model.projects.first)
        let path = directory.url.appendingPathComponent("node_modules/pkg/index.d.ts").path
        #expect(model.openFile(at: path, in: project.id))

        model.saveFocusedFile()

        #expect(model.editors[path]?.isVendored == true)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "const a = 1\n")
        _ = directory
    }
}

@Suite("A run nobody is waiting for")
struct RunningProcessTests {
    @Test("A checker whose answer stopped being wanted is stopped too")
    func cancelling() throws {
        // Typing starts a run every time the hand pauses, and each one is a
        // node process: the ones whose text has already been typed past have
        // to go, or they compete with the one that matters.
        let directory = try TemporaryDirectory()
        let tool = directory.url.appendingPathComponent("slow.sh")
        try "#!/bin/sh\nsleep 30\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let checker = FileChecker(
            name: "slow",
            executable: tool.path,
            arguments: [],
            input: .standardInput,
            format: .compiler
        )
        let running = RunningProcess()

        // A checker is run in the PATH a terminal would have, which is asked
        // of an interactive login shell once and kept. That shell is most of a
        // second on a machine with a configured one and was eleven on a cold
        // CI runner, all of it inside the run being timed here — so the test
        // failed for how long somebody's `.zshrc` takes. Paid for before the
        // clock starts, the window holds what this test is about.
        _ = LoginPath.value

        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) { running.cancel() }
        _ = FileCheck.run(checker, on: "text\n", path: "/p/a.swift", root: directory.url.path, running: running)

        // It came back because it was killed, not because it finished.
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("A run cancelled before it starts never starts")
    func cancelledFirst() throws {
        let directory = try TemporaryDirectory()
        let marker = directory.url.appendingPathComponent("ran")
        let tool = directory.url.appendingPathComponent("touch.sh")
        try "#!/bin/sh\ntouch \"\(marker.path)\"\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let checker = FileChecker(
            name: "touch",
            executable: tool.path,
            arguments: [],
            input: .standardInput,
            format: .compiler
        )
        let running = RunningProcess()
        running.cancel()

        _ = FileCheck.run(checker, on: "", path: "/p/a.swift", root: directory.url.path, running: running)

        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}
