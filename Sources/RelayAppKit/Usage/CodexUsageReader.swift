import Foundation
import RelayProtocol

/// Reads the limits Codex last heard from its provider.
///
/// Codex keeps no summary file, but it records a `rate_limits` object in each
/// session's rollout log every time the figure changes. The newest such record
/// in the most recently written session is what the CLI itself would show.
///
/// The log is read from the end: these files run to hundreds of kilobytes, the
/// answer is always near the bottom, and reading a whole conversation to learn
/// two percentages would be absurd.
enum CodexUsageReader {
    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    /// How much of the tail to search. Generous next to a `rate_limits` record
    /// and nothing next to the file.
    static let tailBytes = 256 * 1024

    static func read(from directory: URL = defaultDirectory) -> AgentUsage? {
        guard let log = newestRollout(in: directory), let tail = tail(of: log) else { return nil }
        return parse(tail, modifiedAt: modificationDate(of: log))
    }

    static func parse(_ text: String, modifiedAt: Date? = nil) -> AgentUsage? {
        guard let limits = lastRateLimits(in: text) else { return nil }

        let windows = [limits["primary"], limits["secondary"]]
            .compactMap { $0 as? [String: Any] }
            .compactMap(window(from:))
        guard !windows.isEmpty else { return nil }

        return AgentUsage(kind: .codex, windows: windows, fetchedAt: modifiedAt)
    }

    private static func window(from limit: [String: Any]) -> UsageWindow? {
        guard let used = limit["used_percent"] as? Double else { return nil }
        let resets = (limit["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
        return UsageWindow(
            span: span(forWindowMinutes: limit["window_minutes"] as? Double),
            fraction: used / 100,
            resetsAt: resets
        )
    }

    /// Codex describes a window by its length rather than by name.
    static func span(forWindowMinutes minutes: Double?) -> UsageWindow.Span {
        guard let minutes, minutes > 0 else { return .rolling(minutes: 0) }
        return minutes >= 10_080 ? .weekly : .rolling(minutes: Int(minutes))
    }

    /// The last `rate_limits` object in the text, decoded on its own.
    ///
    /// Found by scanning rather than by parsing every line: a rollout log is a
    /// transcript, and most of it is of no interest here.
    static func lastRateLimits(in text: String) -> [String: Any]? {
        var search = text.startIndex ..< text.endIndex
        var found: [String: Any]?

        while let marker = text.range(of: "\"rate_limits\":", options: .backwards, range: search) {
            if let object = jsonObject(in: text, startingAfter: marker.upperBound) {
                found = object
                break
            }
            search = text.startIndex ..< marker.lowerBound
        }
        return found
    }

    private static func jsonObject(in text: String, startingAfter index: String.Index) -> [String: Any]? {
        guard let open = text[index...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var cursor = open

        while cursor < text.endIndex {
            if text[cursor] == "{" { depth += 1 }
            if text[cursor] == "}" {
                depth -= 1
                if depth == 0 {
                    let slice = text[open ... cursor]
                    return try? JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [String: Any]
                }
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    // MARK: - Finding the file

    private static func newestRollout(in directory: URL) -> URL? {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var newest: (url: URL, date: Date)?
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let date = modificationDate(of: url) ?? .distantPast
            if newest == nil || date > newest!.date { newest = (url, date) }
        }
        return newest?.url
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func tail(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
