import Darwin
import Foundation

/// The smallest HTTP client that can ask a unix socket a question.
///
/// `URLSession` cannot address a unix socket, and pulling in a networking
/// library to send eleven bytes and read a JSON array would be a poor trade.
/// What is needed is one request, one response, no keep-alive and no
/// redirects — which is short enough to state exactly, including the two ways
/// a body can end.
public enum UnixSocketHTTP {
    public enum Failure: Error {
        case pathTooLong
        case cannotConnect(Int32)
        case cannotSend(Int32)
        case truncated
        /// The engine answered, and the answer was not success.
        case status(Int)
    }

    public static func get(_ path: String, from socketPath: String, timeout: TimeInterval) throws -> Data {
        let descriptor = try connect(to: socketPath, timeout: timeout)
        defer { close(descriptor) }

        // `Connection: close` so the engine ends the body by hanging up, which
        // removes the case where a reply with neither length nor chunking
        // leaves the read waiting for a byte that is never coming.
        let request = """
        GET \(path) HTTP/1.1\r
        Host: docker\r
        Accept: application/json\r
        Connection: close\r
        \r

        """
        try send(Data(request.utf8), on: descriptor)

        let response = try readToEnd(descriptor)
        let (status, body) = try split(response)
        guard (200 ..< 300).contains(status) else { throw Failure.status(status) }
        return body
    }

    // MARK: - Socket

    private static func connect(to socketPath: String, timeout: TimeInterval) throws -> Int32 {
        guard socketPath.utf8.count < 104 else { throw Failure.pathTooLong }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.cannotConnect(errno) }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        var window = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - Double(Int(timeout))) * 1_000_000)
        )
        // Both directions: a socket file that exists for an engine that is no
        // longer behind it accepts and then says nothing at all.
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &window, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            socketPath.withCString { source in
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, 103)
            }
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.cannotConnect(code)
        }
        return descriptor
    }

    private static func send(_ data: Data, on descriptor: Int32) throws {
        var sent = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            while sent < buffer.count {
                let written = Darwin.send(descriptor, base.advanced(by: sent), buffer.count - sent, 0)
                guard written > 0 else { throw Failure.cannotSend(errno) }
                sent += written
            }
        }
    }

    private static func readToEnd(_ descriptor: Int32) throws -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let read = recv(descriptor, &buffer, buffer.count, 0)
            if read > 0 {
                response.append(contentsOf: buffer[0 ..< read])
                continue
            }
            // 0 is the engine hanging up, which is the end of the body. Below
            // zero is a timeout or a broken socket, and what arrived so far is
            // not something to parse.
            if read == 0 { return response }
            throw Failure.truncated
        }
    }

    // MARK: - HTTP

    private static let headerTerminator = Data("\r\n\r\n".utf8)

    static func split(_ response: Data) throws -> (status: Int, body: Data) {
        guard let separator = response.range(of: headerTerminator) else { throw Failure.truncated }
        let head = String(decoding: response[..<separator.lowerBound], as: UTF8.self)
        let body = response[separator.upperBound...]

        // "HTTP/1.1 200 OK"
        let fields = head.split(separator: "\r\n", maxSplits: 1).first?.split(separator: " ") ?? []
        guard fields.count >= 2, let status = Int(fields[1]) else { throw Failure.truncated }

        let isChunked = head.lowercased().contains("transfer-encoding: chunked")
        return (status, isChunked ? try dechunk(Data(body)) : Data(body))
    }

    /// Chunked bodies, which Docker uses for anything it streams and sometimes
    /// for what it does not.
    static func dechunk(_ body: Data) throws -> Data {
        var remaining = body
        var result = Data()
        let newline = Data("\r\n".utf8)

        while let lineEnd = remaining.range(of: newline) {
            let header = String(decoding: remaining[..<lineEnd.lowerBound], as: UTF8.self)
            // A chunk size may carry extensions after a semicolon.
            let size = Int(header.split(separator: ";").first ?? "", radix: 16)
            guard let size else { throw Failure.truncated }
            if size == 0 { return result }

            let chunkStart = lineEnd.upperBound
            guard let chunkEnd = remaining.index(chunkStart, offsetBy: size, limitedBy: remaining.endIndex),
                  chunkEnd <= remaining.endIndex
            else { throw Failure.truncated }

            result.append(remaining[chunkStart ..< chunkEnd])
            // Past the chunk and the CRLF that closes it.
            guard let next = remaining.index(chunkEnd, offsetBy: newline.count, limitedBy: remaining.endIndex)
            else { return result }
            remaining = remaining[next...]
        }
        return result
    }
}
