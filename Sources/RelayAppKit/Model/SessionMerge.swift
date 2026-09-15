import Foundation
import RelayProtocol

/// Decides whether an incoming snapshot is newer than the one already held.
///
/// Replies and events race. A reply to `createSession` carries the session as it
/// was when the daemon answered — always `starting` — while the events that
/// follow carry the state now. Applying the reply afterwards rewinds the
/// session, and for a process that starts and then goes quiet, like a dev
/// server, nothing ever arrives to correct it: it reads "Starting" forever.
enum SessionMerge {
    static func shouldApply(_ incoming: SessionSnapshot, over existing: SessionSnapshot?) -> Bool {
        guard let existing else { return true }
        guard incoming.id == existing.id else { return true }

        // An exit is final and can only be learnt once.
        if existing.exitCode != nil, incoming.exitCode == nil { return false }
        if incoming.exitCode != nil, existing.exitCode == nil { return true }

        return incoming.lastActivityAt >= existing.lastActivityAt
    }

    static func merging(_ incoming: SessionSnapshot, into sessions: inout [SessionID: SessionSnapshot]) {
        guard shouldApply(incoming, over: sessions[incoming.id]) else { return }
        sessions[incoming.id] = incoming
    }
}
