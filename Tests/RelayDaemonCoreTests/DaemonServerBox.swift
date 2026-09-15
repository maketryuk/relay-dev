import Foundation

@testable import RelayDaemonCore

/// Thin wrapper so the test target can own a `DaemonServer` lifetime.
final class DaemonServerBox: @unchecked Sendable {
    private let server: DaemonServer
    private let lock = NSLock()
    private var exitRequested = false

    init(socketURL: URL, commandRunner: (any CommandRunning)? = nil) throws {
        // Keep test output out of the log the user reads.
        let logURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-tests-\(UUID().uuidString).log")
        server = if let commandRunner {
            DaemonServer(socketURL: socketURL, logURL: logURL, commandRunner: commandRunner)
        } else {
            DaemonServer(socketURL: socketURL, logURL: logURL)
        }
        // The real entry point calls `exit` here; a test only records it.
        server.onExitRequested = { [weak self] in
            self?.lock.withLock { self?.exitRequested = true }
        }
        try server.start()
    }

    var didRequestExit: Bool {
        lock.withLock { exitRequested }
    }

    func shutdown() {
        server.shutdown()
    }
}
