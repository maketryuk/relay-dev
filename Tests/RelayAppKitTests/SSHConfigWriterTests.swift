import Foundation
import Testing

@testable import RelayAppKit

@Suite("SSH config writing")
struct SSHConfigWriterTests {
    private let configPath = "/home/.ssh/config"

    private func hosts(in config: String, extraFiles: [String: String] = [:]) -> [SSHHost] {
        var files = extraFiles
        files[configPath] = config
        return SSHConfigParser.parse(
            rootConfig: URL(fileURLWithPath: configPath),
            fileSystem: FakeSSHFileSystem(files: files)
        )
    }

    private func host(_ alias: String, in config: String) throws -> SSHHost {
        try #require(hosts(in: config).first { $0.alias == alias })
    }

    private func definition(_ alias: String, in config: String) throws -> SSHHostDefinition {
        try #require(host(alias, in: config).definitions.first)
    }

    // MARK: - Where a block is

    @Test("A block knows the file and the lines it occupies")
    func blockRemembersItsPlace() throws {
        let config = """
        # Servers

        Host staging
            HostName staging.example.com
            User deploy

        Host production
            HostName prod.example.com
        """
        let staging = try definition("staging", in: config)
        #expect(staging.file.path == configPath)
        #expect(staging.lines == 2 ..< 5)
        #expect(try definition("production", in: config).lines == 6 ..< 8)
    }

    @Test("A trailing comment belongs to the host it introduces, not the one above")
    func trailingCommentIsNotSwallowed() throws {
        let config = """
        Host staging
            User deploy

        # The one that matters
        Host production
            User root
        """
        #expect(try definition("staging", in: config).lines == 0 ..< 2)
    }

    @Test("Every host that is listed can be found in a block")
    func everyHostHasABlock() {
        let config = """
        Host *
            ServerAliveInterval 60
        Host staging
            HostName staging.example.com
        """
        // The list only ever offers a host it could locate; an entry with no
        // block behind it would be an Edit button that rewrites `Host *`.
        #expect(hosts(in: config).allSatisfy { !$0.definitions.isEmpty })
    }

    @Test("A block records what it says, not what the host inherits")
    func blockKeepsItsOwnDirectives() throws {
        let config = """
        Host staging
            HostName staging.example.com
        Host *
            User deploy
        """
        let staging = try host("staging", in: config)
        #expect(staging.user == "deploy")
        #expect(staging.definitions[0].directives.map(\.keyword) == ["hostname"])
    }

    // MARK: - Adding

