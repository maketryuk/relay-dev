import Foundation
import Testing

@testable import RelayAppKit

/// The parts that touch somebody's real `~/.ssh`, driven against a throwaway
/// directory rather than mocked: what is worth checking here is exactly what a
/// mock would have to assume.
@Suite("SSH config files")
struct SSHConfigStoreTests {
    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-ssh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func draft(alias: String, hostName: String) -> SSHHostDraft {
        var draft = SSHHostDraft()
        draft.alias = alias
        draft.hostName = hostName
        return draft
    }

    private func definition(of alias: String, in url: URL) throws -> SSHHostDefinition {
        let hosts = SSHConfigParser.parse(rootConfig: url)
        return try #require(hosts.first { $0.alias == alias }?.definitions.first)
    }

    @Test("A config that is not there yet is created rather than refused")
    func createsTheConfig() throws {
        try withTemporaryDirectory { directory in
            let config = directory.appendingPathComponent(".ssh/config")
            try SSHConfigStore.add(draft(alias: "staging", hostName: "staging.example.com"), to: config)

            #expect(try String(contentsOf: config, encoding: .utf8)
                == "Host staging\n    HostName staging.example.com\n")
            let mode = try #require(
                FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber
            )
            // OpenSSH refuses a config anybody but its owner can write to.
            #expect(mode.int16Value & 0o077 == 0)
        }
    }

    @Test("The permissions a config already had are the permissions it keeps")
    func keepsPermissions() throws {
        try withTemporaryDirectory { directory in
            let config = directory.appendingPathComponent("config")
            try "Host old\n    User root\n".write(to: config, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: config.path)

            try SSHConfigStore.add(draft(alias: "staging", hostName: "staging.example.com"), to: config)

            let mode = try #require(
                FileManager.default.attributesOfItem(atPath: config.path)[.posixPermissions] as? NSNumber
            )
            // An atomic write creates a new file, which would otherwise arrive
            // with whatever the umask says instead.
            #expect(mode.int16Value & 0o777 == 0o640)
        }
    }

    @Test("A config kept in a dotfiles repository stays the symlink it was")
    func followsSymlinks() throws {
        try withTemporaryDirectory { directory in
            let real = directory.appendingPathComponent("dotfiles-config")
            let link = directory.appendingPathComponent("config")
            try "Host old\n    User root\n".write(to: real, atomically: true, encoding: .utf8)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

            try SSHConfigStore.add(draft(alias: "staging", hostName: "staging.example.com"), to: link)

            // Writing through the link rather than over it: the alternative
            // replaces the symlink with a plain file, and the config under
            // version control silently stops being the one in use.
            let type = try FileManager.default.attributesOfItem(atPath: link.path)[.type] as? FileAttributeType
            #expect(type == .typeSymbolicLink)
            #expect(try String(contentsOf: real, encoding: .utf8).contains("Host staging"))
        }
    }

    @Test("The file as it was before Relay first touched it is kept once")
    func backsUpOnce() throws {
        try withTemporaryDirectory { directory in
            let config = directory.appendingPathComponent("config")
            let original = "Host old\n    User root\n"
            try original.write(to: config, atomically: true, encoding: .utf8)

            try SSHConfigStore.add(draft(alias: "one", hostName: "one.example.com"), to: config)
            try SSHConfigStore.add(draft(alias: "two", hostName: "two.example.com"), to: config)

            // A backup rewritten on every save is a copy of the last edit, not
            // a way back to the file somebody wrote by hand.
            let backup = directory.appendingPathComponent("config.relay-backup")
            #expect(try String(contentsOf: backup, encoding: .utf8) == original)
        }
    }

    @Test("The keychain defaults are written where a default belongs")
    func writesKeychainDefaults() throws {
        try withTemporaryDirectory { directory in
            let config = directory.appendingPathComponent("config")
            try "Host staging\n    User deploy\n".write(to: config, atomically: true, encoding: .utf8)

            #expect(SSHConfigStore.hasKeychainDefaults(rootConfig: config) == false)

            try SSHConfigStore.enableKeychainDefaults(in: config)

            // At the end, because OpenSSH keeps the first value it obtains: a
            // `Host *` above would override what a host says rather than stand
            // behind it.
            #expect(try String(contentsOf: config, encoding: .utf8) == """
            Host staging
                User deploy

            Host *
                AddKeysToAgent yes
                UseKeychain yes

            """)
            #expect(SSHConfigStore.hasKeychainDefaults(rootConfig: config))
        }
    }

    @Test("Defaults kept in an included file count as already set")
    func seesKeychainDefaultsBehindAnInclude() throws {
        try withTemporaryDirectory { directory in
            let config = directory.appendingPathComponent("config")
            let included = directory.appendingPathComponent("defaults.conf")
            try "Include \(included.path)\n".write(to: config, atomically: true, encoding: .utf8)
            try "Host *\n    AddKeysToAgent yes\n    UseKeychain yes\n"
                .write(to: included, atomically: true, encoding: .utf8)

            // Offering to add them again would write a second `Host *` saying
            // exactly what the first one already says.
            #expect(SSHConfigStore.hasKeychainDefaults(rootConfig: config))
        }
    }

    @Test("A setting explicitly turned off is not a setting that is on")
    func doesNotMistakeNoForYes() throws {
        try withTemporaryDirectory { directory in
            let config = directory.appendingPathComponent("config")
            try "Host *\n    AddKeysToAgent yes\n    UseKeychain no\n"
                .write(to: config, atomically: true, encoding: .utf8)
            #expect(SSHConfigStore.hasKeychainDefaults(rootConfig: config) == false)
        }
    }

    @Test("Asking twice does not write twice")
    func keychainDefaultsAreIdempotent() throws {
        try withTemporaryDirectory { directory in
            let config = directory.appendingPathComponent("config")
            try "Host *\n    AddKeysToAgent yes\n".write(to: config, atomically: true, encoding: .utf8)

            try SSHConfigStore.enableKeychainDefaults(in: config)
            let once = try String(contentsOf: config, encoding: .utf8)
            try SSHConfigStore.enableKeychainDefaults(in: config)

            #expect(once == "Host *\n    AddKeysToAgent yes\n    UseKeychain yes\n")
            #expect(try String(contentsOf: config, encoding: .utf8) == once)
        }
    }

    @Test("An edit reaches the file the block actually came from")
    func editsTheIncludedFile() throws {
        try withTemporaryDirectory { directory in
            let config = directory.appendingPathComponent("config")
            let included = directory.appendingPathComponent("work.conf")
            try "Include \(included.path)\n\nHost home\n    User me\n"
                .write(to: config, atomically: true, encoding: .utf8)
            try "Host staging\n    HostName staging.example.com\n"
                .write(to: included, atomically: true, encoding: .utf8)

            let definition = try definition(of: "staging", in: config)
            var draft = SSHHostDraft()
            draft.alias = "staging"
            draft.hostName = "staging2.example.com"
            try SSHConfigStore.update(draft, at: definition, previousAlias: "staging")

            #expect(try String(contentsOf: included, encoding: .utf8)
                == "Host staging\n    HostName staging2.example.com\n")
            #expect(try String(contentsOf: config, encoding: .utf8).contains("Host home"))
        }
    }

    @Test("Deleting reaches the file the block actually came from")
    func deletesFromTheIncludedFile() throws {
        try withTemporaryDirectory { directory in
            let config = directory.appendingPathComponent("config")
            let included = directory.appendingPathComponent("work.conf")
            try "Include \(included.path)\n".write(to: config, atomically: true, encoding: .utf8)
            try "Host staging\n    User deploy\n\nHost production\n    User root\n"
                .write(to: included, atomically: true, encoding: .utf8)

            let host = try #require(SSHConfigParser.parse(rootConfig: config).first { $0.alias == "staging" })
            try SSHConfigStore.remove(alias: "staging", from: host.definitions)

            #expect(try String(contentsOf: included, encoding: .utf8) == "Host production\n    User root\n")
        }
    }
}
