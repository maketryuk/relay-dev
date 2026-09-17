import Foundation

/// One `Keyword value` line as a block spells it.
struct SSHDirective: Hashable, Sendable {
    /// Lower-cased, because OpenSSH does not care about the case and neither
    /// should anything comparing two of these.
    var keyword: String
    /// The keyword as the file writes it. A config that says `Hostname` is not
    /// wrong, and an editor that shows it back as `hostname` is correcting
    /// somebody's spelling for no reason.
    var spelling: String
    var value: String

    init(keyword: String, value: String, spelling: String? = nil) {
        self.keyword = keyword
        self.value = value
        self.spelling = spelling ?? keyword
    }
}

/// Where a host is written down.
///
/// Relay edits the block it found rather than regenerating the file, so it has
/// to remember which file that block came from and which lines it occupied.
struct SSHHostDefinition: Hashable, Sendable {
    var file: URL
    /// Zero-based and half-open: the `Host` line through the last directive
    /// belonging to it. Trailing blank lines and comments are left out, since a
    /// comment sitting above the next `Host` belongs to that one.
    var lines: Range<Int>
    /// Every alias the block names. Editing it touches all of them.
    var patterns: [String]
    /// What this block says, as opposed to what the host inherits from a
    /// wildcard block elsewhere in the file.
    var directives: [SSHDirective]
}

/// One connectable entry from the user's OpenSSH configuration.
struct SSHHost: Identifiable, Hashable, Sendable {
    var alias: String
    var hostName: String?
    var user: String?
    var port: Int?
    var identityFile: String?
    var proxyJump: String?
    var forwardAgent: Bool?
    /// The blocks naming this alias outright, in file order. Usually one; more
    /// than one is legal, and OpenSSH reads them all, so Relay has to as well.
    var definitions: [SSHHostDefinition] = []

    var id: String { alias }

    /// `user@host:port`, omitting whatever the config did not specify.
    var displayTarget: String {
        let host = hostName ?? alias
        var target = host
        if let user { target = "\(user)@\(host)" }
        if let port, port != 22 { target += ":\(port)" }
        return target
    }

}

/// Filesystem access used while parsing, injected so the parser can be tested
/// against fixtures instead of the developer's real `~/.ssh`.
protocol SSHConfigFileSystem: Sendable {
    func read(_ url: URL) -> String?
    /// Resolves an `Include` argument, which may be relative and may contain
    /// shell globs, into concrete files.
    func resolve(include pattern: String, relativeTo directory: URL) -> [URL]
}

struct DefaultSSHConfigFileSystem: SSHConfigFileSystem {
    func read(_ url: URL) -> String? {
        try? String(contentsOf: url, encoding: .utf8)
    }

    func resolve(include pattern: String, relativeTo directory: URL) -> [URL] {
        let expanded = NSString(string: pattern).expandingTildeInPath
        let absolute = expanded.hasPrefix("/")
            ? expanded
            : directory.appendingPathComponent(expanded).path

        guard absolute.contains("*") || absolute.contains("?") || absolute.contains("[") else {
            return FileManager.default.fileExists(atPath: absolute) ? [URL(fileURLWithPath: absolute)] : []
        }

        var result = glob_t()
        defer { globfree(&result) }
        guard glob(absolute, 0, nil, &result) == 0 else { return [] }
        return (0 ..< Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { URL(fileURLWithPath: String(cString: $0)) }
        }
    }
}

/// Reads `~/.ssh/config` the way OpenSSH does.
///
/// Relay never copies keys or passphrases: it only surfaces which hosts exist so
/// the user can open a normal `ssh` session through the daemon.
enum SSHConfigParser {
    private struct Block {
        var patterns: [String]
        /// Preserved in file order because OpenSSH takes the *first* value it
        /// obtains for each keyword, not the last.
        var settings: [SSHDirective]
        var file: URL
        var headerLine: Int
        /// The last line that is a directive of this block, so that a comment
        /// introducing the next host is not swallowed by the previous one.
        var endLine: Int

        var lines: Range<Int> { headerLine ..< endLine + 1 }
    }

    private static let maxIncludeDepth = 8

    static func parse(
        rootConfig url: URL,
        fileSystem: some SSHConfigFileSystem = DefaultSSHConfigFileSystem()
    ) -> [SSHHost] {
        guard let contents = fileSystem.read(url) else { return [] }
        var visited: Set<String> = [url.standardizedFileURL.path]
        let blocks = parseBlocks(
            contents: contents,
            file: url,
            directory: url.deletingLastPathComponent(),
            fileSystem: fileSystem,
            visited: &visited,
            depth: 0
        )
        return resolveHosts(from: blocks)
    }

    // MARK: - Tokenising

