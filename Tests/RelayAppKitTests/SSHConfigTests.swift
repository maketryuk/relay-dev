import Foundation
import Testing

@testable import RelayAppKit

/// In-memory filesystem so parsing is tested against fixtures rather than the
/// developer's real `~/.ssh`.
struct FakeSSHFileSystem: SSHConfigFileSystem {
    var files: [String: String]

    func read(_ url: URL) -> String? {
        files[url.path]
    }

    func resolve(include pattern: String, relativeTo directory: URL) -> [URL] {
        let absolute = pattern.hasPrefix("/") ? pattern : directory.appendingPathComponent(pattern).path
        if absolute.contains("*") {
            let prefix = String(absolute.prefix(while: { $0 != "*" }))
            return files.keys
                .filter { $0.hasPrefix(prefix) }
                .sorted()
                .map { URL(fileURLWithPath: $0) }
        }
        return files[absolute] != nil ? [URL(fileURLWithPath: absolute)] : []
    }
}

@Suite("SSH config parsing")
struct SSHConfigTests {
    private func parse(_ config: String, extraFiles: [String: String] = [:]) -> [SSHHost] {
        var files = extraFiles
        files["/home/.ssh/config"] = config
        return SSHConfigParser.parse(
            rootConfig: URL(fileURLWithPath: "/home/.ssh/config"),
            fileSystem: FakeSSHFileSystem(files: files)
        )
    }

    @Test("A simple host block is read in full")
    func simpleHost() {
        let hosts = parse("""
        Host staging
            HostName staging.example.com
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_staging
        """)
        #expect(hosts.count == 1)
        #expect(hosts[0].alias == "staging")
        #expect(hosts[0].hostName == "staging.example.com")
        #expect(hosts[0].user == "deploy")
        #expect(hosts[0].port == 2222)
        #expect(hosts[0].identityFile == "~/.ssh/id_staging")
    }

    @Test("Multiple hosts keep their file order")
    func multipleHostsKeepOrder() {
        let hosts = parse("""
        Host bastion
            HostName bastion.example.com
        Host database
            HostName db.internal
        Host production
            HostName prod.example.com
        """)
        #expect(hosts.map(\.alias) == ["bastion", "database", "production"])
    }

    @Test("Comments and blank lines are ignored")
    func commentsIgnored() {
        let hosts = parse("""
        # Production servers

        Host web    # inline comment
            HostName web.example.com
            # User root
        """)
        #expect(hosts.count == 1)
        #expect(hosts[0].hostName == "web.example.com")
        #expect(hosts[0].user == nil)
    }

    @Test("Keywords are case-insensitive")
    func caseInsensitiveKeywords() {
        let hosts = parse("""
        HOST myhost
            hostname example.com
            USER admin
            PoRt 2200
        """)
        #expect(hosts[0].hostName == "example.com")
        #expect(hosts[0].user == "admin")
        #expect(hosts[0].port == 2200)
    }

    @Test("The `Keyword=value` form is accepted")
    func equalsSeparator() {
        let hosts = parse("""
        Host equals
            HostName=equals.example.com
            User = someone
        """)
        #expect(hosts[0].hostName == "equals.example.com")
        #expect(hosts[0].user == "someone")
    }

    @Test("Quoted values are unquoted")
    func quotedValues() {
        let hosts = parse("""
        Host quoted
            IdentityFile "~/.ssh/key with spaces"
        """)
        #expect(hosts[0].identityFile == "~/.ssh/key with spaces")
    }

    @Test("Wildcard-only blocks are not offered as connectable hosts")
    func wildcardBlocksAreNotHosts() {
        let hosts = parse("""
        Host *
            User defaultuser
        Host *.internal
            Port 2022
        Host real
            HostName real.example.com
        """)
        #expect(hosts.map(\.alias) == ["real"])
    }

    @Test("A trailing `Host *` block supplies defaults")
    func wildcardSuppliesDefaults() {
        let hosts = parse("""
        Host web
            HostName web.example.com
        Host *
            User globaluser
            Port 2020
        """)
        #expect(hosts[0].user == "globaluser")
        #expect(hosts[0].port == 2020)
    }

    @Test("The first value obtained for a keyword wins, as OpenSSH specifies")
    func firstValueWins() {
        // A `Host *` block placed first would override every specific setting in
        // real ssh; the parser must reproduce that, surprising as it is.
        let hosts = parse("""
        Host web
            User specific
        Host *
            User fallback
        """)
        #expect(hosts[0].user == "specific")

        let inverted = parse("""
        Host *
            User fallback
        Host web
            HostName web.example.com
            User specific
        """)
        #expect(inverted[0].user == "fallback")
    }

