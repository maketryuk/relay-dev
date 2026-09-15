import Darwin
import Foundation

/// A child process attached to a pseudo-terminal.
///
/// The daemon owns the master side; the child sees a real tty, which is what
/// makes zsh, vim, fzf, Claude Code and ssh behave normally.
public final class PTYProcess: @unchecked Sendable {
    public struct LaunchPlan: Sendable {
        public var executable: String
        public var arguments: [String]
        public var workingDirectory: String
        public var environment: [String: String]
        public var columns: Int
        public var rows: Int
    }

    public enum LaunchError: Error, CustomStringConvertible {
        case forkFailed(Int32)

        public var description: String {
            switch self {
            case let .forkFailed(code): "forkpty failed: \(String(cString: strerror(code)))"
            }
        }
    }

    public let masterFD: Int32
    public let pid: pid_t

    private var readSource: DispatchSourceRead?
    private var exitSource: DispatchSourceProcess?
    private var isClosed = false

    private init(masterFD: Int32, pid: pid_t) {
        self.masterFD = masterFD
        self.pid = pid
    }

    // MARK: - Launching

    /// Spawns the child on a freshly allocated pseudo-terminal.
    ///
    /// `forkpty` is used rather than `posix_spawn` because macOS, unlike Linux,
    /// does not hand a session leader a controlling terminal merely because it
    /// opened one — that requires `ioctl(TIOCSCTTY)` inside the child, which
    /// `posix_spawn` file actions cannot express. Without it zsh starts in
    /// non-interactive mode and Claude Code refuses to render at all.
    public static func launch(_ plan: LaunchPlan) throws -> PTYProcess {
        // Everything the child touches is allocated before the fork: after it,
        // only async-signal-safe calls are legal.
        let argv = CStringArray([plan.executable] + plan.arguments)
        let envp = CStringArray(plan.environment.map { "\($0.key)=\($0.value)" })
        let executablePath = strdup(plan.executable)
        let directoryPath = strdup(plan.workingDirectory)
        defer {
            argv.deallocate()
            envp.deallocate()
            free(executablePath)
            free(directoryPath)
        }

        var size = winsize(
            ws_row: UInt16(max(1, plan.rows)),
            ws_col: UInt16(max(1, plan.columns)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        // Mark everything the daemon has open as close-on-exec *before* forking.
        // The child cannot do this reliably: `closefrom` does not exist on
        // macOS, and `getdtablesize()` here is 61440, so looping over the whole
        // table in the child is both slow and — if capped — incomplete. A
        // descriptor above the cap survived into spawned processes.
        Self.markOpenDescriptorsCloseOnExec()

        var master: Int32 = -1
        let childPID = forkpty(&master, nil, nil, &size)

        if childPID == 0 {
            // --- child ---
            _ = chdir(directoryPath)

            // Backstop for anything another thread opened between the marking
            // above and the fork. Descriptors 0/1/2 are the pty and must survive.
            let limit = min(getdtablesize(), 4096)
            var descriptor: Int32 = 3
            while descriptor < limit {
                _ = Darwin.close(descriptor)
                descriptor += 1
            }

            // Signal dispositions and the blocked mask both survive `exec`, and
            // the daemon inherits `SIGHUP: SIG_IGN` from being launched
            // detached. Without this reset every session would ignore SIGHUP
            // and the Terminate action would silently do nothing.
            for number in [SIGHUP, SIGINT, SIGQUIT, SIGPIPE, SIGTERM, SIGTSTP, SIGTTIN, SIGTTOU, SIGCHLD, SIGWINCH] {
                signal(number, SIG_DFL)
            }
            var empty = sigset_t()
            sigemptyset(&empty)
            sigprocmask(SIG_SETMASK, &empty, nil)

            execve(executablePath, argv.pointer, envp.pointer)
            _exit(127)
        }

        guard childPID > 0 else { throw LaunchError.forkFailed(errno) }

        // The master must not leak into any later child.
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        // Non-blocking reads let one dispatch handler drain everything available.
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        return PTYProcess(masterFD: master, pid: childPID)
    }

    // MARK: - Streaming

    /// Starts delivering PTY output, by default on `DaemonQueue.shared`.
    ///
    /// The queue is a parameter so a test can exercise one process in isolation.
    /// Sharing the daemon's queue is what gives terminal output its ordering,
    /// and it also means anything else using that queue can delay delivery —
    /// which is correct for the daemon and merely noise for a unit test.
    public func startStreaming(
        on queue: DispatchQueue = DaemonQueue.shared,
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        let read = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        read.setEventHandler { [weak self] in
            guard let self else { return }
            self.drainAvailableOutput(into: onOutput)
        }
        readSource = read
        read.resume()

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self] in
            guard let self else { return }
            // Drained *before* the child is reaped, and the order is the whole
            // point: on macOS it is reaping, not exiting, that tears the pty
            // down and discards whatever is still buffered in it. Measured, not
            // assumed — reading after the reap lost the output 30 times out of
            // 30. A command that prints why it failed and exits in the same
            // breath would have printed into nothing.
            self.drainAvailableOutput(into: onOutput)
            onExit(self.reapExitCode())
        }
        exitSource = exit
        exit.resume()
    }