    private static func parseBlocks(
        contents: String,
        file: URL,
        directory: URL,
        fileSystem: some SSHConfigFileSystem,
        visited: inout Set<String>,
        depth: Int,
        followingIncludes: Bool = true
    ) -> [Block] {
        var blocks: [Block] = []
        var current: Block?

        let rawLines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, rawLine) in rawLines.enumerated() {
            guard let (keyword, value) = directive(in: String(rawLine)) else { continue }

            switch keyword.lowercased() {
            case "host":
                if let existing = current { blocks.append(existing) }
                current = Block(
                    patterns: patterns(in: value),
                    settings: [],
                    file: file,
                    headerLine: index,
                    endLine: index
                )

            case "match":
                // Match blocks are conditional on runtime state Relay cannot
                // evaluate; ending the current block is the safe reading.
                if let existing = current { blocks.append(existing) }
                current = nil

            case "include":
                guard followingIncludes, depth < maxIncludeDepth else { continue }
                for pattern in patterns(in: value) {
                    for included in fileSystem.resolve(include: pattern, relativeTo: directory) {
                        let key = included.standardizedFileURL.path
                        // Guard against a config that includes itself.
                        guard !visited.contains(key), let text = fileSystem.read(included) else { continue }
                        visited.insert(key)
                        let nested = parseBlocks(
                            contents: text,
                            file: included,
                            directory: included.deletingLastPathComponent(),
                            fileSystem: fileSystem,
                            visited: &visited,
                            depth: depth + 1
                        )
                        // An Include is expanded in place, so anything it defines
                        // is seen before the rest of the including file.
                        if let existing = current {
                            blocks.append(existing)
                            current = nil
                        }
                        blocks.append(contentsOf: nested)
                    }
                }

            default:
                current?.settings.append(
                    SSHDirective(keyword: keyword.lowercased(), value: value, spelling: keyword)
                )
                current?.endLine = index
            }
        }

