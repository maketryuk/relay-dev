import Foundation
import Testing

@testable import RelayAppKit

@Suite("SSH agent")
struct SSHAgentTests {
    @Test("A fingerprint is read out of what ssh-add and ssh-keygen print")
    func readsFingerprints() {
        #expect(
            SSHAgent.fingerprint(inListing: "256 SHA256:9kL2q/ab+CD me@mac (ED25519)")
                == "SHA256:9kL2q/ab+CD"
        )
        // `ssh-keygen -lf` prints the same shape, comment and all.
        #expect(
            SSHAgent.fingerprint(inListing: "3072 SHA256:xY1z work key (RSA)")
                == "SHA256:xY1z"
        )
        #expect(SSHAgent.fingerprint(inListing: "The agent has no identities.") == nil)
        #expect(SSHAgent.fingerprint(inListing: "") == nil)
    }

    @Test("Not knowing the key and there being no agent are different answers")
    func statusDistinguishesItsThreeCases() {
        let held: Set<String> = ["SHA256:aaa"]
        #expect(SSHAgent.status(ofKey: "SHA256:aaa", in: held) == .loaded)
        #expect(SSHAgent.status(ofKey: "SHA256:bbb", in: held) == .notLoaded)
        #expect(SSHAgent.status(ofKey: "SHA256:aaa", in: []) == .notLoaded)
        // No agent at all: nothing can be loaded into one, so offering to is
        // offering something that cannot work.
        #expect(SSHAgent.status(ofKey: "SHA256:aaa", in: nil) == .noAgent)
        // No key to speak of, so the panel says nothing rather than guessing.
        #expect(SSHAgent.status(ofKey: nil, in: held) == .unknown)
    }

    @Test("The key a host uses is the one it names")
    func namedKeyWins() {
        let path = SSHAgent.keyPath(forIdentityFile: "~/.ssh/id_work") { _ in true }
        #expect(path?.hasSuffix("/.ssh/id_work") == true)
        // Expanded, because every process that has to open it needs a real path.
        #expect(path?.hasPrefix("~") == false)
    }

    @Test("A host that names no key falls back to the first default that exists")
    func fallsBackToTheDefaultKey() {
        // OpenSSH's own order, which is why a machine with both ed25519 and rsa
        // keys authenticates with the first of them.
        #expect(
            SSHAgent.keyPath(forIdentityFile: nil) { $0.hasSuffix("id_rsa") || $0.hasSuffix("id_ed25519") }?
                .hasSuffix("id_ed25519") == true
        )
        #expect(SSHAgent.keyPath(forIdentityFile: "  ") { $0.hasSuffix("id_rsa") }?.hasSuffix("id_rsa") == true)
        #expect(SSHAgent.keyPath(forIdentityFile: nil) { _ in false } == nil)
    }
}

@Suite("Unlocking a key")
struct SSHKeyUnlockTests {
    @Test("The helper only passes its input along, and carries no secret itself")
    func askpassScriptHoldsNothing() {
        // It is written to a file, so what it must never contain is the
        // passphrase: that arrives down the pipe `ssh-add` hands it.
        #expect(SSHAgent.askpassScript == "#!/bin/sh\nexec cat\n")
    }

    @Test("A silent refusal is a wrong passphrase")
    func silentFailureIsAWrongPassphrase() {
        // With no terminal to complain to, ssh-add rejects a bad passphrase by
        // exiting non-zero and saying nothing at all.
        #expect(SSHAgent.outcome(status: 1, reported: "") == .wrongPassphrase)
        #expect(SSHAgent.outcome(status: 1, reported: "\n  \n") == .wrongPassphrase)
    }

    @Test("Anything it does say is what the user is shown")
    func reportedFailureIsPassedOn() {
        #expect(
            SSHAgent.outcome(status: 1, reported: "Could not open a connection to your authentication agent.\n")
                == .failed("Could not open a connection to your authentication agent.")
        )
    }

    @Test("A clean exit is a key that is in")
    func successIsSuccess() {
        #expect(SSHAgent.outcome(status: 0, reported: "Identity added: probe") == .added)
    }
}
