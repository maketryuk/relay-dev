import Foundation

/// Something a checker objected to in a file.
struct Diagnostic: Identifiable, Hashable, Sendable {
    enum Severity: String, Hashable, Sendable {
        case warning
        case error
    }

    let severity: Severity
    /// 1-based, the way every compiler and every linter counts.
    let line: Int
    /// 1-based, and zero when the checker did not say.
    let column: Int
    let endLine: Int
    let endColumn: Int
    let message: String
    /// The rule that objected, when the checker names one.
    let rule: String?
    /// True when the file could not be read at all — a quote that does not
    /// close, a brace that does not match. There is no offending word in that
    /// case, only a line the parser gave up on, so the whole of it is marked.
    let isSyntax: Bool

    var id: String { "\(line):\(column):\(message)" }

    init(
        severity: Severity,
        line: Int,
        column: Int = 0,
        endLine: Int = 0,
        endColumn: Int = 0,
        message: String,
        rule: String? = nil,
        isSyntax: Bool = false
    ) {
        self.severity = severity
        self.line = line
        self.column = column
        self.endLine = endLine == 0 ? line : endLine
        self.endColumn = endColumn
        self.message = message
        self.rule = rule
        self.isSyntax = isSyntax
    }

    /// Where it is in the text, for drawing under it.
    ///
    /// A checker says line and column; a text view wants a range. What is
    /// underlined when the end is not given is the rest of the word — a
    /// single character is too small to see and the whole line says nothing
    /// about which part of it is wrong.
    func range(in text: String) -> NSRange? {
        let source = text as NSString
        guard let start = offset(ofLine: line, column: max(column, 1), in: source) else { return nil }

        // A parser that gave up says where it gave up, which is somewhere
        // after the thing that broke it: a string opened with one quote and
        // closed with another is reported at the comma that follows. One
        // character there is a dot nobody can read as a mark, so the line the
        // parser choked on is marked instead.
        if isSyntax { return content(ofLineAt: start, in: source) }

        if endColumn > 0, let end = offset(ofLine: endLine, column: endColumn, in: source), end > start {
            return visible(NSRange(location: start, length: min(end, source.length) - start), in: source)
        }

        let lineRange = source.lineRange(for: NSRange(location: start, length: 0))
        let stop = NSMaxRange(lineRange)

        // A word is marked as a word; anything else — a brace, a comma, a
        // quote — is marked to the end of its line, because what is wrong
        // with punctuation is never the punctuation on its own.
        guard start < stop, isWord(source.character(at: start)) else {
            return content(ofLineAt: start, in: source, from: start)
        }

        var end = start
        while end < stop, isWord(source.character(at: end)) { end += 1 }
        return visible(NSRange(location: start, length: max(end - start, 1)), in: source)
    }

    /// The line's own text, without the indentation in front of it or the
    /// break at the end.
    private func content(ofLineAt offset: Int, in source: NSString, from: Int? = nil) -> NSRange? {
        let lineRange = source.lineRange(for: NSRange(location: min(offset, max(source.length - 1, 0)), length: 0))
        var start = from ?? lineRange.location
        var end = NSMaxRange(lineRange)
        while start < end, isSpace(source.character(at: start)) { start += 1 }
        while end > start, isSpace(source.character(at: end - 1)) { end -= 1 }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    /// A range with something in it to draw under.
    ///
    /// Half of what a linter objects to is blank space: `vue/block-tag-newline`
    /// says "three line breaks before `</script>`" and hands back a range of
    /// two empty lines, which underlines nothing at all and reads as a
    /// complaint with no place. What it is about is the thing the space
    /// follows, so the mark moves back onto that.
    private func visible(_ range: NSRange, in source: NSString) -> NSRange {
        guard NSMaxRange(range) <= source.length else { return range }
        guard source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return range }

        var end = range.location
        while end > 0, isSpace(source.character(at: end - 1)) { end -= 1 }
        var start = end
        while start > 0, !isSpace(source.character(at: start - 1)) { start -= 1 }
        if start < end { return NSRange(location: start, length: end - start) }

        // Nothing before it — the file begins with the space it is about — so
        // the first thing after it is what gets the mark.
        var after = NSMaxRange(range)
        while after < source.length, isSpace(source.character(at: after)) { after += 1 }
        var stop = after
        while stop < source.length, !isSpace(source.character(at: stop)) { stop += 1 }
        return stop > after ? NSRange(location: after, length: stop - after) : range
    }