    @Test("A new host is appended as a block of its own")
    func appendsANewBlock() {
        var draft = SSHHostDraft()
        draft.alias = "staging"
        draft.hostName = "staging.example.com"
        draft.user = "deploy"
        draft.port = "2222"

        #expect(SSHConfigWriter.appending(draft, to: "Host old\n    User root\n") == """
        Host old
            User root

        Host staging
            HostName staging.example.com
            User deploy
            Port 2222

        """)
    }

    @Test("The first host does not need the file to exist first")
    func appendsToAnEmptyFile() {
        var draft = SSHHostDraft()
        draft.alias = "staging"
        draft.hostName = "staging.example.com"
        #expect(SSHConfigWriter.appending(draft, to: "") == "Host staging\n    HostName staging.example.com\n")
    }

    // MARK: - Editing

    @Test("Saving a host nobody changed changes nothing at all")
    func editingWithoutChangingIsAnIdentity() throws {
        // The property everything else rests on: a config is somebody's file,
        // and opening it in Relay must not be a way of reformatting it. Every
        // shape below is one a real config puts in front of the writer.
        let config = """
        # Defaults for everything
        Host *
            AddKeysToAgent yes
            ServerAliveInterval 60

        # Bastion first
        Host bastion   # the jump box
        \tHostname=bastion.example.com
        \tUser root
        \tForwardAgent no

        Host staging
          HostName staging.example.com
          # deploy, not root
          User deploy
          Port 2222
          IdentityFile ~/.ssh/id_staging
          ProxyJump bastion
          ControlMaster auto
          ControlPath ~/.ssh/cm-%r@%h:%p

        Host web1 web2 !web3
            User deploy
            Compression yes

        Match host production
            LogLevel QUIET

        Host production
            HostName prod.example.com
        """
        for alias in ["bastion", "staging", "web1", "web2", "production"] {
            let host = try host(alias, in: config)
            let definition = try #require(host.definitions.first)
            let rewritten = SSHConfigWriter.replacing(
                lines: definition.lines,
                in: config,
                with: SSHHostDraft(editing: host),
                previousAlias: alias
            )
            #expect(rewritten == config, "\(alias) was rewritten")
        }
    }

    @Test("Changing one value rewrites one line")
    func changingOneValueTouchesOneLine() throws {
        let config = """
        Host staging
        \tHostname staging.example.com
        \t# deploy, not root
        \tUser deploy
        \tCompression yes
        """
        var draft = SSHHostDraft(editing: try host("staging", in: config))
        draft.user = "release"

        #expect(SSHConfigWriter.replacing(
            lines: try definition("staging", in: config).lines,
            in: config,
            with: draft,
            previousAlias: "staging"
        ) == """
        Host staging
        \tHostname staging.example.com
        \t# deploy, not root
        \tUser release
        \tCompression yes
        """)
    }

    @Test("A value added to a block is indented the way that block indents")
    func addedLinesMatchTheBlockIndent() throws {
        let config = "Host staging\n  HostName staging.example.com"
        var draft = SSHHostDraft(editing: try host("staging", in: config))
        draft.port = "2222"

        #expect(SSHConfigWriter.replacing(
            lines: try definition("staging", in: config).lines,
            in: config,
            with: draft,
            previousAlias: "staging"
        ) == "Host staging\n  HostName staging.example.com\n  Port 2222")
    }

    @Test("Clearing a field removes its line rather than writing an empty one")
    func clearingAFieldRemovesTheLine() throws {
        let config = """
        Host staging
            HostName staging.example.com
            User deploy
        """
        var draft = SSHHostDraft(editing: try host("staging", in: config))
        draft.user = "  "

        #expect(SSHConfigWriter.replacing(
            lines: try definition("staging", in: config).lines,
            in: config,
            with: draft,
            previousAlias: "staging"
        ) == "Host staging\n    HostName staging.example.com")
    }

    @Test("A directive Relay has no field for survives being edited around")
    func unknownDirectivesSurvive() throws {
        let config = """
        Host staging
            HostName staging.example.com
            ControlMaster auto
            ControlPath ~/.ssh/cm-%r@%h:%p
        """
        var draft = SSHHostDraft(editing: try host("staging", in: config))
        draft.hostName = "staging2.example.com"

        #expect(SSHConfigWriter.replacing(
            lines: try definition("staging", in: config).lines,
            in: config,
            with: draft,
            previousAlias: "staging"
        ) == """
        Host staging
            HostName staging2.example.com
            ControlMaster auto
            ControlPath ~/.ssh/cm-%r@%h:%p
        """)
    }

    @Test("An unknown directive is offered back spelled the way the file spells it")
    func unknownDirectivesKeepTheirSpelling() throws {
        let config = "Host staging\n    ServerAliveInterval 60"
        #expect(SSHHostDraft(editing: try host("staging", in: config)).extraDirectives == "ServerAliveInterval 60")
    }

    @Test("ForwardAgent no is a setting, not the absence of one")
    func forwardAgentHasThreeStates() throws {
        let config = """
        Host staging
            ForwardAgent no
        Host *
            ForwardAgent yes
        """
        // Dropping the line because the switch is off would hand the host the
        // `yes` from the wildcard block, which is the opposite of what it says.
        let draft = SSHHostDraft(editing: try host("staging", in: config))
        #expect(draft.forwardAgent == .no)
        #expect(SSHConfigWriter.replacing(
            lines: try definition("staging", in: config).lines,
            in: config,
            with: draft,
            previousAlias: "staging"
        ) == config)
    }

    @Test("A repeated keyword loses the copy OpenSSH was already ignoring")
    func repeatedKeywordsAreCollapsed() throws {
        let config = """
        Host staging
            User deploy
            User root
        """
        #expect(SSHConfigWriter.replacing(
            lines: try definition("staging", in: config).lines,
            in: config,
            with: SSHHostDraft(editing: try host("staging", in: config)),
            previousAlias: "staging"
        ) == "Host staging\n    User deploy")
    }

    // MARK: - Renaming

    @Test("Renaming changes the alias and leaves the block alone")
    func renamingRewritesTheHostLine() throws {
        let config = "Host staging\n    HostName staging.example.com"
        var draft = SSHHostDraft(editing: try host("staging", in: config))
        draft.alias = "stage"

        #expect(SSHConfigWriter.replacing(
            lines: try definition("staging", in: config).lines,
            in: config,
            with: draft,
            previousAlias: "staging"
        ) == "Host stage\n    HostName staging.example.com")
    }

    @Test("Renaming one name in a block that carries several leaves the others")
    func renamingKeepsTheOtherPatterns() throws {
        let config = "Host web1 web2 web3\n    User deploy"
        var draft = SSHHostDraft(editing: try host("web2", in: config))
        draft.alias = "web-two"

        #expect(SSHConfigWriter.replacing(
            lines: try definition("web2", in: config).lines,
            in: config,
            with: draft,
            previousAlias: "web2"
        ) == "Host web1 web-two web3\n    User deploy")
    }

    // MARK: - Deleting

    @Test("Deleting removes the block and the gap it would have left")
    func deletingRemovesTheBlockAndOneBlankLine() throws {
        let config = """
        Host bastion
            User root

        Host staging
            User deploy

        Host production
            User root
        """
        #expect(SSHConfigWriter.removing(
            alias: "staging",
            atLines: try definition("staging", in: config).lines,
            from: config
        ) == """
        Host bastion
            User root

        Host production
            User root
        """)
    }

    @Test("Deleting a host named alongside others takes the name, not the block")
    func deletingFromASharedBlockRemovesOnlyTheName() throws {
        let config = "Host web1 web2\n    User deploy"
        #expect(SSHConfigWriter.removing(
            alias: "web1",
            atLines: try definition("web1", in: config).lines,
            from: config
        ) == "Host web2\n    User deploy")
    }

    @Test("Deleting the only host leaves an empty file, not a file of blank lines")
    func deletingTheLastHostEmptiesTheFile() throws {
        let config = "Host staging\n    User deploy\n"
        #expect(SSHConfigWriter.removing(
            alias: "staging",
            atLines: try definition("staging", in: config).lines,
            from: config
        ) == "")
    }

    @Test("A host declared twice is deleted from both places")
    func deletingRemovesEveryBlock() throws {
        let config = """
        Host staging
            User deploy

        Host other
            User root

        Host staging
            Port 2222
        """
        var text = config
        // Last first, so the earlier line numbers are still the ones parsed.
        for definition in try host("staging", in: config).definitions
            .sorted(by: { $0.lines.lowerBound > $1.lines.lowerBound })
        {
            text = SSHConfigWriter.removing(alias: "staging", atLines: definition.lines, from: text)
        }
        #expect(text == "Host other\n    User root")
    }

    // MARK: - The Host * defaults

    @Test("A setting the block is missing is added; one it has is left alone")
    func ensuringAddsOnlyWhatIsMissing() throws {
        let config = """
        Host *
            AddKeysToAgent yes
            # everything else stays
            ServerAliveInterval 60

        Host staging
            User deploy
        """
        let wildcard = try #require(
            SSHConfigParser.blocks(in: config, file: URL(fileURLWithPath: configPath))
                .first { $0.patterns == ["*"] }
        )
        #expect(SSHConfigWriter.ensuring(
            SSHConfigStore.keychainDefaults,
            inBlockAt: wildcard.lines,
            of: config
        ) == """
        Host *
            AddKeysToAgent yes
            # everything else stays
            ServerAliveInterval 60
            UseKeychain yes

        Host staging
            User deploy
        """)
    }

    @Test("A block that already says it all is not rewritten")
    func ensuringIsAnIdentityWhenNothingIsMissing() throws {
        let config = "Host *\n\tUseKeychain yes\n\tAddKeysToAgent yes"
        let wildcard = try #require(
            SSHConfigParser.blocks(in: config, file: URL(fileURLWithPath: configPath))
                .first { $0.patterns == ["*"] }
        )
        #expect(SSHConfigWriter.ensuring(
            SSHConfigStore.keychainDefaults,
            inBlockAt: wildcard.lines,
            of: config
        ) == config)
    }

    @Test("Blocks in one file are found without following Include")
    func blocksAreFoundWithoutIncludes() {
        let config = """
        Include ~/.ssh/work.conf

        Host *
            AddKeysToAgent yes

        Match host staging
            LogLevel QUIET

        Host staging
            User deploy
        """
        // Include is not followed here on purpose: this answers "what is in
        // this file", which is what editing the file needs to know.
        let blocks = SSHConfigParser.blocks(in: config, file: URL(fileURLWithPath: configPath))
        #expect(blocks.map(\.patterns) == [["*"], ["staging"]])
    }

    // MARK: - Validation

    @Test("An alias has to be a name a connection can be made by")
    func aliasIsValidated() {
        func problem(_ alias: String, taken: Set<String> = []) -> SSHHostDraftProblem? {
            var draft = SSHHostDraft()
            draft.alias = alias
            return SSHConfigWriter.problem(with: draft, takenAliases: taken)
        }
        #expect(problem("") == .emptyAlias)
        #expect(problem("   ") == .emptyAlias)
        #expect(problem("my staging") == .aliasHasWhitespace)
        #expect(problem("web*") == .aliasIsPattern)
        #expect(problem("!web") == .aliasIsPattern)
        #expect(problem("staging", taken: ["staging"]) == .aliasTaken)
        #expect(problem("staging") == nil)
    }

    @Test("A port is a number a connection can be made on")
    func portIsValidated() {
        func problem(_ port: String) -> SSHHostDraftProblem? {
            var draft = SSHHostDraft()
            draft.alias = "staging"
            draft.port = port
            return SSHConfigWriter.problem(with: draft, takenAliases: [])
        }
        #expect(problem("") == nil)
        #expect(problem("2222") == nil)
        #expect(problem("ssh") == .invalidPort)
        #expect(problem("0") == .invalidPort)
        #expect(problem("70000") == .invalidPort)
    }

    @Test("A free-text directive that is not one is refused before it is written")
    func extraDirectivesAreValidated() {
        func problem(_ text: String) -> SSHHostDraftProblem? {
            var draft = SSHHostDraft()
            draft.alias = "staging"
            draft.extraDirectives = text
            return SSHConfigWriter.problem(with: draft, takenAliases: [])
        }
        #expect(problem("ServerAliveInterval 60\n\nCompression yes") == nil)
        #expect(problem("# just a note") == nil)
        #expect(problem("ServerAliveInterval") == .notADirective("ServerAliveInterval"))
        // A second Host inside the block would quietly start a different one.
        #expect(problem("Host elsewhere") == .notADirective("Host elsewhere"))
    }
}
