import Darwin
import Foundation
import RelayProtocol

@testable import RelayDaemonCore

/// Minimal blocking client used by the daemon integration tests.
///
/// Deliberately not `DaemonClient`: the tests should exercise the wire protocol
/// itself, not the GUI's convenience layer.
final class TestClient: @unchecked Sendable {
    private let descriptor: Int32
    private var accumulator = FrameAccumulator()
    private var received: [ServerMessage] = []
    private let lock = NSLock()
    private var nextRequestID: UInt64 = 1
    private let encoder = MessageFraming.makeEncoder()
    private let decoder = MessageFraming.makeDecoder()

    init(socketURL: URL) throws {
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw TestClientError.socketFailed }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            socketURL.path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                connect(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(descriptor)
            throw TestClientError.connectFailed
        }

        var timeout = timeval(tv_sec: 0, tv_usec: 50_000)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    enum TestClientError: Error {
        case socketFailed
        case connectFailed
        case timedOut
    }

    @discardableResult
    func send(_ request: DaemonRequest) throws -> UInt64 {
        let requestID = lock.withLock { () -> UInt64 in
            let identifier = nextRequestID
            nextRequestID += 1
            return identifier
        }
        let frame = try MessageFraming.encode(
            ClientMessage(requestID: requestID, request: request),
            using: encoder
        )
        _ = frame.withUnsafeBytes { raw in Darwin.write(descriptor, raw.baseAddress, raw.count) }
        return requestID
    }

    /// Drains whatever has arrived without blocking for long.
    func pump() {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = buffer.withUnsafeMutableBytes { pointer in
            Darwin.read(descriptor, pointer.baseAddress, pointer.count)
        }
        guard count > 0 else { return }
        accumulator.append(Data(buffer[0 ..< count]))
        for frame in accumulator.drainFrames() {
            if let message = try? decoder.decode(ServerMessage.self, from: frame) {
                lock.withLock { received.append(message) }
            }
        }
    }

    /// Polls until `predicate` is satisfied by the messages received so far.
    @discardableResult
    func wait(
        timeout: TimeInterval = 10,
        until predicate: ([ServerMessage]) -> Bool
    ) throws -> [ServerMessage] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            pump()
            let snapshot = lock.withLock { received }
            if predicate(snapshot) { return snapshot }
        }
        throw TestClientError.timedOut
    }

    var messages: [ServerMessage] {
        lock.withLock { received }
    }

    func close() {
        Darwin.close(descriptor)
    }
}

extension [ServerMessage] {
    var events: [DaemonEvent] {
        compactMap { if case let .event(event) = $0 { event } else { nil } }
    }

    func reply(to requestID: UInt64) -> DaemonReply? {
        for message in self {
            if case let .reply(identifier, reply) = message, identifier == requestID { return reply }
        }
        return nil
    }

    func failure(to requestID: UInt64) -> DaemonError? {
        for message in self {
            if case let .failure(identifier, error) = message, identifier == requestID { return error }
        }
        return nil
    }

    /// Concatenated PTY output for one session, in arrival order.
    func output(for sessionID: SessionID) -> Data {
        var data = Data()
        for event in events {
            if case let .output(identifier, chunk) = event, identifier == sessionID {
                data.append(chunk)
            }
        }
        return data
    }

    func snapshots(for sessionID: SessionID) -> [SessionSnapshot] {
        events.compactMap { event in
            switch event {
            case let .sessionCreated(snapshot) where snapshot.id == sessionID: snapshot
            case let .sessionUpdated(snapshot) where snapshot.id == sessionID: snapshot
            default: nil
            }
        }
    }
}

/// Spins up a real daemon on a throwaway socket for the duration of a test.
final class DaemonHarness {
    let socketURL: URL
    let server: DaemonServerBox

    init(commandRunner: (any CommandRunning)? = nil) throws {
        socketURL = URL(fileURLWithPath: "/tmp/relay-test-\(UUID().uuidString.prefix(8)).sock")
        server = try DaemonServerBox(socketURL: socketURL, commandRunner: commandRunner)
    }

    func makeClient() throws -> TestClient {
        let client = try TestClient(socketURL: socketURL)
        try client.send(.handshake(protocolVersion: RelayProtocolVersion.current, clientName: "tests"))
        return client
    }

    func shutdown() {
        server.shutdown()
        try? FileManager.default.removeItem(at: socketURL)
    }
}
