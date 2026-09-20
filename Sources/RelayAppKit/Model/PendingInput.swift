import Foundation
import RelayProtocol

/// Text waiting for a session that can take it.
///
/// A new agent cannot be typed into the moment it is asked for: the process is
/// still starting, the terminal is not on screen yet, and a prompt that is not
/// there drops what is sent to it. So the text waits, and what it is waiting
/// for is described by ``PendingInputPolicy``.
struct PendingInput: Equatable {
    let text: String
    /// Review notes to forget once the text has actually been handed over.
    ///
    /// They used to be forgotten at the moment the session was asked for, which
    /// is why a review could vanish from the panel without ever reaching the
    /// agent: if the hand-over never happened, nothing was left to hand over
    /// again.
    let commentIDs: [UUID]

    init(text: String, commentIDs: [UUID] = []) {
        self.text = text
        self.commentIDs = commentIDs
    }
}

enum PendingInputPolicy {
    /// Whether a session will keep what is typed into it.
    ///
    /// Two conditions, and both were learned by losing text. The status has to
    /// say the agent has stopped printing and is waiting for a person —
    /// anything typed while it is still working is echoed into a prompt that
    /// then redraws over it. And the terminal has to exist, because Relay asks
    /// it whether it understands a bracketed paste; without one the text is
    /// sent as plain keystrokes, and every newline in a review is a message
    /// sent early.
    static func isReady(status: RuntimeStatus, hasTerminal: Bool) -> Bool {
        guard hasTerminal else { return false }
        return status == .waiting || status == .idle
    }
}
