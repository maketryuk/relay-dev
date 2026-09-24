import Foundation
import Testing

@testable import RelayAppKit

@Suite("JSON that keeps what it was given")
struct OrderedJSONTests {
    /// In the shape `JSON.stringify(value, null, 2)` writes, which is the
    /// shape the agents' settings files are in.
    static let stringified = """
    {
      "zeta": 1.50,
      "alpha": {
        "nested": [
          true,
          null,
          "a \\"quoted\\" path/with/slashes",
          "é — ünïcode"
        ],
        "empty": {},
        "none": []
      },
      "exponent": 1e-3
    }
    """

    @Test("A file already in that shape comes back byte for byte")
    func roundTrip() throws {
        #expect(try OrderedJSON.parse(Self.stringified).serialized() == Self.stringified)
    }

    @Test("Keys stay in the order they were written, not sorted")
    func order() throws {
        guard case let .object(members) = try OrderedJSON.parse(Self.stringified) else {
            Issue.record("not an object")
            return
        }
        #expect(members.map(\.key) == ["zeta", "alpha", "exponent"])
    }

    @Test("Strings are escaped as JSON.stringify escapes them, and read back as they were")
    func quoting() throws {
        let original = "tab\there \"quote\" back\\slash /slash \u{01} é"
        let quoted = OrderedJSON.quoted(original)
        #expect(quoted == #""tab\there \"quote\" back\\slash /slash \u0001 é""#)
        #expect(OrderedJSON.scalar(quoted).stringValue == original)
    }

    @Test("What is not JSON is refused", arguments: [
        "", "{", "{\"a\": }", "{\"a\": 1} trailing", "[1,]", "{\"a\" 1}", "{\"a\": tru}",
    ])
    func refused(text: String) {
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse(text) }
    }
}

@Suite("Installing Relay's hook beside everyone else's", .serialized)
struct AgentHookInstallerTests {
    /// Settings as Claude Code and other tools leave them, trimmed down.
    static let claudeSettings = """
    {
      "permissions": {
        "allow": [
          "Bash(git status:*)"
        ]
      },
      "hooks": {
        "UserPromptSubmit": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "[ -n \\"$OTHER_TOOL_HOME\\" ] && \\"$OTHER_TOOL_HOME/hooks/notify.sh\\" || true"
              }
            ]
          }
        ],
        "Notification": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "exec \\"$RELAY_HOOK\\" claude --old"
              }
            ]
          }
        ]
      },
      "statusLine": {
        "type": "command",
        "command": "bash \\"$HOME/.claude/statusline-command.sh\\""
      }
    }

    """

