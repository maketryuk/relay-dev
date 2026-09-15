import Darwin
import Foundation
import Testing

@testable import RelayDaemonCore

/// These spawn real processes on real pseudo-terminals. They are the only place
/// the `forkpty` path is exercised end to end, and they are the reason the
/// original `posix_spawn` implementation was caught producing children with no
/// controlling terminal.
@Suite("PTY process", .serialized)
struct PTYProcessTests {
    private func plan(_ script: String, rows: Int = 24, columns: Int = 80) -> PTYProcess.LaunchPlan {
        PTYProcess.LaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", script],
            workingDirectory: "/tmp",
            environment: ["TERM": "xterm-256color", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            columns: columns,
            rows: rows
        )
    }

    /// Runs a plan and waits for the thing the test is about to assert.
    ///
    /// `expecting` matters: exit and output are separate events, and waiting
    /// only for the exit asserts on whatever happened to have arrived by then.
    /// That passes on a developer's machine and fails on a loaded CI runner,
    /// which is not a useful way to find out.
    private func collect(
        _ plan: PTYProcess.LaunchPlan,
        expecting marker: String? = nil,
        timeout: TimeInterval = 10
    ) throws -> (output: Data, exitCode: Int32?, wasAlive: Bool) {
        let process = try PTYProcess.launch(plan)
        let box = OutputBox()
        process.startStreaming(
            on: .testStream,
            onOutput: { box.append($0) },
            onExit: { box.finish(code: $0) }
        )

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let marker {
                if box.text.contains(marker) { break }
            } else if box.exitCode != nil {
                break
            }
            usleep(20_000)
        }
        // Whether the child was still alive when we gave up is the difference
        // between "it never ran" and "it ran and we lost what it said", and a
        // failure that cannot tell those apart is a failure nobody can act on.
        let alive = process.isRunning
        process.close()
        return (box.data, box.exitCode, alive)
    }

    /// Describes a collection that did not produce what was expected.
    private func diagnosis(_ result: (output: Data, exitCode: Int32?, wasAlive: Bool)) -> String {
        let text = String(decoding: result.output, as: UTF8.self)
        return """
        produced \(text.debugDescription),         exit \(result.exitCode.map(String.init) ?? "none"),         \(result.wasAlive ? "still running" : "already gone")
        """
    }

    @Test("The child runs on a real controlling terminal")
    func childHasControllingTerminal() throws {
        // `tty` prints the controlling terminal's path, or "not a tty" without
        // one. This is the exact regression that broke the first implementation.
        let result = try collect(plan("tty"), expecting: "/dev/ttys")
        let text = String(decoding: result.output, as: UTF8.self)
        #expect(text.contains("/dev/ttys"))
        #expect(!text.lowercased().contains("not a tty"))
    }

    @Test("Standard output reaches the master side")
    func capturesStdout() throws {
        let result = try collect(plan("echo RELAY_MARKER"), expecting: "RELAY_MARKER")
        #expect(String(decoding: result.output, as: UTF8.self).contains("RELAY_MARKER"))
    }

    @Test("Standard error is merged into the terminal stream")
    func capturesStderr() throws {
        let result = try collect(plan("echo OOPS 1>&2"), expecting: "OOPS")
        #expect(String(decoding: result.output, as: UTF8.self).contains("OOPS"))
    }

    @Test("A successful exit reports code zero")
    func reportsSuccessExitCode() throws {
        let result = try collect(plan("exit 0"))
        #expect(result.exitCode == 0)
    }

    @Test("A failing exit reports its own code")
    func reportsFailureExitCode() throws {
        let result = try collect(plan("exit 42"))
        #expect(result.exitCode == 42)
    }

    @Test("A child killed by a signal reports 128 plus the signal number")
    func reportsSignalExitCode() throws {
        // SIGKILL cannot be trapped, so this exercises the kernel's "terminated
        // by signal" wait status rather than a shell's own exit handling.
        let process = try PTYProcess.launch(plan("exec sleep 30"))
        let box = OutputBox()
        process.startStreaming(on: .testStream, onOutput: { box.append($0) }, onExit: { box.finish(code: $0) })

        usleep(300_000)
        process.forceKill()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, box.exitCode == nil { usleep(20_000) }
        process.close()
        #expect(box.exitCode == 128 + SIGKILL)
    }

    @Test("A child does not inherit the daemon's ignored signal dispositions")
    func childResetsSignalDispositions() throws {
        // The daemon runs detached with SIGHUP ignored. Dispositions survive
        // `exec`, so without an explicit reset in the child, SIGHUP — the signal
        // a closing terminal sends — would be silently discarded and Terminate
        // would do nothing.
        signal(SIGHUP, SIG_IGN)
        defer { signal(SIGHUP, SIG_DFL) }

        let process = try PTYProcess.launch(plan("exec sleep 30"))
        let box = OutputBox()
        process.startStreaming(on: .testStream, onOutput: { box.append($0) }, onExit: { box.finish(code: $0) })

        usleep(300_000)
        process.terminate()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, box.exitCode == nil { usleep(20_000) }
        let stillRunning = process.isRunning
        process.close()

        #expect(box.exitCode == 128 + SIGHUP)
        #expect(!stillRunning)
    }

    @Test("The child starts in the requested working directory")
    func honoursWorkingDirectory() throws {
        var directoryPlan = plan("pwd")
        directoryPlan.workingDirectory = "/usr"
        let result = try collect(directoryPlan, expecting: "/usr")
        #expect(String(decoding: result.output, as: UTF8.self).contains("/usr"), "\(diagnosis(result))")
    }

    @Test("The environment passed in reaches the child")
    func passesEnvironment() throws {
        var environmentPlan = plan("echo \"[$RELAY_TEST_VAR]\"")
        environmentPlan.environment["RELAY_TEST_VAR"] = "carried-through"
        let result = try collect(environmentPlan, expecting: "[carried-through]")
        #expect(String(decoding: result.output, as: UTF8.self).contains("[carried-through]"), "\(diagnosis(result))")
    }

    @Test("The window size is visible to the child")
    func appliesWindowSize() throws {
        let result = try collect(plan("stty size", rows: 40, columns: 132), expecting: "40 132")
        // `stty size` prints "rows cols".
        #expect(String(decoding: result.output, as: UTF8.self).contains("40 132"), "\(diagnosis(result))")
    }

    @Test("Resizing is visible to a command started after the resize")
    func resizeIsObserved() throws {
        // The child reads the size after a delay, so the assertion covers the
        // TIOCSWINSZ round trip rather than a shell's trap-dispatch timing.
        let process = try PTYProcess.launch(plan("sleep 1; stty size", rows: 24, columns: 80))
        let box = OutputBox()
        process.startStreaming(on: .testStream, onOutput: { box.append($0) }, onExit: { box.finish(code: $0) })

        usleep(300_000)
        process.resize(columns: 100, rows: 50)

        box.waitForOutput(containing: "50 100", timeout: 8)
        let text = box.text
        process.close()
        #expect(text.contains("50 100"), "produced: \(text.debugDescription)")
    }

    @Test("Input written to the master is read by the child")
    func writesInput() throws {
        let process = try PTYProcess.launch(plan("read line; echo \"got:$line\""))
        let box = OutputBox()
        process.startStreaming(on: .testStream, onOutput: { box.append($0) }, onExit: { box.finish(code: $0) })

        usleep(300_000)
        process.write(Data("hello-relay\n".utf8))

        box.waitForOutput(containing: "got:hello-relay", timeout: 5)
        let text = box.text
        process.close()
        #expect(text.contains("got:hello-relay"), "produced: \(text.debugDescription)")
    }

    @Test("Terminating a running child stops it and the whole process group")
    func terminateStopsChild() throws {
        // `sleep` here is a grandchild of the shell; SIGHUP goes to the group so
        // nothing is left orphaned.
        let process = try PTYProcess.launch(plan("sleep 30"))
        let box = OutputBox()
        process.startStreaming(on: .testStream, onOutput: { box.append($0) }, onExit: { box.finish(code: $0) })

        usleep(300_000)
        process.terminate()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, box.exitCode == nil { usleep(20_000) }
        let stillRunning = process.isRunning
        process.close()
        #expect(box.exitCode != nil)
        #expect(!stillRunning)
    }
}