    private func isSpace(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private func offset(ofLine line: Int, column: Int, in source: NSString) -> Int? {
        guard line > 0 else { return nil }
        var start = 0
        var number = 1
        while number < line, start < source.length {
            let range = source.lineRange(for: NSRange(location: start, length: 0))
            let next = NSMaxRange(range)
            guard next > start else { return nil }
            start = next
            number += 1
        }
        guard number == line, start <= source.length else { return nil }
        let lineRange = source.lineRange(for: NSRange(location: min(start, max(source.length - 1, 0)), length: 0))
        return min(start + column - 1, max(NSMaxRange(lineRange) - 1, start))
    }

    private func isWord(_ character: unichar) -> Bool {
        guard let scalar = UnicodeScalar(character) else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
    }
}

/// A program that reads a file and says what is wrong with it.
///
/// The project's own, never one of ours: a checkout is linted by the rules it
/// carries — its `eslint`, its config, its plugins — and a linter installed
/// beside Relay would be a second opinion nobody asked for. Nothing is
/// installed and nothing is configured; if the tool is not there, the pane
/// simply says nothing.
struct FileChecker: Sendable {
    /// How the buffer reaches it. `stdin` where the tool supports it, because
    /// what is checked has to be what is on screen rather than what was last
    /// written to disk — and ESLint needs the real name even then, to find
    /// the config that governs that file.
    enum Input: Sendable {
        case standardInput
        case temporaryFile
    }

    enum Format: Sendable {
        case eslintJSON
        case oxlintJSON
        case ruffJSON
        case phpLint
        case pythonSyntax
        /// `file:line:column: severity: message`, and the three or four other
        /// shapes of the same line that tools of this family print.
        case compiler
    }

    let name: String
    let executable: String
    /// `%@` is where the file's path goes.
    let arguments: [String]
    let input: Input
    let format: Format
}

/// A program that corrects what it can of what it objected to.
///
/// The same tools, asked to write rather than to read. What comes back is
/// text: the buffer is set to it and then written out, so one save is one
/// change to the file and the undo stack keeps its meaning.
struct FileFixer: Sendable {
    /// Where the corrected text comes back.
    enum Result: Sendable {
        /// Printed, the way a formatter prints.
        case standardOutput
        /// In the `output` field of ESLint's JSON, which is there only when
        /// something was actually corrected.
        case eslintJSON
        /// Written over the file it was given, which is what a tool with no
        /// dry run does.
        case rewrittenFile
    }