    @Test("One block declaring several aliases yields one host each")
    func multipleAliasesInOneBlock() {
        let hosts = parse("""
        Host alpha beta gamma
            HostName shared.example.com
            User shared
        """)
        #expect(hosts.map(\.alias) == ["alpha", "beta", "gamma"])
        #expect(hosts.allSatisfy { $0.hostName == "shared.example.com" })
    }

    @Test("A pattern block applies to matching aliases")
    func patternBlockApplies() {
        let hosts = parse("""
        Host web1 web2
            HostName placeholder
        Host web*
            User webuser
            Port 8022
        """)
        #expect(hosts.count == 2)
        #expect(hosts.allSatisfy { $0.user == "webuser" && $0.port == 8022 })
    }

    @Test("A negated pattern excludes a host from a block")
    func negatedPattern() {
        let hosts = parse("""
        Host web1 web2
            HostName placeholder
        Host web* !web2
            User webuser
        """)
        let byAlias = Dictionary(uniqueKeysWithValues: hosts.map { ($0.alias, $0) })
        #expect(byAlias["web1"]?.user == "webuser")
        #expect(byAlias["web2"]?.user == nil)
    }

    @Test("Include pulls in hosts from another file")
    func includeIsExpanded() {
        let hosts = parse(
            """
            Include work/config
            Host personal
                HostName personal.example.com
            """,
            extraFiles: [
                "/home/.ssh/work/config": """
                Host work-vpn
                    HostName vpn.work.internal
                    User employee
                """,
            ]
        )
        #expect(hosts.map(\.alias) == ["work-vpn", "personal"])
        #expect(hosts[0].user == "employee")
    }

    @Test("Include supports globs and includes every match")
    func includeGlob() {
        let hosts = parse(
            "Include conf.d/*",
            extraFiles: [
                "/home/.ssh/conf.d/10-a": "Host alpha\n    HostName a.example.com",
                "/home/.ssh/conf.d/20-b": "Host beta\n    HostName b.example.com",
            ]
        )
        #expect(hosts.map(\.alias) == ["alpha", "beta"])
    }

    @Test("Nested includes are followed")
    func nestedInclude() {
        let hosts = parse(
            "Include level1",
            extraFiles: [
                "/home/.ssh/level1": "Include level2",
                "/home/.ssh/level2": "Host deep\n    HostName deep.example.com",
            ]
        )
        #expect(hosts.map(\.alias) == ["deep"])
    }

    @Test("A self-including config terminates instead of looping forever")
    func includeCycleIsBroken() {
        let hosts = parse(
            """
            Include loop
            Host safe
                HostName safe.example.com
            """,
            extraFiles: ["/home/.ssh/loop": "Include loop\nHost looped\n    HostName looped.example.com"]
        )
        #expect(hosts.map(\.alias).contains("safe"))
        #expect(hosts.map(\.alias).contains("looped"))
    }

    @Test("A missing Include is skipped silently")
    func missingIncludeIgnored() {
        let hosts = parse("""
        Include does/not/exist
        Host survivor
            HostName survivor.example.com
        """)
        #expect(hosts.map(\.alias) == ["survivor"])
    }

    @Test("A Match block ends the preceding Host block")
    func matchBlockEndsHost() {
        let hosts = parse("""
        Host web
            HostName web.example.com
        Match host *.internal
            User internaluser
        """)
        #expect(hosts.count == 1)
        // `User` belongs to the Match block, so it must not leak onto `web`.
        #expect(hosts[0].user == nil)
    }

    @Test("A missing config file yields no hosts")
    func missingConfig() {
        let hosts = SSHConfigParser.parse(
            rootConfig: URL(fileURLWithPath: "/nowhere/config"),
            fileSystem: FakeSSHFileSystem(files: [:])
        )
        #expect(hosts.isEmpty)
    }

    @Test("A duplicated alias is listed once")
    func duplicateAliases() {
        let hosts = parse("""
        Host dupe
            HostName first.example.com
        Host dupe
            HostName second.example.com
        """)
        #expect(hosts.count == 1)
        #expect(hosts[0].hostName == "first.example.com")
    }

    @Test("A non-numeric port is ignored rather than defaulting to zero")
    func invalidPort() {
        let hosts = parse("Host bad\n    Port notanumber")
        #expect(hosts[0].port == nil)
    }

