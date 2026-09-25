import Foundation
import Testing

@testable import RelayDaemonCore

@Suite("Scrollback buffer")
struct ScrollbackBufferTests {
    @Test("Appended bytes are preserved verbatim")
    func preservesBytes() {
        var buffer = ScrollbackBuffer(capacity: 1024)
        buffer.append(Data("hello ".utf8))
        buffer.append(Data("world".utf8))
        #expect(String(decoding: buffer.bytes, as: UTF8.self) == "hello world")
    }

    @Test("The buffer never exceeds its capacity")
    func respectsCapacity() {
        var buffer = ScrollbackBuffer(capacity: 1000)
        // Endless agent output must not grow daemon RAM without bound.
        for _ in 0 ..< 100 {
            buffer.append(Data(repeating: 0x41, count: 500))
        }
        #expect(buffer.bytes.count <= 1000)
    }

    @Test("Trimmed bytes are let go of, not only hidden")
    func trimmedBytesAreReleased() {
        // A count within the capacity is not memory within it: trimmed with
        // `Data.removeFirst`, which moves where the data starts and keeps the
        // storage behind it, the buffer held everything a session had ever
        // printed while reporting half a megabyte.
        let before = allocatedBytes()
        var buffer = ScrollbackBuffer(capacity: 64 * 1024)
        let chunk = Data(repeating: 0x41, count: 4096)
        for _ in 0 ..< 8192 {
            buffer.append(chunk)
        }
        withExtendedLifetime(buffer) {
            #expect(buffer.bytes.count <= 64 * 1024)
            #expect(allocatedBytes() - before < 4 * 1024 * 1024)
        }
    }

    @Test("Trimming drops the oldest bytes and keeps the newest")
    func trimsFromTheFront() {
        var buffer = ScrollbackBuffer(capacity: 16)
        buffer.append(Data("0123456789".utf8))
        buffer.append(Data("ABCDEFGHIJ".utf8))
        let text = String(decoding: buffer.bytes, as: UTF8.self)
        #expect(text.hasSuffix("ABCDEFGHIJ"))
        #expect(!text.contains("012345"))
    }

    @Test("A fresh buffer is empty and clears back to empty")
    func emptiness() {
        var buffer = ScrollbackBuffer(capacity: 64)
        #expect(buffer.isEmpty)
        buffer.append(Data("x".utf8))
        #expect(!buffer.isEmpty)
        buffer.removeAll()
        #expect(buffer.isEmpty)
    }

    @Test("A single append larger than capacity is still bounded")
    func oversizedSingleAppend() {
        var buffer = ScrollbackBuffer(capacity: 100)
        buffer.append(Data(repeating: 0x42, count: 10_000))
        #expect(buffer.bytes.count <= 100)
    }
}