    let name: String
    let executable: String
    let arguments: [String]
    let input: FileChecker.Input
    let result: Result
}

enum FileCheckers {
    /// What checks this file, if the project has it.
    static func checker(for path: String, in root: String) -> FileChecker? {
        let suffix = (path as NSString).pathExtension.lowercased()

        if eslintExtensions.contains(suffix) {
            // ESLint first where a project has both: it is the one the
            // project's rules are written for, and oxlint is usually the fast
            // pass added beside it rather than instead of it.
            // `eslint_d` first: the same ESLint with the node process kept
            // warm between runs, which is the whole of the difference between
            // a second and a fiftieth of one.
            if let eslint = tool("eslint_d", in: root) ?? tool("eslint", in: root) {
                return FileChecker(
                    name: (eslint as NSString).lastPathComponent == "eslint_d" ? "eslint_d" : "ESLint",
                    executable: eslint,
                    arguments: ["--format", "json", "--stdin", "--stdin-filename", path],
                    input: .standardInput,
                    format: .eslintJSON
                )
            }
            if let oxlint = tool("oxlint", in: root) {
                // No standard input: it is given the buffer as a file of its
                // own, and run from the project so that it finds the project's
                // `.oxlintrc.json`.
                return FileChecker(
                    name: "oxlint",
                    executable: oxlint,
                    arguments: ["-f", "json", "%@"],
                    input: .temporaryFile,
                    format: .oxlintJSON
                )
            }
        }

        if suffix == "php", let php = tool(named: "php") {
            // Syntax only: `php -l` is what every PHP install has, needs no
            // config and answers in milliseconds. PHPStan sees far more and
            // needs a project set up for it, which is the next step rather
            // than this one.
            return FileChecker(
                name: "php -l",
                executable: php,
                arguments: ["-l"],
                input: .standardInput,
                format: .phpLint
            )
        }

        if suffix == "go", let gofmt = FileCheckers.tool(named: "gofmt") {
            // Syntax only, and the one check every Go install already has.
            // `go vet` sees more and needs a package that builds, which a
            // file being typed into routinely is not.
            return FileChecker(
                name: "gofmt",
                executable: gofmt,
                arguments: ["-e", "%@"],
                input: .temporaryFile,
                format: .compiler
            )
        }

        if shellExtensions.contains(suffix), let shellcheck = FileCheckers.tool(named: "shellcheck") {
            return FileChecker(
                name: "shellcheck",
                executable: shellcheck,
                arguments: ["--format=gcc", "-"],
                input: .standardInput,
                format: .compiler
            )
        }

        if suffix == "rb", let ruby = FileCheckers.tool(named: "ruby") {
            return FileChecker(
                name: "ruby -c",
                executable: ruby,
                arguments: ["-c", "%@"],
                input: .temporaryFile,
                format: .compiler
            )
        }

        if suffix == "py" {
            if let ruff = ruff(in: root) {
                return FileChecker(
                    name: "Ruff",
                    executable: ruff,
                    arguments: ["check", "--output-format", "json", "--stdin-filename", path, "-"],
                    input: .standardInput,
                    format: .ruffJSON
                )
            }
            if let python = python(in: root) {
                // Syntax only, and every Python has it.
                return FileChecker(
                    name: "python",
                    executable: python,
                    arguments: ["-m", "py_compile", "%@"],
                    input: .temporaryFile,
                    format: .pythonSyntax
                )
            }
        }

        if suffix == "swift" {
            if let swiftlint = swiftlint(in: root) {
                return FileChecker(
                    name: "SwiftLint",
                    executable: swiftlint,
                    arguments: ["lint", "--quiet", "--use-stdin", "--reporter", "json"],
                    input: .standardInput,
                    format: .eslintJSON
                )
            }
            if let xcrun = tool(named: "xcrun") {
                // Parsing only, with no module around the file: it catches
                // what is not Swift at all, and says nothing about types.
                return FileChecker(
                    name: "swiftc",
                    executable: xcrun,
                    arguments: ["swiftc", "-parse", "%@"],
                    input: .temporaryFile,
                    format: .compiler
                )
            }
        }
        return nil
    }

