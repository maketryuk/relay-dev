import Foundation
import RelayProtocol

/// Bounded byte ring for terminal history.
///
/// Raw bytes are stored rather than parsed cells, so replaying the buffer into
/// any VT-compatible renderer reproduces colours and cursor state. The cap is a
/// hard limit: unbounded agent output must never grow daemon RAM without end.
public struct ScrollbackBuffer: Sendable {
    public private(set) var bytes: Data
    public let capacity: Int

    public init(capacity: Int = 512 * 1024) {
        self.capacity = capacity
        bytes = Data()
        bytes.reserveCapacity(min(capacity, 64 * 1024))
    }

    public mutating func append(_ chunk: Data) {
        bytes.append(chunk)
        guard bytes.count > capacity else { return }
        // Trim in chunks so a busy stream does not copy on every write.
        let overflow = bytes.count - capacity
        let trim = max(overflow, capacity / 8)
        bytes.discardFirst(min(trim, bytes.count))
    }

    public mutating func removeAll() {
        bytes.removeAll(keepingCapacity: true)
    }

    public var isEmpty: Bool { bytes.isEmpty }
}
