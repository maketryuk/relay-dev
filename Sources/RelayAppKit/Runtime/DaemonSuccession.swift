import Foundation

/// What to do about a daemon started by a different build of Relay.
///
/// The daemon deliberately outlives the GUI, so a new build routinely meets the
/// previous build's daemon — after an update, most of all, since the update
/// quits the app and starts the new one while the daemon carries on. Retiring
/// it unconditionally is what made every session die on every update: the
/// binary's hash changes with each build, and shutting the daemon down tears
/// down every PTY it is supervising.
///
/// So the rule is about what there is to lose rather than about the hash alone.
/// A daemon supervising nothing is replaced at once, which is the common case
/// and keeps the guarantee that new code does not talk to old code. A daemon
/// with sessions in it is kept: the protocol version has already been agreed at
/// the handshake, so the message set is compatible, and the alternative is
/// destroying the user's work to install a newer supervisor for work that no
/// longer exists.
enum DaemonSuccession {
    enum Decision: Equatable {
        /// This is our daemon, or close enough to be treated as such.
        case keep
        /// Shut it down and start the one this build ships with.
        case retire
        /// Keep using it, knowing it is the previous build's, until the sessions
        /// it holds are gone.
        case inherit
    }

    static func decide(
        daemonIdentity: String?,
        bundledIdentity: String?,
        supervisedSessions: Int
    ) -> Decision {
        // Nothing to compare: a daemon too old to report its build, or a bundle
        // whose helper cannot be read. Neither is grounds for killing sessions.
        guard let bundledIdentity, let daemonIdentity else { return .keep }
        guard daemonIdentity != bundledIdentity else { return .keep }
        return supervisedSessions == 0 ? .retire : .inherit
    }
}
