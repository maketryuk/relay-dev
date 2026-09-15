import Foundation

/// Reads the end of a file that is written by appending.
///
/// Both agents keep their sessions as ever-growing JSONL, and the only line
/// either question here needs is near the bottom. Reading a whole conversation
/// to learn one number would be absurd, and these run to megabytes.
enum TranscriptTail {
    /// Generous next to a single record and nothing next to the file.
    static let defaultBytes = 512 * 1024

    static func read(_ url: URL, bytes: Int = defaultBytes) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// The complete lines in a tail, oldest first.
    ///
    /// The first line is dropped whenever the tail began mid-file: half a record
    /// is not a record, and parsing it would either fail or, worse, succeed on
    /// the wrong half.
    static func lines(in tail: String, isWholeFile: Bool) -> [Substring] {
        let all = tail.split(separator: "\n", omittingEmptySubsequences: true)
        guard !isWholeFile, all.count > 1 else { return all }
        return Array(all.dropFirst())
    }

    static func objects(in url: URL, bytes: Int = defaultBytes) -> [[String: Any]] {
        guard let tail = read(url, bytes: bytes) else { return [] }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let whole = size <= bytes
        return lines(in: tail, isWholeFile: whole).compactMap { line in
            try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        }
    }

    static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
