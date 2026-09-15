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

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, box.exitCode == nil { usleep(20_000) }
        process.close()

        let contents = (try? String(contentsOf: temporary, encoding: .utf8)) ?? ""
        #expect(!contents.contains("LEAKED"))
        #expect(String(decoding: box.data, as: UTF8.self).contains("blocked"))
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
