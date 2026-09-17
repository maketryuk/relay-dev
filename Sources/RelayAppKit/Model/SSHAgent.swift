import Foundation

/// Whether the key a host would use is already unlocked.
enum SSHAgentStatus: Equatable, Sendable {
    /// Nothing is running to hold a key, so `ssh` will ask every time.
    case noAgent
    /// The agent has it: no passphrase will be asked for.
    case loaded
    case notLoaded
    /// No key file to say anything about, or one that could not be read.
    case unknown
}

/// What `ssh-agent` is holding, and which key a host would reach for.
///
/// Relay never handles a passphrase. It asks the agent what it already has, and
/// when the key is missing it hands the job to `ssh-add` in a terminal the user
/// types into — which is the only place a passphrase belongs.
enum SSHAgent {
    /// OpenSSH's own default identity files, in the order it tries them.
    static let defaultKeyNames = ["id_ed25519", "id_ecdsa", "id_ecdsa_sk", "id_ed25519_sk", "id_rsa", "id_dsa"]

    /// The key a host would authenticate with: the one it names, or the first
    /// default that exists on disk.
    static func keyPath(forIdentityFile identityFile: String?, fileExists: (String) -> Bool = defaultFileExists)
        -> String?
    {
        if let identityFile, !identityFile.trimmingCharacters(in: .whitespaces).isEmpty {
            return expanding(identityFile)
        }
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        return defaultKeyNames
            .map { directory.appendingPathComponent($0).path }
            .first(where: fileExists)
    }

    /// The fingerprints the agent currently holds, or nil when there is no
    /// agent to ask.
    static func loadedFingerprints() -> Set<String>? {
        guard let result = Shell.capture("/usr/bin/ssh-add", arguments: ["-l"], timeout: 4) else { return nil }
        // 2 is "cannot connect to the agent"; 1 is an agent holding nothing,
        // which is an answer rather than a failure.
        guard result.status != 2 else { return nil }
        return Set(result.output.split(separator: "\n").compactMap { fingerprint(inListing: String($0)) })
    }

    /// The fingerprint of a key on disk.
    ///
    /// Read from the public half where there is one, so an encrypted private
    /// key is never opened and nothing is ever asked for.
    static func fingerprint(ofKeyAt path: String) -> String? {
        let expanded = expanding(path)
        let candidates = expanded.hasSuffix(".pub") ? [expanded] : [expanded + ".pub", expanded]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate) {
            guard let result = Shell.capture("/usr/bin/ssh-keygen", arguments: ["-lf", candidate], timeout: 4),
                  result.succeeded,
                  let fingerprint = fingerprint(inListing: result.output)
            else { continue }
            return fingerprint
        }
        return nil
    }

    /// `256 SHA256:Ab3… comment (ED25519)` — the fingerprint is the second
    /// field, and both `ssh-add -l` and `ssh-keygen -lf` print this shape.
    static func fingerprint(inListing line: String) -> String? {
        let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 2 else { return nil }
        let fingerprint = String(fields[1])
        return fingerprint.contains(":") ? fingerprint : nil
    }

    /// How handing a passphrase to `ssh-add` turned out.
    enum UnlockResult: Equatable, Sendable {
        case added
        case wrongPassphrase
        case failed(String)
    }

    /// Two lines that copy standard input to standard output.
    ///
    /// OpenSSH reads a passphrase from the controlling terminal unless it is
    /// told to ask a program instead, and it hands that program its own
    /// standard input. So the program need only pass it on, and the passphrase
    /// travels from the field to `ssh-add` down a pipe: never written to disk,
    /// never an argument and never in the environment, each of which any other
    /// process of this user could read.
    static let askpassScript = "#!/bin/sh\nexec cat\n"

    /// Unlocks the key and lets macOS remember it, without a terminal.
    ///
    /// Relay holds the passphrase only for as long as this call takes. What
    /// remembers it afterwards is the login keychain, and what reads it back on
    /// the next connection is `ssh` itself — Relay is not involved.
    static func add(keyAt path: String, passphrase: String) -> UnlockResult {
        let manager = FileManager.default
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-askpass-\(UUID().uuidString)", isDirectory: true)
        defer { try? manager.removeItem(at: directory) }

        let askpass = directory.appendingPathComponent("askpass")
        do {
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try Data(askpassScript.utf8).write(to: askpass)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: askpass.path)
        } catch {
            return .failed(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        process.arguments = ["--apple-use-keychain", NSString(string: path).expandingTildeInPath]
        process.environment = environment(askpass: askpass.path)

        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = Pipe()
        process.standardError = errors

        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }

        input.fileHandleForWriting.write(Data((passphrase + "\n").utf8))
        // Closed so the helper sees the end of the passphrase and exits; left
        // open, both it and `ssh-add` would wait for a second line forever.
        try? input.fileHandleForWriting.close()

        let reported = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return .added }
        return outcome(status: process.terminationStatus, reported: reported)
    }

    /// With no terminal to complain to, `ssh-add` refuses a wrong passphrase
    /// silently: a bare non-zero exit is the only thing it says.
    static func outcome(status: Int32, reported: String) -> UnlockResult {
        guard status != 0 else { return .added }
        let message = reported
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        return message.map(UnlockResult.failed) ?? .wrongPassphrase
    }

    private static func environment(askpass: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = askpass
        // `force` rather than the default, which only asks a program when there
        // is no terminal *and* DISPLAY is set — and a Mac has no DISPLAY.
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        if environment["SSH_AUTH_SOCK"]?.isEmpty != false {
            // launchd exports it to everything in the login session, but an app
            // started some other way may not have inherited it.
            environment["SSH_AUTH_SOCK"] = Shell.capture(
                "/bin/launchctl",
                arguments: ["getenv", "SSH_AUTH_SOCK"],
                timeout: 2
            )?.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return environment.compactMapValues { $0.isEmpty ? nil : $0 }
    }

    static func status(ofKey fingerprint: String?, in loaded: Set<String>?) -> SSHAgentStatus {
        guard let loaded else { return .noAgent }
        guard let fingerprint else { return .unknown }
        return loaded.contains(fingerprint) ? .loaded : .notLoaded
    }

    private static func expanding(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }

    private static func defaultFileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
