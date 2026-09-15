import Darwin
import Foundation
import Testing

@testable import RelayAppKit

/// Minimal Unix socket listener so transport lifetime can be tested without a
/// daemon.
private final class StubListener: @unchecked Sendable {
    let url: URL
    private var descriptor: Int32 = -1
    private var accepted: [Int32] = []
    private let lock = NSLock()
    private var isStopped = false

    init() throws {
        url = URL(fileURLWithPath: "/tmp/relay-transport-\(UUID().uuidString.prefix(8)).sock")
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.socket }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            url.path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                bind(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(descriptor, 64) == 0 else { throw Failure.bind }

        // Something has to drain the backlog, or later connects are refused.
        let listenerDescriptor = descriptor
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listenerDescriptor, nil, nil)
                guard client >= 0, let self else { return }
                self.lock.withLock {
                    if self.isStopped {
                        Darwin.close(client)
                    } else {
                        self.accepted.append(client)
                    }
                }
            }
        }
    }

    enum Failure: Error { case socket, bind }

    deinit {
        lock.withLock {
            isStopped = true
            for client in accepted { Darwin.close(client) }
            accepted.removeAll()
        }
        if descriptor >= 0 { Darwin.close(descriptor) }
        try? FileManager.default.removeItem(at: url)
    }
}

@Suite("Daemon transport lifetime", .serialized)
struct DaemonTransportTests {
    @Test("A connected transport can be dropped without calling close")
    func deallocatingWithoutCloseIsSafe() throws {
        // libdispatch traps with "release of an inactive object" when a
        // suspended source is deallocated. The write source is suspended
        // whenever there is nothing queued — which is almost always — so any
        // path that drops the transport without closing it used to abort the
        // whole app. A rejected handshake was exactly that path.
        let listener = try StubListener()

        for _ in 0 ..< 20 {
            let transport = UnixSocketTransport(url: listener.url)
            try transport.connect()
            _ = transport
        }

        // Reaching here without trapping is the assertion.
        #expect(Bool(true))
    }

    @Test("Closing and then dropping a transport is also safe")
    func closingThenDeallocatingIsSafe() throws {
        let listener = try StubListener()
        for _ in 0 ..< 20 {
            let transport = UnixSocketTransport(url: listener.url)
            try transport.connect()
            transport.close()
        }
        #expect(Bool(true))
    }

    @Test("A transport that wrote data can still be dropped safely")
    func deallocatingAfterWritingIsSafe() throws {
        // Writing resumes the write source on a blocked socket; the teardown
        // has to cope with the source being active as well as suspended.
        let listener = try StubListener()
        let transport = UnixSocketTransport(url: listener.url)
        try transport.connect()
        transport.send(Data(repeating: 0x41, count: 4096))
        Thread.sleep(forTimeInterval: 0.1)
        #expect(Bool(true))
    }

    @Test("Connecting to a socket that is not there fails without trapping")
    func failedConnectIsSafe() {
        let transport = UnixSocketTransport(url: URL(fileURLWithPath: "/tmp/relay-nonexistent.sock"))
        #expect(throws: (any Error).self) { try transport.connect() }
    }
}
