import Foundation
import RelayProtocol

/// Explains a session that has not produced anything yet.
///
/// A shell can stall before printing a single byte — most often because a
/// command substitution in the user's startup files is blocked, which on macOS
/// usually means a permission dialog is waiting behind another window. Without
/// this the session just sits at "Starting" with an empty terminal and no clue.
enum StartupDiagnostics {
    /// How long a session may take to produce output before it looks stuck.
    static let patience: TimeInterval = 8

    static func hint(for snapshot: SessionSnapshot, now: Date = Date()) -> String? {
        guard snapshot.status == .starting else { return nil }
        guard now.timeIntervalSince(snapshot.startedAt) >= patience else { return nil }
        return """
        Still starting after \(Int(now.timeIntervalSince(snapshot.startedAt)))s and no output yet.

        Relay launches sessions through your login shell. If macOS is showing a \
        permission dialog, approve it — your shell startup is blocked until you do. \
        Otherwise check your ~/.zshrc for a command that never returns.
        """
    }
}