    @Test(
        "Glob matching follows OpenSSH semantics",
        arguments: [
            ("*", "anything", true),
            ("web*", "web1", true),
            ("web*", "api1", false),
            ("web?", "web1", true),
            ("web?", "web12", false),
            ("*.internal", "db.internal", true),
            ("*.internal", "db.external", false),
            ("exact", "exact", true),
            ("exact", "exactly", false),
            ("a*c", "abc", true),
            ("a*c", "ac", true),
        ]
    )
    func globMatching(pattern: String, value: String, expected: Bool) {
        #expect(SSHConfigParser.matchesGlob(pattern: pattern, value: value) == expected)
    }
}

@Suite("SSH host presentation")
struct SSHHostPresentationTests {
    @Test("The display target composes user, host and non-default port")
    func displayTarget() {
        #expect(SSHHost(alias: "a", hostName: "example.com").displayTarget == "example.com")
        #expect(SSHHost(alias: "a", hostName: "example.com", user: "root").displayTarget == "root@example.com")
        #expect(
            SSHHost(alias: "a", hostName: "example.com", user: "root", port: 2222).displayTarget
                == "root@example.com:2222"
        )
        // Port 22 is noise.
        #expect(SSHHost(alias: "a", hostName: "example.com", port: 22).displayTarget == "example.com")
    }

    @Test("Without a HostName the alias itself is the target")
    func aliasIsFallbackTarget() {
        #expect(SSHHost(alias: "myserver").displayTarget == "myserver")
    }
}

@Suite("SSH pinning")
struct SSHPinningTests {
    private let hosts = [
        SSHHost(alias: "alpha"),
        SSHHost(alias: "beta"),
        SSHHost(alias: "gamma"),
    ]

    @Test("With nothing pinned every host stays in file order")
    func noPins() {
        let split = SSHHostOrdering.split(hosts: hosts, pinnedAliases: [])
        #expect(split.pinned.isEmpty)
        #expect(split.others.map(\.alias) == ["alpha", "beta", "gamma"])
    }

    @Test("Pinned hosts come first, in the order they were pinned")
    func pinnedOrderIsPreserved() {
        let split = SSHHostOrdering.split(hosts: hosts, pinnedAliases: ["gamma", "alpha"])
        #expect(split.pinned.map(\.alias) == ["gamma", "alpha"])
        #expect(split.others.map(\.alias) == ["beta"])
    }

    @Test("A pin naming a host that no longer exists is skipped")
    func stalePinIgnored() {
        let split = SSHHostOrdering.split(hosts: hosts, pinnedAliases: ["deleted-host", "beta"])
        #expect(split.pinned.map(\.alias) == ["beta"])
        #expect(split.others.map(\.alias) == ["alpha", "gamma"])
    }

    @Test("Pinning toggles on and off")
    func togglePin() {
        var project = Project(name: "Test", rootPath: "/tmp")
        #expect(project.pinnedSSHHosts.isEmpty)
        project.togglePin(sshHost: "staging")
        project.togglePin(sshHost: "production")
        #expect(project.pinnedSSHHosts == ["staging", "production"])
        project.togglePin(sshHost: "staging")
        #expect(project.pinnedSSHHosts == ["production"])
    }
}

@Suite("Workspace format compatibility")
struct WorkspaceCompatibilityTests {
    @Test("A workspace written before SSH pins existed still loads")
    func decodesLegacyProject() throws {
        // Exactly the shape milestone 1 wrote to disk.
        let legacy = """
        {
          "version": 1,
          "projects": [
            {
              "id": "A1B2",
              "name": "Legacy",
              "rootPath": "/tmp/legacy",
              "createdAt": "2026-01-01T00:00:00Z",
              "defaultAgent": "claude",
              "sessionNameCounters": { "shell": 2 },
              "preferredEditor": "code"
            }
          ],
          "lastActiveSessionByProject": {},
          "sidebarWidth": 248,
          "collapsedSections": []
        }
        """
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let state = WorkspaceStore(url: url).load()
        #expect(state.projects.count == 1)
        #expect(state.projects[0].name == "Legacy")
        #expect(state.projects[0].pinnedSSHHosts.isEmpty)
        // The obsolete counter key is simply ignored rather than failing the load.
        #expect(state.projects[0].preferredEditor == "code")
    }

    @Test("A minimal project entry loads with sensible defaults")
    func decodesMinimalProject() throws {
        let minimal = """
        { "projects": [ { "id": "X", "name": "Bare", "rootPath": "/tmp" } ] }
        """
        let directory = try TemporaryDirectory()
        let url = directory.url.appendingPathComponent("workspace.json")
        try minimal.write(to: url, atomically: true, encoding: .utf8)

        let state = WorkspaceStore(url: url).load()
        #expect(state.projects.count == 1)
        #expect(state.projects[0].defaultAgent == .claude)
        #expect(state.sidebarWidth == 248)
        #expect(state.version == 1)
    }
}