    /// What corrects this file, if the project has it.
    static func fixer(for path: String, in root: String) -> FileFixer? {
        let suffix = (path as NSString).pathExtension.lowercased()

        if eslintExtensions.contains(suffix) {
            if let eslint = tool("eslint_d", in: root) ?? tool("eslint", in: root) {
                // A dry run, because what is wanted is the text rather than a
                // file written behind the editor's back: the buffer is set to
                // it and saved once.
                return FileFixer(
                    name: "ESLint",
                    executable: eslint,
                    arguments: ["--fix-dry-run", "--format", "json", "--stdin", "--stdin-filename", path],
                    input: .standardInput,
                    result: .eslintJSON
                )
            }
            if let oxlint = tool("oxlint", in: root) {
                return FileFixer(
                    name: "oxlint",
                    executable: oxlint,
                    arguments: ["--fix", "%@"],
                    input: .temporaryFile,
                    result: .rewrittenFile
                )
            }
        }

        if suffix == "go", let gofmt = tool(named: "gofmt") {
            return FileFixer(
                name: "gofmt",
                executable: gofmt,
                arguments: [],
                input: .standardInput,
                result: .standardOutput
            )
        }

        if suffix == "py", let ruff = ruff(in: root) {
            return FileFixer(
                name: "Ruff",
                executable: ruff,
                arguments: ["check", "--fix", "--quiet", "--stdin-filename", path, "-"],
                input: .standardInput,
                result: .standardOutput
            )
        }

        // `php -l` corrects nothing; Pint is what a Laravel project formats
        // with, and it is the project's own copy or nothing.
        if suffix == "php", let pint = composer("pint", in: root) {
            return FileFixer(
                name: "Pint",
                executable: pint,
                arguments: ["--quiet", "%@"],
                input: .temporaryFile,
                result: .rewrittenFile
            )
        }

        if suffix == "swift", let swiftlint = swiftlint(in: root) {
            return FileFixer(
                name: "SwiftLint",
                executable: swiftlint,
                arguments: ["--fix", "--quiet", "%@"],
                input: .temporaryFile,
                result: .rewrittenFile
            )
        }
        return nil
    }

    static let eslintExtensions: Set<String> = [
        "js", "jsx", "mjs", "cjs", "ts", "tsx", "mts", "cts", "vue", "svelte", "astro",
    ]
    static let shellExtensions: Set<String> = ["sh", "bash", "zsh", "ksh"]

