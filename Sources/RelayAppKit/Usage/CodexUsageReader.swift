import Foundation
import RelayProtocol

/// Reads the limits Codex last heard from its provider.
///
/// Codex keeps no summary file, but it records a `rate_limits` object in a
/// session's rollout log every time the figure changes, so the newest such
/// record anywhere is what the CLI itself would show.
///
/// Newest by the time in the record, not by the file holding it. Resuming a
/// conversation appends to the log it started in, so the most recently written
/// file is routinely an old one whose limits are months out of date, and a
/// session opened a moment ago has no record in it at all. Sorting by the file
/// answered "which log was touched last", which is a different question.
///
/// Each log is read from the end: these files run to hundreds of kilobytes, the
/// answer is always near the bottom, and reading a whole conversation to learn
/// two percentages would be absurd.
enum CodexUsageReader {
    static var defaultDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
    }

    /// How much of the tail to search. Generous next to a `rate_limits` record
    /// and nothing next to the file.
    static let tailBytes = 256 * 1024

    /// A backstop on how many logs are opened before the search gives up. The
    /// walk stops on its own as soon as no unread file can hold a newer record;
    /// this only bounds the case where a great many logs were touched at once.
    static let logsToSearch = 16

    static func read(from directory: URL = defaultDirectory, now: Date = Date()) -> AgentUsage? {
        var best: AgentUsage?

        for log in rollouts(in: directory).prefix(logsToSearch) {
            // A record cannot be newer than the file it is written in, so once
            // the best answer so far postdates the next file, nothing below can
            // improve on it.
            if let recorded = best?.fetchedAt, recorded >= log.modifiedAt { break }

            guard let tail = tail(of: log.url), let usage = parse(tail, now: now) else { continue }
            if recordedAt(usage) > recordedAt(best) { best = usage }
        }
        return best
    }

    private static func recordedAt(_ usage: AgentUsage?) -> Date {
        usage?.fetchedAt ?? .distantPast
    }

    static func parse(_ text: String, now: Date = Date()) -> AgentUsage? {
        guard let record = lastRateLimits(in: text) else { return nil }

        let windows = [record.limits["primary"], record.limits["secondary"]]
            .compactMap { $0 as? [String: Any] }
            .compactMap { window(from: $0, now: now) }
        guard !windows.isEmpty else { return nil }

        return AgentUsage(kind: .codex, windows: windows, fetchedAt: record.recordedAt)
    }

    private static func window(from limit: [String: Any], now: Date) -> UsageWindow? {
        guard let used = limit["used_percent"] as? Double else { return nil }
        let span = span(forWindowMinutes: limit["window_minutes"] as? Double)
        let resets = (limit["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }

        // A window that has rolled over since the record was written is empty,
        // and can be shown as empty rather than dropped: Codex writes a record
        // for every answer it is given, so anything spent in the window that
        // replaced this one would have left a newer record than this.
        if let resets, resets <= now {
            return UsageWindow(span: span, fraction: 0, resetsAt: nil)
        }
        return UsageWindow(span: span, fraction: used / 100, resetsAt: resets)
    }

    /// Codex describes a window by its length rather than by name.
    static func span(forWindowMinutes minutes: Double?) -> UsageWindow.Span {
        guard let minutes, minutes > 0 else { return .rolling(minutes: 0) }
        return minutes >= 10_080 ? .weekly : .rolling(minutes: Int(minutes))
    }

    /// The last `rate_limits` object in the text, with the time of the line it
    /// was written on.
    ///
    /// Found by scanning rather than by parsing every line: a rollout log is a
    /// transcript, and most of it is of no interest here.
    static func lastRateLimits(in text: String) -> (limits: [String: Any], recordedAt: Date?)? {
        var search = text.startIndex ..< text.endIndex

        while let marker = text.range(of: "\"rate_limits\":", options: .backwards, range: search) {
            if let object = jsonObject(in: text, startingAfter: marker.upperBound) {
                return (object, recordTime(in: text, around: marker.lowerBound))
            }
            search = text.startIndex ..< marker.lowerBound
        }
        return nil
    }

    /// The `timestamp` the record's own line carries, which is what makes two
    /// logs comparable.
    private static func recordTime(in text: String, around index: String.Index) -> Date? {
        let start = text[..<index].lastIndex(of: "\n").map(text.index(after:)) ?? text.startIndex
        let line = text[start...].prefix { $0 != "\n" }
        guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        else { return nil }
        return ClaudeUsageWindows.resetDate(record["timestamp"])
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

    // MARK: - Finding the files

    /// Every rollout log, most recently written first.
    private static func rollouts(in directory: URL) -> [(url: URL, modifiedAt: Date)] {
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var logs: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            logs.append((url, modificationDate(of: url) ?? .distantPast))
        }
        return logs.sorted { $0.modifiedAt > $1.modifiedAt }
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
