import Foundation
import Testing

@testable import RelayAppKit

@Suite("Leaving the copy macOS runs a download from")
struct TranslocationTests {
    @Test("A bundle run where it lies has no other location")
    func ordinaryBundleIsNotTranslocated() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try makeBundle(identifier: "com.maketryuk.relay", in: directory)

        // Asked of Security itself, so this is also the proof that the two
        // functions were found and called with the shape they have.
        #expect(Translocation.originalLocation(of: bundle) == nil)
    }

    @Test("The flag goes from the bundle and everything in it")
    func quarantineIsClearedThroughout() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try makeBundle(identifier: "com.maketryuk.relay", in: directory)
        let executable = bundle.appendingPathComponent("Contents/MacOS/Relay")
        try quarantine(bundle)
        try quarantine(executable)

        #expect(Translocation.clearQuarantine(of: bundle))
        #expect(!isQuarantined(bundle))
        #expect(!isQuarantined(executable))
    }

    @Test("A bundle whose flag cannot be removed says so")
    func unwritableBundleKeepsItsFlag() throws {
        // What a disk image looks like from here: the flag is there and
        // nothing this process does can take it off.
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let bundle = try makeBundle(identifier: "com.maketryuk.relay", in: directory)
        try quarantine(bundle)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: bundle.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.path) }

        #expect(!Translocation.clearQuarantine(of: bundle))
    }

    @Test("A copy put in Applications carries no flag")
    func installedCopyIsNotQuarantined() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeBundle(identifier: "com.maketryuk.relay", in: directory.appendingPathComponent("image"))
        try quarantine(source)
        try quarantine(source.appendingPathComponent("Contents/MacOS/Relay"))
        let applications = directory.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let destination = applications.appendingPathComponent("Relay.app")

        try Translocation.install(source, at: destination)

        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("Contents/MacOS/Relay").path))
        #expect(!isQuarantined(destination))
        #expect(!isQuarantined(destination.appendingPathComponent("Contents/MacOS/Relay")))
        // A copy that went wrong halfway would have left its staging folder.
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["Relay.app"])
    }

    @Test("An earlier copy of Relay is replaced")
    func earlierCopyIsReplaced() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeBundle(identifier: "com.maketryuk.relay", in: directory.appendingPathComponent("image"))
        let applications = directory.appendingPathComponent("Applications")
        let earlier = try makeBundle(identifier: "com.maketryuk.relay", in: applications)
        let leftover = earlier.appendingPathComponent("Contents/Resources/only-in-the-old-one")
        try FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: leftover)

        try Translocation.install(source, at: earlier)

        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: earlier.appendingPathComponent("Contents/MacOS/Relay").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: applications.path) == ["Relay.app"])
    }

    @Test("Another application with the same name is left alone")
    func strangerIsNotReplaced() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeBundle(identifier: "com.maketryuk.relay", in: directory.appendingPathComponent("image"))
        let stranger = try makeBundle(identifier: "org.example.relay", in: directory.appendingPathComponent("Applications"))

        #expect(throws: Translocation.InstallFailure.occupied(stranger.path)) {
            try Translocation.install(source, at: stranger)
        }
        let info = NSDictionary(contentsOf: stranger.appendingPathComponent("Contents/Info.plist"))
        #expect(info?["CFBundleIdentifier"] as? String == "org.example.relay")
    }

    // MARK: - Fixtures

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-translocation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeBundle(identifier: String, in directory: URL) throws -> URL {
        let bundle = directory.appendingPathComponent("Relay.app", isDirectory: true)
        let executables = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: executables, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: executables.appendingPathComponent("Relay"))
        let info: NSDictionary = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Relay"]
        try info.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        return bundle
    }

    /// The value a browser writes: flags, time, the agent that downloaded it.
    private func quarantine(_ url: URL) throws {
        let value = "0081;66f5a3c1;Dia;"
        let result = value.withCString { pointer in
            setxattr(url.path, Translocation.quarantineAttribute, pointer, strlen(pointer), 0, XATTR_NOFOLLOW)
        }
        try #require(result == 0)
    }

    private func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, Translocation.quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }
}
