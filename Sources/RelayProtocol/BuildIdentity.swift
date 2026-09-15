import CryptoKit
import Foundation

/// Identifies which build of the daemon binary is running.
///
/// The daemon deliberately outlives the GUI, so a rebuilt app routinely meets a
/// daemon started from the previous build. Protocol versioning only catches the
/// subset of changes that alter the wire format; everything else — a fixed
/// scan, a new heuristic — would silently keep running the old code until
/// someone killed the process by hand.
///
/// Hashing the binary's contents rather than its path or timestamp means an
/// identical daemon installed somewhere else is correctly treated as the same
/// build, so copying the app does not cause a pointless restart.
public enum BuildIdentity {
    /// Short content hash of an executable, or `nil` if it cannot be read.
    public static func of(executableAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Identity of the currently running executable.
    public static let current: String = {
        guard let url = Bundle.main.executableURL, let identity = of(executableAt: url) else {
            return "unknown"
        }
        return identity
    }()
}