    private func drainAvailableOutput(into sink: @Sendable (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { pointer in
                read(masterFD, pointer.baseAddress, pointer.count)
            }
            if count > 0 {
                sink(Data(buffer[0 ..< count]))
                continue
            }
            // 0 means the slave closed; negative with EAGAIN means "nothing more
            // right now". EIO is how macOS reports a hung-up PTY.
            break
        }
    }

    private func reapExitCode() -> Int32 {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        guard result == pid else { return 0 }
        if status & 0x7F == 0 {
            return (status >> 8) & 0xFF
        }
        return 128 + (status & 0x7F)
    }

    // MARK: - Control

    public func write(_ data: Data) {
        guard !isClosed, !data.isEmpty else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(masterFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if errno == EAGAIN || errno == EINTR {
                    continue
                } else {
                    break
                }
            }
        }
    }

    public func resize(columns: Int, rows: Int) {
        guard !isClosed else { return }
        Self.setWindowSize(masterFD: masterFD, columns: columns, rows: rows)
    }

    /// Polite shutdown: SIGHUP to the whole process group, the same signal a
    /// closing terminal window sends.
    public func terminate() {
        guard !isClosed else { return }
        killpg(pid, SIGHUP)
        kill(pid, SIGHUP)
    }

    /// True while the child has not been reaped.
    public var isRunning: Bool {
        guard !isClosed else { return false }
        return kill(pid, 0) == 0
    }

    public func forceKill() {
        guard !isClosed else { return }
        killpg(pid, SIGKILL)
        kill(pid, SIGKILL)
    }

    /// Where reaping waits, so that nothing else has to.
    private static let reaping = DispatchQueue(
        label: "studio.lince.relay.daemon.reaping",
        qos: .utility,
        attributes: .concurrent
    )

    /// Waits briefly for an already-signalled child to be reaped.
    ///
    /// Without this the daemon leaves zombies behind whenever it tears sessions
    /// down, because cancelling the exit source also removes the only place
    /// `waitpid` was being called.
    public func reap(timeout: TimeInterval = 0.5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) { return }
            usleep(5_000)
        }
    }

    /// The same wait, somewhere it cannot be felt.
    ///
    /// A reap is a wait, and waits have no business on the queue that carries
    /// terminal output: tearing down ten sessions held it for up to five
    /// seconds, during which no pane drew a character and no keystroke landed.
    /// The child has already been signalled, and nothing upstream needs the
    /// answer — the point is only that the zombie goes away.
    public func reapDetached(timeout: TimeInterval = 2) {
        let identifier = pid
        Self.reaping.async {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                var status: Int32 = 0
                let result = waitpid(identifier, &status, WNOHANG)
                if result == identifier || (result == -1 && errno == ECHILD) { return }
                usleep(5_000)
            }
        }
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        Darwin.close(masterFD)
    }

    /// Sets `FD_CLOEXEC` on every descriptor this process currently holds,
    /// except the standard three.
    ///
    /// Done in the parent, where enumerating is safe: after `fork` only
    /// async-signal-safe calls are legal, which rules this out.
    private static func markOpenDescriptorsCloseOnExec() {
        let bufferSize = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        guard bufferSize > 0 else { return }

        let capacity = Int(bufferSize) / MemoryLayout<proc_fdinfo>.stride + 16
        var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
        let written = entries.withUnsafeMutableBytes { raw in
            proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, raw.baseAddress, Int32(raw.count))
        }
        guard written > 0 else { return }

        let count = Int(written) / MemoryLayout<proc_fdinfo>.stride
        for index in 0 ..< min(count, entries.count) {
            let descriptor = entries[index].proc_fd
            guard descriptor > 2 else { continue }
            let flags = fcntl(descriptor, F_GETFD)
            guard flags >= 0, flags & FD_CLOEXEC == 0 else { continue }
            _ = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC)
        }
    }

    static func setWindowSize(masterFD: Int32, columns: Int, rows: Int) {
        var size = winsize(
            ws_row: UInt16(max(1, rows)),
            ws_col: UInt16(max(1, columns)),
            ws_xpixel: 0,
            ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &size)
    }
}
