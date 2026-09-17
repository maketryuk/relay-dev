import Foundation

/// Writes to the user's own OpenSSH configuration.
///
/// Relay edits the file `ssh` reads rather than keeping a list beside it, so a
/// host added here is a host every terminal on the machine can reach. That is
/// also why nothing below rewrites a whole file: it patches the lines it was
/// given and leaves the rest of somebody's config exactly as it was.
enum SSHConfigStore {
    enum Failure: Error {
        case unreadable(URL)
        case unwritable(URL, String)

        var path: String {
            switch self {
            case let .unreadable(url), let .unwritable(url, _): url.path
            }
        }

        var reason: String? {
            switch self {
            case .unreadable: nil
            case let .unwritable(_, reason): reason
            }
        }
    }

    /// Where a host with nowhere else to go is written.
    static var rootConfig: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config", isDirectory: false)
    }

    /// The two settings that make a passphrase be asked for once rather than
    /// every time.
    ///
    /// `AddKeysToAgent` puts a key into the agent after it has been used, and
    /// `UseKeychain` — Apple's addition — lets ssh take the passphrase from the
    /// login keychain instead of asking for it. Neither stores anything in
    /// Relay: macOS already has somewhere better to keep a secret.
    static let keychainDefaults = [
        SSHDirective(keyword: "addkeystoagent", value: "yes", spelling: "AddKeysToAgent"),
        SSHDirective(keyword: "usekeychain", value: "yes", spelling: "UseKeychain"),
    ]

    /// Whether the defaults are already set for every host, so nothing is
    /// offered that has already been done.
    ///
    /// Asked of the whole configuration rather than of one file: a machine that
    /// keeps its defaults in an included file has them set, and offering to add
    /// them again would write a second `Host *` that says the same thing.
    static func hasKeychainDefaults(rootConfig url: URL? = nil) -> Bool {
        let blocks = SSHConfigParser.blocks(rootConfig: resolved(url ?? rootConfig))
        let present = Set(
            blocks
                .filter { $0.patterns.contains("*") }
                .flatMap { $0.directives }
                .filter { SSHConfigParser.flag($0.value) == true }
                .map(\.keyword)
        )
        return keychainDefaults.allSatisfy { present.contains($0.keyword) }
    }

    /// Puts the defaults into `Host *`, creating the block when there is none.
    static func enableKeychainDefaults(in configURL: URL? = nil) throws {
        let url = resolved(configURL ?? rootConfig)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        let updated: String
        if let wildcard = wildcardBlock(in: text, file: url) {
            updated = SSHConfigWriter.ensuring(keychainDefaults, inBlockAt: wildcard.lines, of: text)
        } else {
            // At the end of the file, which is where a default belongs: OpenSSH
            // keeps the first value it obtains, so a block above would override
            // what a specific host says rather than fall back to it.
            var draft = SSHHostDraft()
            draft.alias = "*"
            draft.extraDirectives = keychainDefaults
                .map { "\($0.spelling) \($0.value)" }
                .joined(separator: "\n")
            updated = SSHConfigWriter.appending(draft, to: text)
        }

        guard updated != text else { return }
        try write(updated, to: url)
    }

    private static func wildcardBlock(in text: String, file: URL) -> SSHHostDefinition? {
        SSHConfigParser.blocks(in: text, file: file).first { $0.patterns == ["*"] }
    }

    static func add(_ draft: SSHHostDraft, to configURL: URL? = nil) throws {
        let url = resolved(configURL ?? rootConfig)
        // A first host is a reason for the file to exist, not a reason to fail.
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try write(SSHConfigWriter.appending(draft, to: text), to: url)
    }

    static func update(_ draft: SSHHostDraft, at definition: SSHHostDefinition, previousAlias: String) throws {
        let url = resolved(definition.file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.unreadable(url) }
        try write(
            SSHConfigWriter.replacing(
                lines: definition.lines,
                in: text,
                with: draft,
                previousAlias: previousAlias
            ),
            to: url
        )
    }

    /// Removes every block naming the alias, since OpenSSH reads them all and
    /// leaving one behind means the host comes back on the next reload.
    static func remove(alias: String, from definitions: [SSHHostDefinition]) throws {
        let byFile = Dictionary(grouping: definitions) { resolved($0.file) }
        for (url, group) in byFile {
            guard var text = try? String(contentsOf: url, encoding: .utf8) else { throw Failure.unreadable(url) }
            // Last block first, so the line numbers of the earlier ones are
            // still the line numbers they were parsed at.
            for definition in group.sorted(by: { $0.lines.lowerBound > $1.lines.lowerBound }) {
                text = SSHConfigWriter.removing(alias: alias, atLines: definition.lines, from: text)
            }
            try write(text, to: url)
        }
    }

    // MARK: - Files

    /// An atomic write replaces the file, so a `~/.ssh/config` that is a symlink
    /// into a dotfiles repository would become a plain file and quietly stop
    /// being the one under version control.
    private static func resolved(_ url: URL) -> URL {
        url.resolvingSymlinksInPath()
    }

    private static func write(_ text: String, to url: URL) throws {
        let manager = FileManager.default
        do {
            try backUpIfNeeded(url)
            try manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let mode = (try? manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)
                ?? nil
            try Data(text.utf8).write(to: url, options: .atomic)
            // An atomic write creates a new file, and OpenSSH refuses a config
            // anyone but its owner can write to.
            try manager.setAttributes([.posixPermissions: mode ?? 0o600], ofItemAtPath: url.path)
        } catch {
            throw Failure.unwritable(url, error.localizedDescription)
        }
    }

    /// One copy of the file as it was before Relay first touched it.
    ///
    /// Kept once rather than per edit: the point is a way back to a config
    /// written by hand, not a history of the app's own changes.
    private static func backUpIfNeeded(_ url: URL) throws {
        let manager = FileManager.default
        let backup = url.appendingPathExtension("relay-backup")
        guard manager.fileExists(atPath: url.path), !manager.fileExists(atPath: backup.path) else { return }
        try manager.copyItem(at: url, to: backup)
    }
}