    private func claudeFolder(_ directory: TemporaryDirectory, settings: String? = claudeSettings) throws -> URL {
        let file = directory.url.appendingPathComponent(".claude/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let settings { try settings.write(to: file, atomically: true, encoding: .utf8) }
        return file
    }

    private func commands(in settings: OrderedJSON, event: String) -> [String] {
        guard case let .array(groups)? = settings["hooks"]?[event] else { return [] }
        return groups.flatMap { group -> [String] in
            guard case let .array(handlers)? = group["hooks"] else { return [] }
            return handlers.compactMap { $0["command"]?.stringValue }
        }
    }

    @Test("The command runs nothing outside a Relay terminal, and says nothing Claude would read as a refusal")
    func command() {
        let claude = AgentHookInstaller.command(for: .claude)
        #expect(claude.hasPrefix(#"if [ -x "${RELAY_HOOK:-}" ]; then exec "$RELAY_HOOK" claude; fi;"#))
        #expect(claude.hasSuffix(#"printf '{}\n'"#))
        #expect(!AgentHookInstaller.command(for: .codex).contains("printf"))
    }

    @Test("Relay's entry goes last under each event, and nothing else in the file moves")
    func claudeInstall() throws {
        let directory = try TemporaryDirectory()
        let file = try claudeFolder(directory)
        #expect(AgentHookInstaller.installClaude(settings: file) == .installed)

        let settings = try OrderedJSON.parse(String(contentsOf: file, encoding: .utf8))
        let relay = AgentHookInstaller.command(for: .claude)
        let prompt = commands(in: settings, event: "UserPromptSubmit")
        #expect(prompt.count == 2)
        #expect(prompt.first?.contains("OTHER_TOOL_HOME") == true)
        #expect(prompt.last == relay)
        for event in AgentHookInstaller.claudeEvents {
            #expect(commands(in: settings, event: event.name).last == relay)
        }
        #expect(settings["permissions"] == (try OrderedJSON.parse(Self.claudeSettings))["permissions"])
        #expect(settings["statusLine"] == (try OrderedJSON.parse(Self.claudeSettings))["statusLine"])
        guard case let .object(members) = settings else { return }
        #expect(members.map(\.key) == ["permissions", "hooks", "statusLine"])
    }

    @Test("An old entry of Relay's is replaced, and an event no longer asked about is let go")
    func claudeReplacesOld() throws {
        let directory = try TemporaryDirectory()
        let file = try claudeFolder(directory)
        _ = AgentHookInstaller.installClaude(settings: file)
        let settings = try OrderedJSON.parse(String(contentsOf: file, encoding: .utf8))
        #expect(settings["hooks"]?["Notification"] == nil)
        let every = AgentHookInstaller.claudeEvents.flatMap { commands(in: settings, event: $0.name) }
        #expect(!every.contains { $0.contains("--old") })
    }

    @Test("A second launch finds it installed and writes nothing")
    func claudeIdempotent() throws {
        let directory = try TemporaryDirectory()
        let file = try claudeFolder(directory)
        _ = AgentHookInstaller.installClaude(settings: file)
        let first = try String(contentsOf: file, encoding: .utf8)
        #expect(AgentHookInstaller.installClaude(settings: file) == .unchanged)
        #expect(try String(contentsOf: file, encoding: .utf8) == first)
    }

    @Test("A private settings file stays private")
    func permissionsKept() throws {
        let directory = try TemporaryDirectory()
        let file = try claudeFolder(directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        _ = AgentHookInstaller.installClaude(settings: file)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test("Settings that do not exist yet are started")
    func claudeFresh() throws {
        let directory = try TemporaryDirectory()
        let file = try claudeFolder(directory, settings: nil)
        #expect(AgentHookInstaller.installClaude(settings: file) == .installed)
        let settings = try OrderedJSON.parse(String(contentsOf: file, encoding: .utf8))
        #expect(commands(in: settings, event: "Stop") == [AgentHookInstaller.command(for: .claude)])
    }

    @Test("An agent that is not installed is not installed into")
    func noAgent() throws {
        let directory = try TemporaryDirectory()
        let file = directory.url.appendingPathComponent(".claude/settings.json")
        guard case .skipped = AgentHookInstaller.installClaude(settings: file) else {
            Issue.record("installed into a folder that did not exist")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
    }

    @Test("A file Relay cannot read is left exactly as it was")
    func unreadable() throws {
        let directory = try TemporaryDirectory()
        let broken = "{ \"hooks\": { // a comment\n } }\n"
        let file = try claudeFolder(directory, settings: broken)
        guard case .skipped = AgentHookInstaller.installClaude(settings: file) else {
            Issue.record("wrote over a file it could not read")
            return
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == broken)
    }

    // MARK: - Codex

    @Test("Codex's trust hash is Codex's", arguments: [
        ("stop", #"printf "done\n" >> "$HOME/log""#, 10,
         "sha256:f8cca0b11859ffb9df0bc0b08729f7e3bf29054873bc33c74d91f3c33f278ecb"),
        ("pre_tool_use", "true", 600,
         "sha256:a7de97b60e1412f8e936f33ad7e97c04dfe69190d43e61d14c46265643383835"),
    ])
    func trustHash(label: String, command: String, timeout: Int, expected: String) {
        #expect(AgentHookInstaller.trustHash(label: label, command: command, timeout: timeout) == expected)
    }

    private func codexFolder(_ directory: TemporaryDirectory, config: String) throws -> (hooks: URL, config: URL) {
        let folder = directory.url.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let hooks = folder.appendingPathComponent("hooks.json")
        try """
        {
          "hooks": {
            "Stop": [
              {
                "hooks": [
                  {
                    "type": "command",
                    "command": "someone-else",
                    "timeout": 10
                  }
                ]
              }
            ]
          }
        }

        """.write(to: hooks, atomically: true, encoding: .utf8)
        let configURL = folder.appendingPathComponent("config.toml")
        try config.write(to: configURL, atomically: true, encoding: .utf8)
        return (hooks, configURL)
    }

    @Test("Codex gets the entry and a trust record for each, keyed by where the entry is")
    func codexInstall() throws {
        let directory = try TemporaryDirectory()
        let (hooks, config) = try codexFolder(directory, config: "model = \"gpt-5\"\n")
        #expect(AgentHookInstaller.installCodex(hooks: hooks, config: config) == .installed)

        let settings = try OrderedJSON.parse(String(contentsOf: hooks, encoding: .utf8))
        let command = AgentHookInstaller.command(for: .codex)
        #expect(commands(in: settings, event: "Stop") == ["someone-else", command])

        let toml = try String(contentsOf: config, encoding: .utf8)
        #expect(toml.hasPrefix("model = \"gpt-5\"\n"))
        let source = AgentHookInstaller.trustSourcePath(for: hooks)
        let stop = AgentHookInstaller.trustHash(label: "stop", command: command, timeout: AgentHookInstaller.timeout)
        #expect(toml.contains("[hooks.state.\"\(source):stop:1:0\"]\ntrusted_hash = \"\(stop)\""))
        for event in AgentHookInstaller.codexEvents where event.name != "Stop" {
            #expect(toml.contains("[hooks.state.\"\(source):\(event.label):0:0\"]"))
        }
    }

    @Test("A second launch leaves both files alone")
    func codexIdempotent() throws {
        let directory = try TemporaryDirectory()
        let (hooks, config) = try codexFolder(directory, config: "")
        _ = AgentHookInstaller.installCodex(hooks: hooks, config: config)
        let before = try (String(contentsOf: hooks, encoding: .utf8), String(contentsOf: config, encoding: .utf8))
        #expect(AgentHookInstaller.installCodex(hooks: hooks, config: config) == .unchanged)
        let after = try (String(contentsOf: hooks, encoding: .utf8), String(contentsOf: config, encoding: .utf8))
        #expect(before == after)
    }

    @Test("When the entry moves, its old trust record goes and a new one comes")
    func codexStaleTrust() throws {
        let directory = try TemporaryDirectory()
        let (hooks, config) = try codexFolder(directory, config: "")
        _ = AgentHookInstaller.installCodex(hooks: hooks, config: config)
        let source = AgentHookInstaller.trustSourcePath(for: hooks)

        // Another tool appends its own after Relay's: Relay's is now second of three.
        var settings = try OrderedJSON.parse(String(contentsOf: hooks, encoding: .utf8))
        guard case let .array(groups)? = settings["hooks"]?["Stop"], let hooksObject = settings["hooks"] else {
            Issue.record("no Stop entries")
            return
        }
        settings = settings.setting("hooks", to: hooksObject.setting("Stop", to: .array(groups + [groups[0]])))
        try (settings.serialized() + "\n").write(to: hooks, atomically: true, encoding: .utf8)

        _ = AgentHookInstaller.installCodex(hooks: hooks, config: config)
        let toml = try String(contentsOf: config, encoding: .utf8)
        #expect(toml.contains("\(source):stop:2:0"))
        #expect(!toml.contains("\(source):stop:1:0"))
        #expect(toml.components(separatedBy: ":stop:").count == 2)
    }

    @Test("A config that defines hooks inline is not edited; Codex will ask instead")
    func codexForeignConfig() throws {
        let directory = try TemporaryDirectory()
        let inline = "hooks = { state = {} }\n"
        let (hooks, config) = try codexFolder(directory, config: inline)
        guard case .skipped = AgentHookInstaller.installCodex(hooks: hooks, config: config) else {
            Issue.record("edited a config it could have broken")
            return
        }
        #expect(try String(contentsOf: config, encoding: .utf8) == inline)
    }
}
