import Foundation
import Testing

@testable import RelayAppKit

@Suite("Meeting another build's daemon")
struct DaemonSuccessionTests {
    @Test("Its own daemon is kept")
    func matchingBuildIsKept() {
        #expect(DaemonSuccession.decide(
            daemonIdentity: "abc123",
            bundledIdentity: "abc123",
            supervisedSessions: 3
        ) == .keep)
    }

    @Test("An older daemon with nothing in it is replaced")
    func idleStrangerIsRetired() {
        // The guarantee worth keeping: new code does not talk to old code when
        // nothing is lost by saying so.
        #expect(DaemonSuccession.decide(
            daemonIdentity: "old",
            bundledIdentity: "new",
            supervisedSessions: 0
        ) == .retire)
    }

    @Test("An older daemon with sessions in it is inherited")
    func busyStrangerIsInherited() {
        // This is what an update used to cost: replacing the daemon tears down
        // every PTY it holds, so an update in the middle of an afternoon's work
        // ended all of it.
        #expect(DaemonSuccession.decide(
            daemonIdentity: "old",
            bundledIdentity: "new",
            supervisedSessions: 1
        ) == .inherit)
    }

    @Test("Nothing to compare is not grounds for ending sessions")
    func unknownIdentitiesAreKept() {
        // A daemon too old to report its build, or a bundle whose helper cannot
        // be read: neither says the daemon is the wrong one.
        #expect(DaemonSuccession.decide(
            daemonIdentity: nil,
            bundledIdentity: "new",
            supervisedSessions: 2
        ) == .keep)
        #expect(DaemonSuccession.decide(
            daemonIdentity: "old",
            bundledIdentity: nil,
            supervisedSessions: 2
        ) == .keep)
    }
}
