import Foundation
import Testing

@testable import RelayProtocol

/// The daemon deliberately outlives the GUI, so a new client routinely meets an
/// old daemon and vice versa. These tests pin the encoding of the messages that
/// the upgrade path depends on: if a change breaks them, a user's running
/// sessions become unreachable rather than merely inconvenient.
@Suite("Wire format compatibility")
struct WireCompatibilityTests {
    private let encoder = MessageFraming.makeEncoder()
    private let decoder = MessageFraming.makeDecoder()

    private func json(_ value: some Encodable) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test("Handshake keeps its shape so a version mismatch can be detected at all")
    func handshakeEncoding() throws {
        let text = try json(DaemonRequest.handshake(protocolVersion: 2, clientName: "Relay GUI"))
        #expect(text.contains("\"handshake\""))
        #expect(text.contains("\"protocolVersion\":2"))
        #expect(text.contains("\"clientName\":\"Relay GUI\""))
    }

    @Test("shutdownDaemon stays a bare case, which is what makes the upgrade work")
    func shutdownEncoding() throws {
        // A newer client sends this to a daemon that predates the version bump,
        // so its encoding must never gain fields.
        #expect(try json(DaemonRequest.shutdownDaemon) == "{\"shutdownDaemon\":{}}")
        #expect(try json(DaemonRequest.ping) == "{\"ping\":{}}")
        #expect(try json(DaemonRequest.listSessions) == "{\"listSessions\":{}}")
    }

    @Test("A frame written by an older client still decodes")
    func decodesLegacyFrames() throws {
        let legacy = "{\"requestID\":1,\"request\":{\"shutdownDaemon\":{}}}"
        let message = try decoder.decode(ClientMessage.self, from: Data(legacy.utf8))
        #expect(message.requestID == 1)
        guard case .shutdownDaemon = message.request else {
            Issue.record("Expected shutdownDaemon")
            return
        }
    }

    @Test("A protocol mismatch reply is understandable to an older client")
    func failureEncoding() throws {
        let text = try json(ServerMessage.failure(requestID: 1, DaemonError.protocolMismatch(1)))
        #expect(text.contains("\"failure\""))
        #expect(text.contains("\"protocol_mismatch\""))
    }

    @Test("The declared protocol version is ahead of the original release")
    func versionMovedForward() {
        // Milestone 1 shipped version 1; roles and the new queries are version 2.
        #expect(RelayProtocolVersion.current >= 2)
    }
}

@Suite("Build identity")
struct BuildIdentityTests {
    @Test("An executable hashes to a stable short identity")
    func hashesFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("a")
        try Data(repeating: 0xAB, count: 4096).write(to: first)

        let identity = try #require(BuildIdentity.of(executableAt: first))
        #expect(identity.count == 16)
        #expect(BuildIdentity.of(executableAt: first) == identity)
    }

    @Test("Identical binaries at different paths share an identity")
    func contentNotPath() throws {
        // Installing the app elsewhere must not look like a different build.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let payload = Data(repeating: 0x5A, count: 8192)
        let first = directory.appendingPathComponent("build/relay-daemon")
        let second = directory.appendingPathComponent("installed/relay-daemon")
        for url in [first, second] {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try payload.write(to: url)
        }
        #expect(BuildIdentity.of(executableAt: first) == BuildIdentity.of(executableAt: second))
    }

    @Test("Different contents produce different identities")
    func differentContent() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("a")
        let second = directory.appendingPathComponent("b")
        try Data(repeating: 0x01, count: 1024).write(to: first)
        try Data(repeating: 0x02, count: 1024).write(to: second)
        #expect(BuildIdentity.of(executableAt: first) != BuildIdentity.of(executableAt: second))
    }

    @Test("A missing file has no identity rather than a fake one")
    func missingFile() {
        #expect(BuildIdentity.of(executableAt: URL(fileURLWithPath: "/nope/relay-daemon")) == nil)
    }

    @Test("The running process can identify itself")
    func currentIsUsable() {
        #expect(!BuildIdentity.current.isEmpty)
    }
}
