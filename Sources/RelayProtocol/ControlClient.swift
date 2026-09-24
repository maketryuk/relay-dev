import Darwin
import Foundation

/// The `relay` command's half of the conversation: one request, one answer.
public enum ControlClient {
    public enum Failure: Error, Equatable {
        /// Nothing is listening: the app is not running, or not this flavour.
        case notRunning(socket: String)
        /// The socket belongs to another user, who is not to be told anything.
        case foreignSocket(socket: String)
        /// The app took the request and gave no answer in time.
        case timedOut
        /// What came back was not an answer.
        case badResponse(String)
    }

    public static func send(
        _ request: ControlRequest,
        to path: String,
        timeout: TimeInterval
    ) -> Result<ControlResponse, Failure> {
        let line: Data
        do {
            line = try ControlProtocol.encodeLine(request)
        } catch {
            return .failure(.badResponse("The request could not be written: \(error)"))
        }
        return exchange(line, with: path, timeout: timeout).flatMap { answer in
            do {
                return .success(try MessageFraming.makeDecoder().decode(ControlResponse.self, from: answer))
            } catch {
                return .failure(.badResponse("Relay's answer could not be read: \(error)"))
            }
        }
    }

    /// Sends bytes as they are and returns the first line that comes back.
    /// Apart from `send` so that a test can send what no command would.
    public static func exchange(_ bytes: Data, with path: String, timeout: TimeInterval) -> Result<Data, Failure> {
        // A socket in /tmp can be put there by anyone. What a command says
        // includes the prompts it carries, so it is said only to this user.
        var status = stat()
        guard lstat(path, &status) == 0 else { return .failure(.notRunning(socket: path)) }
        guard status.st_uid == getuid() else { return .failure(.foreignSocket(socket: path)) }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .failure(.notRunning(socket: path)) }
        defer { close(descriptor) }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        // Zero would mean no limit at all.
        var limit = timeval(tv_sec: max(1, Int(timeout)), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        guard UnixSocketAddress.connect(descriptor, to: path) else { return .failure(.notRunning(socket: path)) }

        // A write cut short is not the end: an app that refuses a request
        // stops reading it, answers and hangs up, and the answer is still
        // there to be read.
        _ = UnixSocketAddress.writeAll(bytes, to: descriptor)

        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                answer.append(contentsOf: buffer[0 ..< count])
                if let end = answer.firstIndex(of: MessageFraming.delimiter) {
                    return .success(Data(answer[answer.startIndex ..< end]))
                }
                continue
            }
            if count < 0, errno == EINTR { continue }
            if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return .failure(.timedOut) }
            break
        }
        return .failure(.badResponse("Relay closed the connection without answering."))
    }
}

/// The parts of a Unix socket both ends of the control socket need.
public enum UnixSocketAddress {
    /// `sun_path` holds 104 bytes with its terminator.
    public static let pathLimit = 103

    public static func withAddress<Value>(
        of path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) -> Value
    ) -> Value? {
        guard path.utf8.count <= pathLimit else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString {
                strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), $0, pathLimit)
            }
        }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    public static func connect(_ descriptor: Int32, to path: String) -> Bool {
        withAddress(of: path) { Darwin.connect(descriptor, $0, $1) == 0 } ?? false
    }

    @discardableResult
    public static func writeAll(_ bytes: Data, to descriptor: Int32) -> Bool {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return true }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base + offset, buffer.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }
}
