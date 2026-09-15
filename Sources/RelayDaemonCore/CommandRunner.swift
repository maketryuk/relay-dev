import Foundation

/// Outcome of a short-lived CLI call.
///
/// Exit status and stderr are carried alongside stdout because the tools Relay
/// shells out to put the interesting part in different places: `lsof` exits
/// non-zero when it simply found nothing, while `docker` says why it failed
/// only on stderr.
public struct CommandResult: Sendable {
    public var status: Int32
    public var standardOutput: String
    public var standardError: String
    public var timedOut: Bool

    public init(status: Int32, standardOutput: String, standardError: String, timedOut: Bool = false) {
        self.status = status
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 && !timedOut }
}

/// Runs short-lived CLI helpers (`ps`, `lsof`, `docker`).
///
/// The daemon shells out rather than linking system libraries because the spec
/// is explicit that Relay uses the tools the user already has installed.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult?
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String], timeout: TimeInterval = 5) -> CommandResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Both pipes must be drained concurrently: a child that fills one while
        // we block on the other would deadlock.
        let collector = PipeCollector()
        collector.begin(output: outputPipe, error: errorPipe)

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            process.terminate()
            let partial = collector.finish()
            return CommandResult(
                status: -1,
                standardOutput: partial.output,
                standardError: partial.error,
                timedOut: true
            )
        }

        let collected = collector.finish()
        return CommandResult(
            status: process.terminationStatus,
            standardOutput: collected.output,
            standardError: collected.error
        )
    }
}

/// Reads two pipes in parallel and hands back what they produced.
private final class PipeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data()
    private var error = Data()
    private let group = DispatchGroup()

    func begin(output outputPipe: Pipe, error errorPipe: Pipe) {
        read(outputPipe) { [weak self] data in
            self?.lock.withLock { self?.output.append(data) }
        }
        read(errorPipe) { [weak self] data in
            self?.lock.withLock { self?.error.append(data) }
        }
    }

    private func read(_ pipe: Pipe, into sink: @escaping @Sendable (Data) -> Void) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [group] in
            defer { group.leave() }
            sink(pipe.fileHandleForReading.readDataToEndOfFile())
        }
    }

    func finish() -> (output: String, error: String) {
        _ = group.wait(timeout: .now() + 2)
        return lock.withLock {
            (String(decoding: output, as: UTF8.self), String(decoding: error, as: UTF8.self))
        }
    }
}

public extension CommandRunning {
    func run(_ executable: String, arguments: [String]) -> CommandResult? {
        run(executable, arguments: arguments, timeout: 5)
    }
}
