import Foundation
import Testing

@testable import RelayProtocol

@Suite("Newline-delimited framing")
struct MessageFramingTests {
    @Test("A frame is terminated by exactly one newline")
    func encodeAppendsDelimiter() throws {
        let encoder = MessageFraming.makeEncoder()
        let frame = try MessageFraming.encode(ClientMessage(requestID: 7, request: .ping), using: encoder)
        #expect(frame.last == MessageFraming.delimiter)
        #expect(frame.dropLast().firstIndex(of: MessageFraming.delimiter) == nil)
    }

    @Test("Complete frames are drained, partial ones are retained")
    func partialFrameIsBuffered() {
        var accumulator = FrameAccumulator()
        accumulator.append(Data("{\"a\":1}\n{\"b\":".utf8))

        let first = accumulator.drainFrames()
        #expect(first.count == 1)
        #expect(String(decoding: first[0], as: UTF8.self) == "{\"a\":1}")

        // The truncated second frame must wait for the rest of the stream.
        #expect(accumulator.drainFrames().isEmpty)

        accumulator.append(Data("2}\n".utf8))
        let second = accumulator.drainFrames()
        #expect(second.count == 1)
        #expect(String(decoding: second[0], as: UTF8.self) == "{\"b\":2}")
    }

    @Test("A single read containing many frames yields all of them in order")
    func multipleFramesInOneChunk() {
        var accumulator = FrameAccumulator()
        accumulator.append(Data("one\ntwo\nthree\n".utf8))
        let frames = accumulator.drainFrames().map { String(decoding: $0, as: UTF8.self) }
        #expect(frames == ["one", "two", "three"])
    }

    @Test("Empty frames from stray newlines are discarded")
    func emptyFramesSkipped() {
        var accumulator = FrameAccumulator()
        accumulator.append(Data("\n\nreal\n\n".utf8))
        let frames = accumulator.drainFrames().map { String(decoding: $0, as: UTF8.self) }
        #expect(frames == ["real"])
    }

    @Test("A frame that never terminates cannot grow without bound")
    func oversizedBufferIsDropped() {
        var accumulator = FrameAccumulator(frameLimit: 1024)
        accumulator.append(Data(repeating: 0x41, count: 4096))
        #expect(accumulator.drainFrames().isEmpty)

        // The runaway buffer was discarded, so the next well-formed frame parses.
        accumulator.append(Data("recovered\n".utf8))
        let frames = accumulator.drainFrames().map { String(decoding: $0, as: UTF8.self) }
        #expect(frames == ["recovered"])
    }
}