        if let existing = current { blocks.append(existing) }
        return blocks
    }

    /// Splits `Keyword value`, `Keyword=value` and quoted forms.
    ///
    /// Returns the keyword as written, because the writer puts lines back the
    /// way it found them and a config that spells it `Hostname` is not wrong.
    static func directive(in line: String) -> (keyword: String, value: String)? {
        var text = line
        if let commentIndex = text.firstIndex(of: "#") {
            text = String(text[text.startIndex ..< commentIndex])
        }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let separators = CharacterSet(charactersIn: " \t=")
        guard let splitIndex = trimmed.unicodeScalars.firstIndex(where: { separators.contains($0) }) else {
            return nil
        }
        let keyword = String(trimmed[trimmed.startIndex ..< splitIndex])
        let remainder = trimmed[trimmed.index(after: splitIndex)...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t="))
        guard !keyword.isEmpty, !remainder.isEmpty else { return nil }
        return (keyword, unquote(remainder))
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }

    static func patterns(in value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { unquote(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// OpenSSH's `yes`/`no`, and nothing at all when the value is neither.
    static func flag(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "yes", "true": true
        case "no", "false": false
        default: nil
        }
    }

    /// Every block in one file, without following `Include` and without
    /// merging anything.
    ///
    /// Hosts are what the list needs; this is what editing needs when the block
    /// is not a host at all — `Host *`, where the defaults live.
    static func blocks(in contents: String, file: URL) -> [SSHHostDefinition] {
        var visited: Set<String> = []
        return parseBlocks(
            contents: contents,
            file: file,
            directory: file.deletingLastPathComponent(),
            fileSystem: DefaultSSHConfigFileSystem(),
            visited: &visited,
            depth: 0,
            followingIncludes: false
        ).map {
            SSHHostDefinition(file: $0.file, lines: $0.lines, patterns: $0.patterns, directives: $0.settings)
        }
    }

    /// Every block the configuration reaches, `Include` and all.
    ///
    /// For asking what the whole configuration already says, as opposed to
    /// `blocks(in:file:)`, which asks what one file says because one file is
    /// what gets edited.
    static func blocks(
        rootConfig url: URL,
        fileSystem: some SSHConfigFileSystem = DefaultSSHConfigFileSystem()
    ) -> [SSHHostDefinition] {
        guard let contents = fileSystem.read(url) else { return [] }
        var visited: Set<String> = [url.standardizedFileURL.path]
        return parseBlocks(
            contents: contents,
            file: url,
            directory: url.deletingLastPathComponent(),
            fileSystem: fileSystem,
            visited: &visited,
            depth: 0
        ).map {
            SSHHostDefinition(file: $0.file, lines: $0.lines, patterns: $0.patterns, directives: $0.settings)
        }
    }

    // MARK: - Resolution

    private static func resolveHosts(from blocks: [Block]) -> [SSHHost] {
        var aliases: [String] = []
        var seen: Set<String> = []

        for block in blocks {
            for pattern in block.patterns where isConcrete(pattern) {
                if seen.insert(pattern).inserted {
                    aliases.append(pattern)
                }
            }
        }

        return aliases.map { alias in
            var host = SSHHost(alias: alias)
            var assigned: Set<String> = []

            for block in blocks where block.patterns.contains(where: { matches(pattern: $0, alias: alias) }) {
                // OpenSSH keeps the first value obtained for each keyword, which
                // is why a `Host *` block at the bottom acts as a default.
                guard !block.patterns.contains(where: { isNegation($0, alias: alias) }) else { continue }
                for setting in block.settings where !assigned.contains(setting.keyword) {
                    assigned.insert(setting.keyword)
                    switch setting.keyword {
                    case "hostname": host.hostName = setting.value
                    case "user": host.user = setting.value
                    case "port": host.port = Int(setting.value)
                    case "identityfile": host.identityFile = setting.value
                    case "proxyjump": host.proxyJump = setting.value
                    case "forwardagent": host.forwardAgent = flag(setting.value)
                    default: break
                    }
                }
            }

            // Only a block that names the alias outright can be edited as this
            // host: rewriting `Host *` because one of the hosts it covers was
            // renamed would change every other host with it.
            host.definitions = blocks
                .filter { $0.patterns.contains(alias) }
                .map { block in
                    SSHHostDefinition(
                        file: block.file,
                        lines: block.lines,
                        patterns: block.patterns,
                        directives: block.settings
                    )
                }
            return host
        }
    }

    /// A pattern is a usable alias only if it names exactly one host.
    private static func isConcrete(_ pattern: String) -> Bool {
        !pattern.contains("*") && !pattern.contains("?") && !pattern.hasPrefix("!")
    }

    private static func isNegation(_ pattern: String, alias: String) -> Bool {
        pattern.hasPrefix("!") && matchesGlob(pattern: String(pattern.dropFirst()), value: alias)
    }

    private static func matches(pattern: String, alias: String) -> Bool {
        guard !pattern.hasPrefix("!") else { return false }
        return matchesGlob(pattern: pattern, value: alias)
    }

    /// OpenSSH pattern matching: `*` for any run, `?` for a single character.
    static func matchesGlob(pattern: String, value: String) -> Bool {
        let patternCharacters = Array(pattern)
        let valueCharacters = Array(value)
        var table = [[Bool]](
            repeating: [Bool](repeating: false, count: valueCharacters.count + 1),
            count: patternCharacters.count + 1
        )
        table[0][0] = true

        for patternIndex in 1 ... max(patternCharacters.count, 1) where patternIndex <= patternCharacters.count {
            table[patternIndex][0] = table[patternIndex - 1][0] && patternCharacters[patternIndex - 1] == "*"
        }

        guard !patternCharacters.isEmpty else { return valueCharacters.isEmpty }

        for patternIndex in 1 ... patternCharacters.count {
            for valueIndex in 1 ... max(valueCharacters.count, 1) where valueIndex <= valueCharacters.count {
                switch patternCharacters[patternIndex - 1] {
                case "*":
                    table[patternIndex][valueIndex] =
                        table[patternIndex - 1][valueIndex] || table[patternIndex][valueIndex - 1]
                case "?":
                    table[patternIndex][valueIndex] = table[patternIndex - 1][valueIndex - 1]
                default:
                    table[patternIndex][valueIndex] = table[patternIndex - 1][valueIndex - 1]
                        && patternCharacters[patternIndex - 1] == valueCharacters[valueIndex - 1]
                }
            }
        }
        return table[patternCharacters.count][valueCharacters.count]
    }
}

/// Which machine an SSH session is on.
///
/// Read back out of the command the session was started with, because that is
/// the only record of it: the name can be changed by hand, and the working
/// directory belongs to the Mac rather than to the far end.
enum SSHDestination {
    /// Only the exact shape Relay writes is read back.
    ///
    /// Anything else would have to be parsed, and `ssh` has two dozen options
    /// that take a value of their own — in `ssh -p 2222 host` the first thing
    /// that is not a flag is the port. A label that names the wrong machine is
    /// worse than no label, so an unfamiliar command simply has no answer.
    static func alias(inCommand command: [String]) -> String? {
        guard command.count == 2, command[0] == "ssh", !command[1].hasPrefix("-") else { return nil }
        return command[1]
    }
}

/// Splits the host list into pinned and unpinned parts.
///
/// Extracted from `AppModel` so the ordering rule — pinned hosts first, in the
/// order the user pinned them — can be tested without a live daemon.
enum SSHHostOrdering {
    static func split(
        hosts: [SSHHost],
        pinnedAliases: [String]
    ) -> (pinned: [SSHHost], others: [SSHHost]) {
        let byAlias = Dictionary(hosts.map { ($0.alias, $0) }, uniquingKeysWith: { first, _ in first })
        let pinned = pinnedAliases.compactMap { byAlias[$0] }
        let pinnedSet = Set(pinned.map(\.alias))
        return (pinned, hosts.filter { !pinnedSet.contains($0.alias) })
    }
}
