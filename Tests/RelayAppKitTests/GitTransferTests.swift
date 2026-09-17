import Foundation
import Testing

@testable import RelayAppKit

@Suite("Planning a pull or a push")
struct GitTransferTests {
    private func status(
        branch: String = "master",
        upstream: String? = "origin/master",
        ahead: Int = 0,
        behind: Int = 0
    ) -> GitStatus {
        GitStatus(
            branch: branch,
            isDirty: false,
            changedFiles: 0,
            ahead: ahead,
            behind: behind,
            upstream: upstream
        )
    }

    @Test("A pull runs against the branch's upstream")
    func pullDefaultsToUpstream() {
        let transfer = GitTransfer.initial(
            direction: .pull,
            status: status(branch: "feature", upstream: "upstream/feature"),
            remotes: ["origin", "upstream"]
        )
        #expect(transfer.remote == "upstream")
        #expect(transfer.branch == "feature")
        #expect(transfer.commandLine == "git pull --rebase upstream feature")
    }

    @Test("A branch with no upstream is pushed to the first remote, and told to follow it")
    func pushWithoutUpstream() {
        // Pushing a new branch and then having to say where it lives is the
        // same request twice.
        let transfer = GitTransfer.initial(
            direction: .push,
            status: status(branch: "spike", upstream: nil),
            remotes: ["origin"]
        )
        #expect(transfer.remote == "origin")
        #expect(transfer.branch == "spike")
        #expect(transfer.options == [.setUpstream])
        #expect(transfer.commandLine == "git push --set-upstream origin spike")
    }

    @Test("An upstream on a remote the repository no longer has is not used")
    func upstreamMustNameAKnownRemote() {
        let transfer = GitTransfer.initial(
            direction: .push,
            status: status(upstream: "gone/master"),
            remotes: ["origin"]
        )
        #expect(transfer.remote == "origin")
    }

    @Test("Pushing elsewhere spells both branches out")
    func refspecNamesBothSidesWhenTheyDiffer() {
        var transfer = GitTransfer.initial(direction: .push, status: status(), remotes: ["origin"])
        transfer.branch = "release"
        #expect(transfer.commandLine == "git push origin master:release")
        // The same name on both sides is the same request, said plainly.
        transfer.branch = "master"
        #expect(transfer.commandLine == "git push origin master")
    }

    @Test("Force pushing is with a lease, never bare")
    func forcePushKeepsItsLease() {
        var transfer = GitTransfer.initial(direction: .push, status: status(), remotes: ["origin"])
        transfer.set(.forceWithLease, true)
        #expect(transfer.commandLine == "git push --force-with-lease origin master")
    }

    @Test("Options that contradict each other cannot both be on")
    func exclusiveOptions() {
        var transfer = GitTransfer.initial(direction: .pull, status: status(), remotes: ["origin"])
        #expect(transfer.options.contains(.rebase))

        transfer.set(.fastForwardOnly, true)
        #expect(!transfer.options.contains(.rebase))
        #expect(transfer.options.contains(.fastForwardOnly))

        transfer.set(.rebase, true)
        #expect(!transfer.options.contains(.fastForwardOnly))
    }

    @Test("What the chosen options rule out is shown as unavailable")
    func availabilityFollowsWhatIsChosen() {
        var transfer = GitTransfer.initial(direction: .pull, status: status(), remotes: ["origin"])
        // `--rebase` is on by default, and git refuses every merge-shaping
        // flag alongside it.
        #expect(!transfer.isAvailable(.squash))
        #expect(!transfer.isAvailable(.noFastForward))
        #expect(!transfer.isAvailable(.noCommit))
        // The one that is chosen is not made unavailable by itself, or it
        // could never be turned off again.
        #expect(transfer.isAvailable(.rebase))
        // And what it has nothing to say about stays available.
        #expect(transfer.isAvailable(.autostash))
        #expect(transfer.isAvailable(.noVerify))

        transfer.set(.rebase, false)
        #expect(transfer.isAvailable(.squash))
    }