    /// The project's own environment first, then the machine's: a checkout
    /// with a virtual environment is linted by what is in it.
    private static func ruff(in root: String) -> String? {
        for local in [".venv/bin/ruff", "venv/bin/ruff", "node_modules/.bin/ruff"] {
            let path = (root as NSString).appendingPathComponent(local)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return tool(named: "ruff")
    }

    private static func python(in root: String) -> String? {
        for local in [".venv/bin/python3", "venv/bin/python3"] {
            let path = (root as NSString).appendingPathComponent(local)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return tool(named: "python3")
    }

    /// The project's own, and only the project's.
    private static func tool(_ name: String, in root: String) -> String? {
        let path = (root as NSString).appendingPathComponent("node_modules/.bin/\(name)")
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static func composer(_ name: String, in root: String) -> String? {
        let path = (root as NSString).appendingPathComponent("vendor/bin/\(name)")
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    private static func swiftlint(in root: String) -> String? {
        let local = (root as NSString).appendingPathComponent("Pods/SwiftLint/swiftlint")
        if FileManager.default.isExecutableFile(atPath: local) { return local }
        return tool(named: "swiftlint")
    }

    /// Where a command-line tool is, as a terminal on this machine would
    /// find it rather than as an application launched from the Dock would.
    static func tool(named name: String) -> String? {
        LoginPath.tool(named: name)
    }
}

/// A process somebody may stop wanting the answer from.
///
/// A checker left running for text nobody is looking at any more is a node
/// process competing with the one that matters, and typing starts a new one
/// every time the hand pauses.
final class RunningProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    /// - Returns: false when the answer is already unwanted, in which case
    ///   the process is not started at all.
    func adopt(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        self.process = process
        return true
    }

    func cancel() {
        lock.lock()
        let running = process
        cancelled = true
        lock.unlock()
        running?.terminate()
    }
}

/// Running a checker over a buffer.
enum FileCheck {
    /// How long a checker is given before it is taken to be stuck. ESLint
    /// takes over a second from cold on a large project; ten is not a limit
    /// anything healthy reaches.
    static let patience: TimeInterval = 10

    /// What a fixer came back with.
    ///
    /// The diagnostics as well as the text, because ESLint answers both in
    /// one run: asking it to correct a file and then asking it what is still
    /// wrong is two node processes for one question, and a node process on a
    /// large project is most of a second.
    struct Fixed: Sendable {
        let text: String?
        let diagnostics: [Diagnostic]?
    }

    /// The corrected text, or nil when nothing was corrected.
    static func fix(_ fixer: FileFixer, on text: String, path: String, root: String) -> Fixed? {
        var arguments = fixer.arguments
        var temporary: URL?

        if case .temporaryFile = fixer.input {
            guard let url = write(text, extension: (path as NSString).pathExtension) else { return nil }
            temporary = url
            arguments = arguments.map { $0 == "%@" ? url.path : $0 }
        }
        defer { temporary.map { try? FileManager.default.removeItem(at: $0) } }

        guard let produced = output(of: fixer.executable, arguments: arguments, input: text, root: root)
        else { return nil }

        var fixed: String?
        var diagnostics: [Diagnostic]?

        switch fixer.result {
        case .standardOutput:
            fixed = produced.isEmpty ? nil : produced
        case .eslintJSON:
            fixed = eslintOutput(produced)
            // What it still objects to after correcting what it could.
            diagnostics = DiagnosticParsing.eslint(produced)
        case .rewrittenFile:
            fixed = temporary.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }

        // Nothing came back, or what came back is what went in.
        if let produced = fixed, produced.isEmpty || produced == text { fixed = nil }
        guard fixed != nil || diagnostics != nil else { return nil }
        return Fixed(text: fixed, diagnostics: diagnostics)
    }

    /// ESLint's `output`, which it includes only when it changed something.
    private static func eslintOutput(_ json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let files = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return files.compactMap { $0["output"] as? String }.first
    }

    private static func write(_ text: String, extension suffix: String) -> URL? {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-check-\(UUID().uuidString)")
            .appendingPathExtension(suffix)
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return url
    }

    /// Runs it, gives it the buffer and reads what it printed.
    private static func output(
        of executable: String,
        arguments: [String],
        input text: String,
        root: String
    ) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        process.environment = LoginPath.environment()

        let out = Pipe()
        let errors = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = errors
        process.standardInput = input

        do {
            try process.run()
        } catch {
            return nil
        }
        input.fileHandleForWriting.write(Data(text.utf8))
        try? input.fileHandleForWriting.close()

        let produced = out.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: produced, as: UTF8.self)
    }

    static func run(
        _ checker: FileChecker,
        on text: String,
        path: String,
        root: String,
        running: RunningProcess? = nil
    ) -> [Diagnostic] {
        var arguments = checker.arguments
        var temporary: URL?

        if case .temporaryFile = checker.input {
            let url = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("relay-check-\(UUID().uuidString)")
                .appendingPathExtension((path as NSString).pathExtension)
            guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil else { return [] }
            temporary = url
            arguments = arguments.map { $0 == "%@" ? url.path : $0 }
        }
        defer { temporary.map { try? FileManager.default.removeItem(at: $0) } }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: checker.executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: root)
        // Without this `node_modules/.bin/eslint` does not start: its first
        // line is `#!/usr/bin/env node`, and an application launched from the
        // Dock has no `node` on its `PATH`.
        process.environment = LoginPath.environment()

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let input = Pipe()
        if case .standardInput = checker.input {
            process.standardInput = input
        }

        if let running, !running.adopt(process) { return [] }
        do {
            try process.run()
        } catch {
            return []
        }

        if case .standardInput = checker.input {
            input.fileHandleForWriting.write(Data(text.utf8))
            try? input.fileHandleForWriting.close()
        }

        let produced = output.fileHandleForReading.readDataToEndOfFile()
        let complained = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(decoding: produced, as: UTF8.self)
        let stderr = String(decoding: complained, as: UTF8.self)

        switch checker.format {
        case .eslintJSON: return DiagnosticParsing.eslint(text)
        case .oxlintJSON: return DiagnosticParsing.oxlint(text)
        case .ruffJSON: return DiagnosticParsing.ruff(text)
        case .pythonSyntax: return DiagnosticParsing.pythonSyntax(text + "\n" + stderr)
        case .phpLint: return DiagnosticParsing.phpLint(text + "\n" + stderr)
        case .compiler: return DiagnosticParsing.compiler(text + "\n" + stderr, path: temporary?.path ?? path)
        }
    }
}

/// Reading what a checker said.
///
/// Pure, and tested against what each tool actually prints: the shape of that
/// output is the whole contract, and it is not one any of them documents.
enum DiagnosticParsing {
    /// ESLint's `--format json`, which SwiftLint's JSON reporter is close
    /// enough to be read by the same code.
    static func eslint(_ output: String) -> [Diagnostic] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data)
        else { return [] }

