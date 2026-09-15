import Darwin
import Foundation
import Testing

@testable import RelayDaemonCore

/// The daemon holds a log handle and a live IPC socket per connected client.
/// A spawned agent must inherit none of them.
@Suite("Descriptor inheritance", .serialized)
struct DescriptorInheritanceTests {
    @Test("A child cannot write through a descriptor the daemon left open")
    func childDoesNotInheritDaemonDescriptors() throws {
        // Stand in for the daemon's log file and client sockets: a plain
        // descriptor with no FD_CLOEXEC, exactly as `open` and `accept` return.
        // Counting descriptor numbers would be ambiguous, so the child is asked
        // to actually write through the number — the file contents settle it.
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-fd-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let leaked = open(temporary.path, O_WRONLY)
        #expect(leaked >= 3)
        #expect(fcntl(leaked, F_GETFD) & FD_CLOEXEC == 0)
        defer { close(leaked) }

        let plan = PTYProcess.LaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", "echo LEAKED >&\(leaked) && echo wrote || echo blocked"],
            workingDirectory: "/tmp",
            environment: ["PATH": "/usr/bin:/bin"],
            columns: 80,
            rows: 24
        )
        let process = try PTYProcess.launch(plan)
        let box = OutputBox()
        process.startStreaming(onOutput: { box.append($0) }, onExit: { box.finish(code: $0) })
        box.waitForEitherOutcome()
        process.close()

        // The file settles it. Which branch the shell took does not: once the
        // descriptor is closed its *number* is free, and `sh` is entitled to
        // put one of its own there — so `>&N` can succeed, write to the
        // terminal, and prove nothing. Seen failing exactly that way.
        let contents = (try? String(contentsOf: temporary, encoding: .utf8)) ?? ""
        #expect(!contents.contains("LEAKED"))
        // And the child did run, so the empty file is a refusal rather than a
        // command that never happened.
        #expect(box.ranToACompletion, "the child produced: \(box.text.debugDescription)")
    }

    @Test("A descriptor above the child's closing range is still not inherited")
    func highNumberedDescriptorIsNotInherited() throws {
        // `getdtablesize()` is tens of thousands on macOS, so the child cannot
        // loop the whole table and `closefrom` does not exist. A descriptor
        // beyond whatever cap the child uses has to be handled in the parent,
        // and this is the case that caught it.
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-fd-high-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temporary.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let low = open(temporary.path, O_WRONLY)
        #expect(low >= 3)
        defer { close(low) }

        // Force a high descriptor number, past any plausible child-side cap.
        // A machine whose descriptor limit is below that — a CI runner often
        // is — cannot make the point at all, and saying so is better than
        // asserting something else by accident.
        let high = fcntl(low, F_DUPFD, 5000)
        try #require(high >= 5000, "this machine's descriptor limit is too low to place one at 5000")
        defer { close(high) }

        let plan = PTYProcess.LaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", "echo LEAKED >&\(high) && echo wrote || echo blocked"],
            workingDirectory: "/tmp",
            environment: ["PATH": "/usr/bin:/bin"],
            columns: 80,
            rows: 24
        )
        let child = try PTYProcess.launch(plan)
        let box = OutputBox()
        child.startStreaming(onOutput: { box.append($0) }, onExit: { box.finish(code: $0) })
        box.waitForEitherOutcome()
        child.close()

        let contents = (try? String(contentsOf: temporary, encoding: .utf8)) ?? ""
        #expect(!contents.contains("LEAKED"))
        #expect(box.ranToACompletion, "the child produced: \(box.text.debugDescription)")
    }

    @Test("The pty master is close-on-exec so a grandchild cannot hold the session open")
    func masterIsCloseOnExec() throws {
        let plan = PTYProcess.LaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", "exit 0"],
            workingDirectory: "/tmp",
            environment: ["PATH": "/usr/bin:/bin"],
            columns: 80,
            rows: 24
        )
        let process = try PTYProcess.launch(plan)
        defer { process.close() }
        #expect(fcntl(process.masterFD, F_GETFD) & FD_CLOEXEC != 0)
    }
}
