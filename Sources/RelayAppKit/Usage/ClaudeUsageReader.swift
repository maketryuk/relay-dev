import Foundation
import RelayProtocol

/// Reads the limits Claude Code last wrote down.
///
/// Claude Code caches the body of its own usage request in `~/.claude.json`, so
/// this needs no credentials and makes no request. What it cannot do is be
/// current: the CLI only rewrites that key when it asks Anthropic itself, which
/// it does rarely — the figures it shows in its status line come from the
/// headers of ordinary responses and are never written down. A cache days old
/// is the normal case rather than the exception, which is why this is the
/// fallback behind `ClaudeUsageEndpoint` and not the source.
enum ClaudeUsageReader {
    static var defaultLocation: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    static func read(from url: URL = defaultLocation, now: Date = Date()) -> AgentUsage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data, now: now)
    }

    static func parse(_ data: Data, now: Date = Date()) -> AgentUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any]
        else { return nil }

        let fetchedAt = (cached["fetchedAtMs"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }

        // A window that has rolled over since the cache was written describes a
        // window that no longer exists. Showing 31% of a five-hour limit that
        // reset two days ago is worse than showing nothing: nothing is read as
        // "Relay does not know", and the bar was read as "you have spent a
        // third of your afternoon".
        let windows = ClaudeUsageWindows.parse(utilization).filter { !$0.hasRolledOver(by: now) }
        guard !windows.isEmpty else { return nil }

        return AgentUsage(kind: .claude, windows: windows, fetchedAt: fetchedAt)
    }
}
