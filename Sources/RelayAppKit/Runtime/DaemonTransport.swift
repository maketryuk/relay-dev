import Darwin
import Foundation
import RelayProtocol

/// Byte-level link to the daemon.
///
/// Everything above this protocol speaks `ClientMessage`/`ServerMessage`, so
/// replacing the Unix socket with an XPC Mach service means writing one new
/// conformance and nothing else.
protocol DaemonTransport: AnyObject {
    var onFrame: ((Data) -> Void)? { get set }
    var onDisconnect: (() -> Void)? { get set }

    func connect() throws
    func send(_ frame: Data)
    func close()
}

final class UnixSocketTransport: DaemonTransport, @unchecked Sendable {
    enum TransportError: Error, LocalizedError {
        case socketFailed(Int32)
        case connectFailed(Int32)
        case pathTooLong

        var errorDescription: String? {
            switch self {
            case let .socketFailed(code): "socket() failed: \(String(cString: strerror(code)))"
            case let .connectFailed(code): "connect() failed: \(String(cString: strerror(code)))"
            case .pathTooLong: "Socket path is too long"
            }
        }
    }

    var onFrame: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?

    private let url: URL
    private let queue = DispatchQueue(label: "com.maketryuk.relay.transport", qos: .userInitiated)
    private var descriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var isWriteSourceActive = false
    private var pendingWrites = Data()
    private var accumulator = FrameAccumulator()
    private var isClosed = false
    private var liveSourceCount = 0

    init(url: URL) {
        self.url = url
    }

    deinit {
        // libdispatch traps with "release of an inactive object" if a suspended
        // source is deallocated. The write source spends most of its life
        // suspended — it is only resumed when a write blocks — so any path that
        // drops the transport without calling `close()` would crash. A failed
        // handshake is exactly such a path.
        if let writeSource, !isWriteSourceActive {
            writeSource.resume()
        }
        writeSource?.cancel()
        readSource?.cancel()
        if descriptor >= 0, !isClosed {
            Darwin.close(descriptor)
        }
    }

    func connect() throws {
        let path = url.path
        guard path.utf8.count < 104 else { throw TransportError.pathTooLong }

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw TransportError.socketFailed(errno) }

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
                Darwin.connect(socketFD, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(socketFD)
            throw TransportError.connectFailed(code)
        }

        var noSigpipe: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(socketFD, F_GETFL, 0)
        _ = fcntl(socketFD, F_SETFL, flags | O_NONBLOCK)
        descriptor = socketFD
        isClosed = false

        let read = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        read.setEventHandler { [weak self] in self?.handleReadable() }
        read.setCancelHandler { [weak self] in self?.noteSourceCancelled() }
        readSource = read

        let write = DispatchSource.makeWriteSource(fileDescriptor: socketFD, queue: queue)
        write.setEventHandler { [weak self] in self?.flush() }
        write.setCancelHandler { [weak self] in self?.noteSourceCancelled() }
        writeSource = write

        liveSourceCount = 2
        read.resume()
    }

    func send(_ frame: Data) {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.pendingWrites.append(frame)
            self.flush()
        }
    }

    func close() {
        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.isClosed = true
            // Cancelling a suspended source is legal, but releasing one is not,
            // so it is resumed on the way out regardless.
            if !self.isWriteSourceActive {
                self.isWriteSourceActive = true
                self.writeSource?.resume()
            }
            self.writeSource?.cancel()
            self.writeSource = nil
            self.readSource?.cancel()
            self.readSource = nil
        }
    }

    private func flush() {
        while !pendingWrites.isEmpty {
            let written = pendingWrites.withUnsafeBytes { raw in
                Darwin.write(descriptor, raw.baseAddress, raw.count)
            }
            if written > 0 {
                pendingWrites.discardFirst(written)
                continue
            }
            if errno == EINTR { continue }
            if errno == EAGAIN {
                if !isWriteSourceActive {
                    isWriteSourceActive = true
                    writeSource?.resume()
                }
                return
            }
            close()
            return
        }
        if isWriteSourceActive {
            isWriteSourceActive = false
            writeSource?.suspend()
        }
    }

    private func handleReadable() {
        var buffer = [UInt8](repeating: 0, count: 128 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { pointer in
                Darwin.read(descriptor, pointer.baseAddress, pointer.count)
            }
            if count > 0 {
                accumulator.append(Data(buffer[0 ..< count]))
                continue
            }
            if count == 0 {
                deliverFrames()
                close()
                return
            }
            if errno == EINTR { continue }
            break
        }
        deliverFrames()
    }

    private func deliverFrames() {
        for frame in accumulator.drainFrames() {
            onFrame?(frame)
        }
    }

    private func noteSourceCancelled() {
        liveSourceCount -= 1
        guard liveSourceCount <= 0, descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
        onDisconnect?()
    }
}
