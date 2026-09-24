import Darwin
import Foundation
import RelayProtocol

/// Reads the one line a hook sends.
enum AgentHookReader {
    /// An event is a few hundred bytes; anything past this is not one.
    static let maximumLength = 64 * 1024

    /// Blocks for at most `AgentHookDelivery.timeout`, so it is called off the
    /// daemon queue. Nil for anything that is not a whole event.
    static func read(from descriptor: Int32) -> AgentHookEvent? {
        var limit = timeval(tv_sec: Int(AgentHookDelivery.timeout), tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))

        var received = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while received.count < maximumLength, !received.contains(0x0A) {
            let count = Darwin.read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            received.append(contentsOf: chunk[0 ..< count])
        }
        guard let line = received.split(separator: 0x0A, omittingEmptySubsequences: true).first else { return nil }
        return try? JSONDecoder().decode(AgentHookEvent.self, from: Data(line))
    }
}
