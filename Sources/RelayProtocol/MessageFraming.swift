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
public struct FrameAccumulator: Sendable {
    private var buffer = Data()
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
        while let index = buffer.firstIndex(of: MessageFraming.delimiter) {
            let frame = buffer[buffer.startIndex ..< index]
            buffer.removeSubrange(buffer.startIndex ... index)
            if !frame.isEmpty {
                frames.append(Data(frame))
            }
        }
        if buffer.count > frameLimit {
            buffer.removeAll(keepingCapacity: false)
        }
        return frames
    }
}
