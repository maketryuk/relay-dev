import Foundation
import RelayProtocol

/// Reads the limits Claude Code has already fetched.
///
/// Claude Code caches its own utilisation in `~/.claude.json`, so Relay reads
/// that rather than asking Anthropic itself: it needs no credentials, makes no
/// request, and cannot disagree with what the CLI shows. Nothing else in that
/// file is touched, and the credentials beside it are never opened.
enum ClaudeUsageReader {
    static var defaultLocation: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude.json")
    }

    static func read(from url: URL = defaultLocation) -> AgentUsage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> AgentUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any]
        else { return nil }

        let fetchedAt = (cached["fetchedAtMs"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }

        // `limits` is the richer of the two shapes the file carries: it names a
        // model-scoped limit, which the flat buckets beside it cannot.
        let windows = (utilization["limits"] as? [[String: Any]]).map(self.windows(from:))
            ?? buckets(from: utilization)
        guard !windows.isEmpty else { return nil }

        return AgentUsage(kind: .claude, windows: windows, fetchedAt: fetchedAt)
    }

    private static func windows(from limits: [[String: Any]]) -> [UsageWindow] {
        limits.compactMap { limit in
            guard let percent = limit["percent"] as? Double else { return nil }
            return UsageWindow(
                span: span(for: limit),
                fraction: percent / 100,
                resetsAt: (limit["resets_at"] as? String).flatMap(date(fromISO8601:))
            )
        }
    }

    /// A limit that applies to one model is named after it — that is the only
    /// thing that tells two otherwise identical weekly bars apart.
    private static func span(for limit: [String: Any]) -> UsageWindow.Span {
        if let scope = limit["scope"] as? [String: Any],
           let model = scope["model"] as? [String: Any],
           let name = model["display_name"] as? String, !name.isEmpty {
            return .model(name)
        }
        // The list says which group a limit belongs to but not how long the
        // window is; the buckets beside it are named for their lengths, and the
        // session one is five hours.
        return (limit["group"] as? String) == "session" ? .rolling(minutes: 300) : .weekly
    }

    /// The older, flatter shape, kept as a fallback so an update to the CLI that
    /// drops `limits` leaves the bar working rather than empty.
    private static func buckets(from utilization: [String: Any]) -> [UsageWindow] {
        let known: [(String, UsageWindow.Span)] = [
            ("five_hour", .rolling(minutes: 300)),
            ("seven_day", .weekly),
        ]
        return known.compactMap { key, span in
            guard let bucket = utilization[key] as? [String: Any],
                  let percent = bucket["utilization"] as? Double
            else { return nil }
            return UsageWindow(
                span: span,
                fraction: percent / 100,
                resetsAt: (bucket["resets_at"] as? String).flatMap(date(fromISO8601:))
            )
        }
    }

    /// Fractional seconds are present in this file and absent from the formatter
    /// that does not ask for them, so both are tried.
    static func date(fromISO8601 text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
