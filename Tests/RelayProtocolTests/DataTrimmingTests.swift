import Darwin
import Foundation
import Testing

@testable import RelayProtocol

@Suite("Dropping the front of a buffer")
struct DataTrimmingTests {
    private func allocatedBytes() -> Int {
        var statistics = malloc_statistics_t()
        malloc_zone_statistics(nil, &statistics)
        return Int(statistics.size_in_use)
    }

    @Test("What is left is the rest of the bytes, in order")
    func keepsTheRest() {
        var buffer = Data()
        var expected: [UInt8] = []
        var next: UInt8 = 0
        for step in 0 ..< 2_000 {
            let chunk = (0 ..< 97).map { _ in
                next &+= 1
                return next
            }
            buffer.append(contentsOf: chunk)
            expected += chunk
            let drop = step % 5 == 0 ? expected.count : min(expected.count, 60 + step % 90)
            buffer.discardFirst(drop)
            expected.removeFirst(drop)
            #expect(Array(buffer) == expected)
        }
    }

    @Test("A buffer fed at one end and drained at the other holds about what is in it")
    func releasesWhatWasDropped() {
        // Sixty-four megabytes through a window of sixty-four kilobytes, the
        // way a scrollback or a socket's queue of writes is used.
        let before = allocatedBytes()
        var buffer = Data()
        let chunk = Data(repeating: 0x41, count: 4096)
        for _ in 0 ..< 16_384 {
            buffer.append(chunk)
            if buffer.count > 64 * 1024 {
                buffer.discardFirst(chunk.count)
            }
        }
        withExtendedLifetime(buffer) {
            #expect(buffer.count <= 64 * 1024)
            #expect(allocatedBytes() - before < 1024 * 1024)
        }
    }
}
