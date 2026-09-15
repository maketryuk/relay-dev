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

        var master: Int32 = -1
        let childPID = forkpty(&master, nil, nil, &size)

        if childPID == 0 {
            // --- child ---
            _ = chdir(directoryPath)

            // Close everything the daemon had open. `forkpty` hands the child a
            // copy of the parent's descriptor table, and only descriptors marked
            // FD_CLOEXEC disappear at `execve` — so without this a spawned agent
            // inherits the daemon's log handle and, worse, its live IPC sockets.
            // Descriptors 0/1/2 are the pty and must survive.
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

    /// Starts delivering PTY output on `DaemonQueue.shared`.
    public func startStreaming(
        onOutput: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        let read = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: DaemonQueue.shared)
        read.setEventHandler { [weak self] in
            guard let self else { return }
            self.drainAvailableOutput(into: onOutput)
        }
        readSource = read
        read.resume()

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: DaemonQueue.shared)
        exit.setEventHandler { [weak self] in
            guard let self else { return }
            // Give the reader a chance to pick up the final bytes before we
            // report the exit upstream.
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

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        readSource?.cancel()
        readSource = nil
        exitSource?.cancel()
        exitSource = nil
        Darwin.close(masterFD)
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
