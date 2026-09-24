import Darwin
import Foundation
import RelayProtocol

/// Where the `relay` command reaches the app.
///
/// One request line in, one answer line out, and the connection is closed.
/// Reading happens off the main thread and the answer comes from the handler,
/// which hands the request to the model on the main actor — so a client that
/// connects and says nothing holds up nobody, and the window is only busy for
/// as long as the model is.
final class ControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    enum StartError: Error, CustomStringConvertible {
        case pathTooLong(String)
        /// Another copy of this build is listening already, and keeps it.
        case alreadyRunning(String)
        case failed(String, Int32)

        var description: String {
            switch self {
            case let .pathTooLong(path): "Socket path exceeds sun_path limit: \(path)"
            case let .alreadyRunning(path): "Another Relay is already listening on \(path)"
            case let .failed(call, code): "\(call)() failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// A command writes its line as soon as it connects; one silent for this
    /// long is not going to.
    static let readTimeout = 5

    let socketURL: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.maketryuk.relay.control", qos: .userInitiated)
    private var descriptor: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    init(socketURL: URL, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.handler = handler
    }

    deinit {
        acceptSource?.cancel()
    }

    func start() throws {
        let path = socketURL.path
        guard path.utf8.count <= UnixSocketAddress.pathLimit else { throw StartError.pathTooLong(path) }

        // Left behind by a copy that crashed, a socket answers nobody; one
        // that answers belongs to a copy still running, and is not taken from it.
        var existing = stat()
        if lstat(path, &existing) == 0 {
            if Self.isAnswering(path) { throw StartError.alreadyRunning(path) }
            unlink(path)
        }

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw StartError.failed("socket", errno) }
        _ = fcntl(socketFD, F_SETFD, FD_CLOEXEC)
        // On the listener, which every connection inherits it from. Set on a
        // connection whose client has already hung up, it is refused — and
        // answering that connection is then a SIGPIPE that ends the app.
        var noSignal: Int32 = 1
        setsockopt(socketFD, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let bound = UnixSocketAddress.withAddress(of: path) { bind(socketFD, $0, $1) } ?? -1
        guard bound == 0 else {
            let code = errno
            close(socketFD)
            throw StartError.failed("bind", code)
        }
        // Before listening, so there is no moment anyone else could connect.
        chmod(path, 0o600)
        guard listen(socketFD, 16) == 0 else {
            let code = errno
            close(socketFD)
            unlink(path)
            throw StartError.failed("listen", code)
        }
        _ = fcntl(socketFD, F_SETFL, fcntl(socketFD, F_GETFL, 0) | O_NONBLOCK)
        descriptor = socketFD

        let source = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(socketFD) }
        acceptSource = source
        source.resume()
    }

    func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            descriptor = -1
        }
        unlink(socketURL.path)
    }

    private func acceptPending() {
        while true {
            let client = accept(descriptor, nil, nil)
            if client >= 0 {
                _ = fcntl(client, F_SETFD, FD_CLOEXEC)
                // A connection inherits the listener's O_NONBLOCK on macOS, and
                // is read here with a timeout instead.
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL, 0) & ~O_NONBLOCK)
                var limit = timeval(tv_sec: Self.readTimeout, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
                DispatchQueue.global(qos: .userInitiated).async { [handler] in
                    Self.serve(client, with: handler)
                }
                continue
            }
            if errno == EINTR { continue }
            break
        }
    }

    private static func serve(_ client: Int32, with handler: @escaping Handler) {
        // The socket's mode already keeps other users out; asking the kernel
        // who is on the other end costs one call and does not depend on it.
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(client, &user, &group) == 0, user == getuid() else {
            close(client)
            return
        }
        let request = requestLine(from: client).flatMap(ControlRequest.decode)
        switch request {
        case let .failure(failure):
            reply(.failure(failure), on: client)
        case let .success(request):
            Task {
                let response = await handler(request)
                reply(response, on: client)
            }
        }
    }

    /// The first line the client sends, without its newline.
    static func requestLine(from client: Int32) -> Result<Data, ControlFailure> {
        var line = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(client, $0.baseAddress, $0.count) }
            if count > 0 {
                let chunk = buffer[0 ..< count]
                let end = chunk.firstIndex(of: MessageFraming.delimiter)
                line.append(contentsOf: chunk[..<(end ?? count)])
                if line.count > ControlProtocol.requestLimit {
                    return .failure(ControlFailure(
                        .requestTooLarge,
                        "The request is over \(ControlProtocol.requestLimit / 1024) KB, which no command is."
                    ))
                }
                if end != nil { return .success(line) }
                continue
            }
            if count < 0, errno == EINTR { continue }
            // A client that hung up after a whole request without its newline
            // still said something.
            if count == 0, !line.isEmpty { return .success(line) }
            let late = count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)
            return .failure(ControlFailure(.badRequest, late ? "No request arrived in time." : "No request arrived."))
        }
    }

    private static func reply(_ response: ControlResponse, on client: Int32) {
        defer { close(client) }
        guard let line = try? ControlProtocol.encodeLine(response) else { return }
        UnixSocketAddress.writeAll(line, to: client)
    }

    private static func isAnswering(_ path: String) -> Bool {
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { return false }
        defer { close(probe) }
        return UnixSocketAddress.connect(probe, to: path)
    }
}