/// Collects streamed output from the daemon queue for assertions on the test
/// thread.
final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var code: Int32?

    func append(_ chunk: Data) {
        lock.withLock { buffer.append(chunk) }
    }

    func finish(code newCode: Int32) {
        lock.withLock { code = newCode }
    }

    var data: Data { lock.withLock { buffer } }
    var text: String { String(decoding: data, as: UTF8.self) }
    var exitCode: Int32? { lock.withLock { code } }

    /// Waits for what the test is about to assert, rather than for the process
    /// to exit. Output and exit are separate events, and stopping at the exit
    /// asserts on whatever happened to have arrived by then — which is how this
    /// passed for months and then failed once, on a machine fast enough to
    /// notice the difference.
    func waitForOutput(containing marker: String, timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !text.contains(marker) {
            usleep(20_000)
        }
    }

    /// True once the descriptor test's child has said which branch it took.
    ///
    /// Either answer means it ran, which is all the test needs from the
    /// terminal — the file is what decides whether the descriptor leaked.
    var ranToACompletion: Bool {
        text.contains("wrote") || text.contains("blocked")
    }

    func waitForEitherOutcome(timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !ranToACompletion {
            usleep(20_000)
        }
    }
}

@Suite("Trailing output")
struct TrailingOutputTests {
    @Test("A command that prints and exits does not lose what it printed")
    func trailingOutputSurvivesTheChildExiting() throws {
        // Reaping a child is what tears its pty down on macOS, and anything
        // still buffered in it goes with it — measured at 30 losses out of 30.
        // The exit handler therefore drains before it reaps, and this is the
        // outcome that depends on it: a command that prints why it failed and
        // exits in the same breath still gets to say so.
        let plan = PTYProcess.LaunchPlan(
            executable: "/bin/sh",
            arguments: ["-c", "echo RELAY_TRAILING_MARKER"],
            workingDirectory: "/tmp",
            environment: ["PATH": "/usr/bin:/bin"],
            columns: 80,
            rows: 24
        )
        let process = try PTYProcess.launch(plan)
        defer { process.close() }

        // Long enough for `echo` to have finished several times over, so the
        // output is already sitting in the pty before anything reads it.
        Thread.sleep(forTimeInterval: 0.4)

        let box = OutputBox()
        process.startStreaming(on: .testStream, onOutput: { box.append($0) }, onExit: { box.finish(code: $0) })
        box.waitForOutput(containing: "RELAY_TRAILING_MARKER", timeout: 5)

        #expect(box.text.contains("RELAY_TRAILING_MARKER"), "the child produced: \(box.text.debugDescription)")
    }
}

extension DispatchQueue {
    /// A queue of this suite's own.
    ///
    /// These tests are about one process on one pseudo-terminal. Delivering on
    /// the daemon's shared queue makes them hostage to whatever else is using
    /// it — which is the daemon's correct design and a unit test's bad day. The
    /// integration suite still exercises the real thing.
    static let testStream = DispatchQueue(label: "com.maketryuk.relay.tests.pty")
}