        // ESLint answers with a file per path; SwiftLint with a flat list.
        let entries: [[String: Any]]
        if let files = json as? [[String: Any]], files.first?["messages"] != nil {
            entries = files.flatMap { $0["messages"] as? [[String: Any]] ?? [] }
        } else if let flat = json as? [[String: Any]] {
            entries = flat
        } else {
            return []
        }
        return eslint(messages: entries)
    }

    /// The same, for a caller that already has the messages: the warm service
    /// answers in objects rather than in text.
    static func eslint(messages entries: [[String: Any]]) -> [Diagnostic] {
        entries.compactMap { entry in
            guard let line = number(entry["line"]),
                  let message = (entry["message"] as? String) ?? (entry["reason"] as? String)
            else { return nil }

            let severity = entry["severity"]
            let isError = (severity as? Int ?? 2) >= 2
                || (severity as? String)?.lowercased() == "error"

            return Diagnostic(
                severity: isError ? .error : .warning,
                line: line,
                column: number(entry["column"]) ?? 0,
                endLine: number(entry["endLine"]) ?? 0,
                endColumn: number(entry["endColumn"]) ?? 0,
                message: message,
                rule: (entry["ruleId"] as? String) ?? (entry["rule_id"] as? String),
                // ESLint's own word for "I could not parse this".
                isSyntax: entry["fatal"] as? Bool == true
            )
        }
    }

    /// JSON has one number type and these tools use both spellings of it.
    private static func number(_ value: Any?) -> Int? {
        if let found = value as? Int { return found }
        if let found = value as? Double { return Int(found) }
        return (value as? NSNumber)?.intValue
    }

    /// oxlint's JSON, which is a different shape from ESLint's: one list of
    /// diagnostics for the whole run, each carrying where it is in a label's
    /// span.
    ///
    /// The span's `length` is left alone. It is a count of bytes, and what a
    /// text view wants is a count of UTF-16 units; the word under the column
    /// is the same answer without the arithmetic to get wrong.
    static func oxlint(_ output: String) -> [Diagnostic] {
        guard let data = output.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["diagnostics"] as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard let message = entry["message"] as? String else { return nil }
            let labels = entry["labels"] as? [[String: Any]] ?? []
            let span = labels.compactMap { $0["span"] as? [String: Any] }.first
            guard let line = number(span?["line"]) else { return nil }

            let severity = (entry["severity"] as? String)?.lowercased()
            return Diagnostic(
                severity: severity == "error" ? .error : .warning,
                line: line,
                column: number(span?["column"]) ?? 0,
                message: message,
                rule: entry["code"] as? String
            )
        }
    }

    /// `PHP Parse error:  syntax error, … in Standard input code on line 2`
    static func phpLint(_ output: String) -> [Diagnostic] {
        for line in output.split(separator: "\n") {
            let text = String(line)
            guard text.contains("error") , let number = lineNumber(in: text) else { continue }

            var message = text
            if let range = message.range(of: " in ", options: .backwards) {
                message = String(message[message.startIndex ..< range.lowerBound])
            }
            message = message
                .replacingOccurrences(of: "PHP Parse error:", with: "")
                .replacingOccurrences(of: "Parse error:", with: "")
                .replacingOccurrences(of: "PHP Fatal error:", with: "")
                .trimmingCharacters(in: .whitespaces)

            // One at a time is all `php -l` ever reports: it stops at the
            // first thing it cannot parse.
            return [Diagnostic(severity: .error, line: number, message: message, isSyntax: true)]
        }
        return []
    }

    /// Ruff's `--output-format json`: a flat list, with the place in a
    /// `location`.
    ///
    /// The one entry here taken from a tool's documentation rather than from
    /// watching it run — Ruff is on none of the machines this was written on.
    /// A shape that turns out to be wrong shows nothing rather than the wrong
    /// thing, which is the failure to prefer.
    static func ruff(_ output: String) -> [Diagnostic] {
        guard let data = output.data(using: .utf8),
              let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            let location = entry["location"] as? [String: Any]
            guard let message = entry["message"] as? String, let line = number(location?["row"]) else { return nil }
            return Diagnostic(
                severity: .warning,
                line: line,
                column: number(location?["column"]) ?? 0,
                message: message,
                rule: entry["code"] as? String
            )
        }
    }

    /// What `py_compile` prints, which is a traceback with the place in the
    /// middle of it.
    static func pythonSyntax(_ output: String) -> [Diagnostic] {
        let lines = output.split(separator: "\n").map(String.init)
        guard let place = lines.last(where: { $0.contains("File \"") && $0.contains(", line ") }),
              let range = place.range(of: ", line "),
              let number = Int(place[range.upperBound...].prefix { $0.isNumber })
        else { return [] }

        let message = lines.last { $0.contains("Error: ") } ?? "Syntax error"
        return [Diagnostic(
            severity: .error,
            line: number,
            message: message.trimmingCharacters(in: .whitespaces),
            isSyntax: true
        )]
    }

    /// The line a compiler prints, in the four shapes of it that exist:
    /// with a column and without, with a severity and without.
    ///
    /// `gofmt` says `file:2:15: expected ';'`, `ruby -c` says
    /// `file:1: syntax error, …`, `shellcheck` says
    /// `file:2:6: note: … [SC2086]`, and `swiftc` says
    /// `file:2:15: error: …`. A line with no severity in it is an error: a
    /// tool that prints a place and a complaint is not making conversation.
    static func compiler(_ output: String, path: String) -> [Diagnostic] {
        let pattern = "^[^:]+:(\\d+)(?::(\\d+))?:\\s*(?:(error|warning|note|fatal error)\\s*:\\s*)?(.+)$"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        else { return [] }

        var found: [Diagnostic] = []
        var seen = Set<String>()
        let source = output as NSString

        expression.enumerateMatches(in: output, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match, let line = Int(source.substring(with: match.range(at: 1))) else { return }

            let column = match.range(at: 2).location == NSNotFound
                ? 0
                : Int(source.substring(with: match.range(at: 2))) ?? 0
            let kind = match.range(at: 3).location == NSNotFound
                ? "error"
                : source.substring(with: match.range(at: 3))
            var message = source.substring(with: match.range(at: 4)).trimmingCharacters(in: .whitespaces)

            // `[SC2086]` at the end is shellcheck naming the rule.
            var rule: String?
            if message.hasSuffix("]"), let opening = message.range(of: "[", options: .backwards) {
                rule = String(message[message.index(after: opening.lowerBound) ..< message.index(before: message.endIndex)])
                message = String(message[message.startIndex ..< opening.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
            }

            let diagnostic = Diagnostic(
                severity: kind == "error" || kind == "fatal error" ? .error : .warning,
                line: line,
                column: column,
                message: message,
                rule: rule
            )
            guard seen.insert(diagnostic.id).inserted else { return }
            found.append(diagnostic)
        }
        return found
    }

    private static func lineNumber(in text: String) -> Int? {
        guard let range = text.range(of: "on line ") else { return nil }
        let rest = text[range.upperBound...].prefix { $0.isNumber }
        return Int(rest)
    }
}
