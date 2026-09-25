import Foundation

/// Newline-delimited JSON framing.
///
/// The transport is deliberately boring so it can be swapped for XPC without
/// touching product code: only `encode`/`decode` and the socket layer know the
/// wire format exists.
public enum MessageFraming {
    public static let delimiter = UInt8(0x0A)

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    public static func encode(_ value: some Encodable, using encoder: JSONEncoder) throws -> Data {
        var data = try encoder.encode(value)
        data.append(delimiter)
        return data
    }
}

/// Accumulates socket reads and yields complete frames.
///
/// A socket hands a frame over a few kilobytes at a time, and a scrollback
/// replay is most of a megabyte. Searched from the start after every read,
/// and cut out one frame at a time, the same bytes were looked at and moved
/// again and again: a tenth of a second for one replay, before it was even
/// decoded. So the search resumes where the last one gave up, and what has
/// been drained is cut out once.
public struct FrameAccumulator: Sendable {
    private var buffer = Data()
    /// How much of `buffer` is known to hold no delimiter.
    private var searched = 0
    private let frameLimit: Int

    public init(frameLimit: Int = 32 * 1024 * 1024) {
        self.frameLimit = frameLimit
    }

    public mutating func append(_ chunk: Data) {
        buffer.append(chunk)
    }

    /// Removes and returns every complete frame currently buffered.
    public mutating func drainFrames() -> [Data] {
        var frames: [Data] = []
        var frameStart = buffer.startIndex
        var searchFrom = buffer.startIndex + searched
        while let index = buffer[searchFrom...].firstIndex(of: MessageFraming.delimiter) {
            if index > frameStart {
                frames.append(Data(buffer[frameStart ..< index]))
            }
            frameStart = index + 1
            searchFrom = frameStart
        }
        buffer.removeSubrange(buffer.startIndex ..< frameStart)
        searched = buffer.count
        if buffer.count > frameLimit {
            buffer.removeAll(keepingCapacity: false)
            searched = 0
        }
        return frames
    }
}
