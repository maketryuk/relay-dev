import Darwin
import Foundation
import RelayProtocol

/// Unix domain socket acceptor.
///
/// A UDS is used instead of XPC because it makes the "GUI reconnects to an
/// already-running daemon" path trivial to reason about and to debug with
/// standard tools. `DaemonTransport` on the client side hides this choice, so
/// swapping in an XPC Mach service later touches no product code.
public final class SocketListener: @unchecked Sendable {
    public enum ListenError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case socketFailed(Int32)
        case bindFailed(Int32)
        case listenFailed(Int32)
        case alreadyRunning

        public var description: String {
            switch self {
            case let .pathTooLong(path): "Socket path exceeds sun_path limit: \(path)"
            case let .socketFailed(code): "socket() failed: \(String(cString: strerror(code)))"
            case let .bindFailed(code): "bind() failed: \(String(cString: strerror(code)))"
            case let .listenFailed(code): "listen() failed: \(String(cString: strerror(code)))"
            case .alreadyRunning: "Another Relay daemon already owns this socket"
            }
        }
    }

    private let url: URL
    private var descriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private let onAccept: (Int32) -> Void

    public init(url: URL, onAccept: @escaping (Int32) -> Void) {
        self.url = url
        self.onAccept = onAccept
    }

    public func start() throws {
        let path = url.path
        guard path.utf8.count < 104 else { throw ListenError.pathTooLong(path) }

        if FileManager.default.fileExists(atPath: path) {
            if Self.isSocketAlive(at: path) { throw ListenError.alreadyRunning }
            try? FileManager.default.removeItem(atPath: path)
        }

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw ListenError.socketFailed(errno) }
        _ = fcntl(socketFD, F_SETFD, FD_CLOEXEC)

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                bind(socketFD, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(socketFD)
            throw ListenError.bindFailed(errno)
        }

        // Only this user may talk to the daemon.
        chmod(path, 0o600)

        guard listen(socketFD, 16) == 0 else {
            close(socketFD)
            throw ListenError.listenFailed(errno)
        }

        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)
        descriptor = socketFD

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: DaemonQueue.shared)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(socketFD) }
        acceptSource = source
        source.resume()
    }

    public func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        descriptor = -1
        try? FileManager.default.removeItem(at: url)
    }

    private func acceptPending() {
        while true {
            let client = accept(descriptor, nil, nil)
            if client >= 0 {
                // An accepted socket does not inherit the listener's flags.
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                onAccept(client)
                continue
            }
            if errno == EINTR { continue }
            break
        }
    }

    /// A stale socket file is left behind by a crashed daemon; connecting is the
    /// only reliable way to tell it apart from a live one.
    public static func isSocketAlive(at path: String) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
                connect(probe, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        return result == 0
    }
}
