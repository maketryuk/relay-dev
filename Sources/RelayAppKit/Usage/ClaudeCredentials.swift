import Foundation

/// The access token Claude Code holds, read the way Claude Code stores it.
///
/// Relay borrows it rather than asking the user to log in twice: the token is
/// already on this machine, it belongs to the account whose limits the bar is
/// showing, and the only thing done with it is a read of that account's own
/// usage. It is never written anywhere, never logged, and never leaves the
/// request it is put in.
///
/// On macOS it lives in the keychain, which means the first read raises the
/// system's own permission sheet — the user decides once whether Relay may see
/// it, and a refusal is treated as absence: the bar falls back to the cache the
/// CLI leaves on disk.
enum ClaudeCredentials {
    /// The keychain item Claude Code writes. The name is the CLI's, not ours,
    /// and it is the whole reason this works without a second login.
    static let service = "Claude Code-credentials"

    /// Why there is no token, when there is none.
    ///
    /// Told apart because the answers differ: an account that has never logged
    /// in is worth asking about again in five minutes, and a keychain Relay has
    /// been told it may not read is not — raising that sheet on a timer would
    /// be a dialog every five minutes for as long as the app is open.
    enum Reading: Equatable {
        case token(String)
        case missing
        case refused
    }

    static func read() -> Reading {
        let item = keychainItem()
        if case let .token(stored) = item, let token = token(fromJSON: stored) {
            return .token(token)
        }
        if let data = try? Data(contentsOf: credentialsFile),
           let token = token(fromJSON: String(decoding: data, as: UTF8.self)) {
            return .token(token)
        }
        return item == .refused ? .refused : .missing
    }

    static var credentialsFile: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/.credentials.json")
    }

    static func token(fromJSON text: String) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty
        else { return nil }
        // `expiresAt` is deliberately not consulted: the endpoint is the
        // authority on whether a token still works, and a clock that disagrees
        // with it would refuse a request that would have succeeded.
        return token
    }

    /// Claude Code 2.1 stores the item under `$USER`, unless that name has a
    /// character it will not accept — an SSO login like `first@example.com` —
    /// in which case it uses a fixed name instead.
    static func account(for user: String) -> String {
        let accepted = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !user.isEmpty, user.unicodeScalars.allSatisfy(accepted.contains) else {
            return "claude-code-user"
        }
        return user
    }

    /// `security` answers 44 for an item that is not there, and something else
    /// for one it will not hand over — a refusal the user made at the sheet, or
    /// a policy that made it for them.
    private static let itemNotFound: Int32 = 44

    private static func keychainItem() -> Reading {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = [
            "find-generic-password",
            "-s", service,
            "-a", account(for: NSUserName()),
            "-w",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .missing
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return reading(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    static func reading(status: Int32, output: String) -> Reading {
        guard status == 0 else { return status == itemNotFound ? .missing : .refused }
        let item = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return item.isEmpty ? .missing : .token(item)
    }
}
