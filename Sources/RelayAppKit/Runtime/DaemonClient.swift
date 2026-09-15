import Foundation
import RelayProtocol

/// Typed, async client for the session daemon.
///
/// Owns request correlation and republishes daemon events as an `AsyncStream`.
/// Output frames are delivered on a background queue and coalesced by the
/// terminal layer, so a chatty session never floods the main thread.
final class DaemonClient: @unchecked Sendable {
    enum ClientError: Error, LocalizedError {
        case notConnected
        case unexpectedReply

        var errorDescription: String? {
            switch self {
            case .notConnected: "Not connected to the Relay daemon"
            case .unexpectedReply: "Daemon returned an unexpected reply"
            }
        }
    }

    private let lock = NSLock()
    private var transport: (any DaemonTransport)?
    private var nextRequestID: UInt64 = 1
    private var pending: [UInt64: CheckedContinuation<DaemonReply, Error>] = [:]
    private var eventContinuation: AsyncStream<DaemonEvent>.Continuation?
    private let encoder = MessageFraming.makeEncoder()
    private let decoder = MessageFraming.makeDecoder()

    private(set) var events: AsyncStream<DaemonEvent>!
    /// Fired when the socket drops so the UI can show a reconnect affordance.
    var onDisconnect: (@Sendable () -> Void)?

    init() {
        events = AsyncStream(bufferingPolicy: .unbounded) { continuation in
            self.eventContinuation = continuation
        }
    }

    var isConnected: Bool {
        lock.withLock { transport != nil }
    }

    // MARK: - Connection

    func connect() async throws {
        do {
            let identity = try await openConnection()
            // Protocol compatibility is not enough. The daemon outlives the GUI
            // on purpose, so a rebuilt app usually finds the *previous* build's
            // daemon still running — with all of its old behaviour intact, and
            // no wire-format change to give it away.
            if let expected = bundledDaemonIdentity(), let identity, identity != expected {
                try await retireIncompatibleDaemon()
                _ = try await openConnection()
            }
        } catch let error as DaemonError where error.code == "protocol_mismatch" {
            try await retireIncompatibleDaemon()
            _ = try await openConnection()
        }
    }

    private func bundledDaemonIdentity() -> String? {
        guard let executable = DaemonLauncher.locateDaemon() else { return nil }
        return BuildIdentity.of(executableAt: executable)
    }

    /// Returns the build identity the daemon reported, when it reported one.
    @discardableResult
    private func openConnection() async throws -> String? {
        // Blocking probe plus process launch: keep it off the caller's actor.
        _ = try await Task.detached(priority: .userInitiated) {
            try DaemonLauncher.startIfNeeded()
        }.value

        let socket = UnixSocketTransport(url: RelayPaths.socketURL)
        socket.onFrame = { [weak self] frame in self?.handle(frame: frame) }
        socket.onDisconnect = { [weak self] in self?.handleDisconnect() }
        try socket.connect()

        lock.withLock { transport = socket }

        do {
            let reply = try await send(
                .handshake(protocolVersion: RelayProtocolVersion.current, clientName: "Relay GUI")
            )
            guard case let .pong(_, _, buildIdentity, _) = reply else { return nil }
            return buildIdentity
        } catch let error as DaemonError where error.code == "protocol_mismatch" {
            // Deliberately keeps the socket open: retiring the old daemon means
            // sending it a message, and tearing the transport down here left
            // `retireIncompatibleDaemon` with nothing to send over — so the
            // stale daemon was never asked to stop and every reconnect hit the
            // same mismatch. `disconnect()` still runs during retirement, so
            // the dispatch sources are released either way.
            throw error
        } catch {
            // Any other rejection must tear the socket down; dropping it on the
            // floor leaks the descriptor and its dispatch sources.
            disconnect()
            throw error
        }
    }

    private func retireIncompatibleDaemon() async throws {
        // `shutdownDaemon` predates every version bump, so an older daemon can
        // still decode it. Adding cases stays backwards compatible; reordering
        // or removing them would not.
        post(.shutdownDaemon)
        try? await Task.sleep(for: .milliseconds(400))
        disconnect()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            let stillRunning = await Task.detached(priority: .userInitiated) {
                DaemonLauncher.isDaemonRunning()
            }.value
            if !stillRunning { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    func disconnect() {
        let socket = lock.withLock { () -> (any DaemonTransport)? in
            let current = transport
            transport = nil
            return current
        }
        socket?.close()
    }

    private func handleDisconnect() {
        let waiters = lock.withLock { () -> [UInt64: CheckedContinuation<DaemonReply, Error>] in
            transport = nil
            let current = pending
            pending.removeAll()
            return current
        }

        for continuation in waiters.values {
            continuation.resume(throwing: ClientError.notConnected)
        }
        onDisconnect?()
    }

    // MARK: - Requests

    /// A reply that never arrives — a frame the daemon could not decode, for
    /// instance — must not leave the UI waiting forever.
    private static let requestTimeout = Duration.seconds(20)

    @discardableResult
    func send(_ request: DaemonRequest) async throws -> DaemonReply {
        guard let (transport, requestID) = lock.withLock({ () -> ((any DaemonTransport), UInt64)? in
            guard let transport else { return nil }
            let identifier = nextRequestID
            nextRequestID += 1
            return (transport, identifier)
        }) else {
            throw ClientError.notConnected
        }

        let frame = try MessageFraming.encode(ClientMessage(requestID: requestID, request: request), using: encoder)

        let watchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.requestTimeout)
            guard !Task.isCancelled else { return }
            self?.resume(
                requestID: requestID,
                with: .failure(DaemonError(code: "timeout", message: "The daemon did not answer in time"))
            )
        }
        defer { watchdog.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[requestID] = continuation }
            transport.send(frame)
        }
    }

    /// Fire-and-forget for the hot path: keystrokes and resizes must not pay for
    /// a round trip.
    func post(_ request: DaemonRequest) {
        guard let (transport, requestID) = lock.withLock({ () -> ((any DaemonTransport), UInt64)? in
            guard let transport else { return nil }
            let identifier = nextRequestID
            nextRequestID += 1
            return (transport, identifier)
        }) else { return }

        guard let frame = try? MessageFraming.encode(
            ClientMessage(requestID: requestID, request: request),
            using: encoder
        ) else { return }
        transport.send(frame)
    }

    private func handle(frame: Data) {
        guard let message = try? decoder.decode(ServerMessage.self, from: frame) else { return }
        switch message {
        case let .reply(requestID, reply):
            resume(requestID: requestID, with: .success(reply))
        case let .failure(requestID, error):
            resume(requestID: requestID, with: .failure(error))
        case let .event(event):
            eventContinuation?.yield(event)
        }
    }

    private func resume(requestID: UInt64, with result: Result<DaemonReply, Error>) {
        let continuation = lock.withLock { pending.removeValue(forKey: requestID) }
        continuation?.resume(with: result)
    }

    // MARK: - Convenience

    func listSessions() async throws -> [SessionSnapshot] {
        guard case let .sessions(sessions) = try await send(.listSessions) else {
            throw ClientError.unexpectedReply
        }
        return sessions
    }

    func createSession(_ spec: SessionSpec) async throws -> SessionSnapshot {
        guard case let .session(session) = try await send(.createSession(spec)) else {
            throw ClientError.unexpectedReply
        }
        return session
    }

    func attach(_ id: SessionID, replayScrollback: Bool) async throws -> SessionSnapshot {
        guard case let .session(session) = try await send(.attach(id, replayScrollback: replayScrollback)) else {
            throw ClientError.unexpectedReply
        }
        return session
    }
}
