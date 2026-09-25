import AppKit
import Foundation
import RelayProtocol
import RelayUI

/// Downloads a release and puts it in place of the running application.
///
/// An application cannot replace its own bundle while it is running, so the last
/// step is handed to a short script that waits for Relay to quit, swaps the two
/// directories and starts the new one. The swap moves the old bundle aside
/// before moving the new one in, and puts it back if that fails — an update that
/// leaves no application behind is worse than one that does not happen.
enum UpdateInstaller {
    /// Everything that can stop an update, phrased for the person watching it
    /// fail. Deliberately not a `LocalizedError`: the text is only ever read to
    /// be shown, and reading it needs the main actor, which that protocol has no
    /// way to say.
    enum Failure: Error {
        case downloadFailed(String)
        case archiveUnreadable
        case noApplicationInArchive
        case signatureInvalid
        /// Signed, but by a team other than the one this copy is signed by.
        case signedBySomeoneElse
        case notWritable(String)

        @MainActor
        var message: String {
            switch self {
            case let .downloadFailed(reason):
                String(format: relayLocalized("The download failed: %@"), reason)
            case .archiveUnreadable:
                relayLocalized("The downloaded archive could not be opened.")
            case .noApplicationInArchive:
                relayLocalized("The download did not contain Relay.")
            case .signatureInvalid:
                String(format: relayLocalized("The downloaded copy was rejected: %@"), relayLocalized("its signature is not valid"))
            case .signedBySomeoneElse:
                String(format: relayLocalized("The downloaded copy was rejected: %@"), relayLocalized("it was signed by someone else"))
            case let .notWritable(path):
                String(format: relayLocalized("Relay cannot replace itself at %@."), path)
            }
        }
    }

    /// Fetches the release and leaves an unpacked, checked bundle in a temporary
    /// directory, ready to be swapped in.
    static func stage(
        _ release: Release,
        session: URLSession = .shared,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let workspace = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        let archive = workspace.appendingPathComponent("Relay.app.zip")
        try await download(release.downloadURL, to: archive, session: session, onProgress: onProgress)

        let unpacked = workspace.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]) == 0 else {
            throw Failure.archiveUnreadable
        }

        guard let bundle = application(in: unpacked) else { throw Failure.noApplicationInArchive }
        try verify(bundle)
        return bundle
    }

    /// Replaces the running application and restarts it.
    ///
    /// Returns once the handover script is running; the caller's next move is to
    /// quit, which is what the script is waiting for.
    static func install(_ staged: URL, replacing target: URL) throws {
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw Failure.notWritable(target.path)
        }

        let script = """
        #!/bin/sh
        set -e
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
        backup="\(target.path).previous"
        rm -rf "$backup"
        mv "\(target.path)" "$backup"
        if mv "\(staged.path)" "\(target.path)"; then
          rm -rf "$backup"
        else
          mv "$backup" "\(target.path)"
        fi
        open "\(target.path)"
        """

        let handover = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-install-\(UUID().uuidString).sh")
        try script.write(to: handover, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [handover.path]
        try process.run()
    }

    // MARK: - Pieces

    private static func download(
        _ url: URL,
        to destination: URL,
        session: URLSession,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        // The only thing Relay ever tells GitHub about itself.
        request.setValue("Relay/\(RelayVersion.current)", forHTTPHeaderField: "User-Agent")

        do {
            let (bytes, response) = try await session.bytes(for: request)
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw Failure.downloadFailed("HTTP \(http.statusCode)")
            }

            let expected = response.expectedContentLength
            var data = Data()
            data.reserveCapacity(expected > 0 ? Int(expected) : 1 << 22)
            for try await byte in bytes {
                data.append(byte)
                if expected > 0, data.count % (256 * 1024) == 0 {
                    onProgress(Double(data.count) / Double(expected))
                }
            }
            onProgress(1)
            try data.write(to: destination)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.downloadFailed(error.localizedDescription)
        }
    }

    private static func application(in directory: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.first { $0.pathExtension == "app" }
    }

    /// Refuses a download that is not signed the way this copy is.
    ///
    /// Relay is not notarised, so this cannot appeal to Apple; what it can do is
    /// insist that the new bundle carries the same team as the one already
    /// running. That is the difference between "an update to this application"
    /// and "an application someone else built".
    private static func verify(_ bundle: URL) throws {
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.path]) == 0 else {
            throw Failure.signatureInvalid
        }
        let incoming = teamIdentifier(of: bundle)
        let current = teamIdentifier(of: Bundle.main.bundleURL)
        guard incoming == current else {
            throw Failure.signedBySomeoneElse
        }
    }

    private static func teamIdentifier(of bundle: URL) -> String? {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-d", "--verbose=2", bundle.path]
        process.standardError = pipe
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return output
            .split(separator: "\n")
            .first { $0.hasPrefix("TeamIdentifier=") }
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