    @Test("Incompatibility is stated the same way from both sides")
    func exclusionIsSymmetric() {
        // Read from either option, the answer has to be the same one: the
        // panel asks in one direction and the command is built in the other.
        for first in GitTransfer.Option.allCases {
            for second in first.excludes {
                #expect(
                    second.excludes.contains(first),
                    "\(first.flag) excludes \(second.flag) but not the other way round"
                )
            }
        }
    }

    @Test("A flag belongs to the commands it is a flag of")
    func optionsBelongToTheirCommands() {
        #expect(GitTransfer.Option.all(for: .pull).contains(.squash))
        #expect(!GitTransfer.Option.all(for: .push).contains(.squash))
        // Hooks can be skipped either way round.
        #expect(GitTransfer.Option.all(for: .pull).contains(.noVerify))
        #expect(GitTransfer.Option.all(for: .push).contains(.noVerify))
    }

    @Test("The merge-shaping flags reach the command in git's own order")
    func pullFlagsAreSpelledOut() {
        var transfer = GitTransfer.initial(direction: .pull, status: status(), remotes: ["origin"])
        transfer.set(.rebase, false)
        transfer.set(.squash, true)
        transfer.set(.noVerify, true)
        #expect(transfer.commandLine == "git pull --squash --no-verify origin master")
    }

    @Test("Flags keep their order, whatever order they were chosen in")
    func flagOrderIsStable() {
        var transfer = GitTransfer.initial(direction: .push, status: status(), remotes: ["origin"])
        transfer.set(.tags, true)
        transfer.set(.forceWithLease, true)
        #expect(transfer.commandLine == "git push --force-with-lease --tags origin master")
    }

    @Test("An upstream is split at its first slash")
    func upstreamSplitting() {
        // A branch name may contain slashes; a remote name is what git matched
        // before the first one.
        #expect(GitTransfer.split(upstream: "origin/feature/x")?.remote == "origin")
        #expect(GitTransfer.split(upstream: "origin/feature/x")?.branch == "feature/x")
        #expect(GitTransfer.split(upstream: "master")?.remote == nil)
        #expect(GitTransfer.split(upstream: "origin/") == nil)
    }

    @Test("Only options belonging to the direction reach the command")
    func directionOwnsItsOptions() {
        var transfer = GitTransfer.initial(direction: .pull, status: status(), remotes: ["origin"])
        // A push flag left in the set by a panel that switched direction must
        // not be sent to `git pull`, which would refuse the whole command.
        transfer.options.insert(.forceWithLease)
        #expect(transfer.commandLine == "git pull --rebase origin master")
    }
}

@Suite("Reading remotes and outgoing commits")
struct GitTransferReaderTests {
    @Test("Remotes are read one per line")
    func remotesParse() {
        #expect(GitTransferReader.parse(remotes: "origin\nupstream\n") == ["origin", "upstream"])
        #expect(GitTransferReader.parse(remotes: "").isEmpty)
    }

    @Test("A commit is a short hash and whatever the subject says")
    func logParses() {
        let commits = GitTransferReader.parse(log: "a1b2c3d\tKeep the sessions\ne4f5g6h\tSay it once\n")
        #expect(commits.map(\.sha) == ["a1b2c3d", "e4f5g6h"])
        #expect(commits.first?.subject == "Keep the sessions")
    }

    @Test("A subject containing a tab keeps all of it")
    func subjectMayContainTabs() {
        let commits = GitTransferReader.parse(log: "a1b2c3d\tone\ttwo")
        #expect(commits.first?.subject == "one\ttwo")
    }

    @Test("A commit with no subject is still a commit")
    func emptySubject() {
        #expect(GitTransferReader.parse(log: "a1b2c3d\t").first?.subject == "")
        #expect(GitTransferReader.parse(log: "\tsubject").isEmpty)
    }
}
