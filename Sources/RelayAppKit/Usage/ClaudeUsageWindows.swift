import Foundation

/// The shape of every answer Claude gives about its own limits.
///
/// `~/.claude.json` stores the body of the CLI's usage request verbatim, so the
/// file it leaves behind and the endpoint it got it from are read by the same
/// code. That is the only reason Relay can fall back from one to the other
/// without a second parser to keep in step with the first.
enum ClaudeUsageWindows {
    static func parse(_ utilization: [String: Any]) -> [UsageWindow] {
        // `limits` is the richer of the two shapes: it names a model-scoped
        // limit, which the flat buckets beside it cannot.
        (utilization["limits"] as? [[String: Any]]).map(windows(from:))
            ?? buckets(from: utilization)
    }

    private static func windows(from limits: [[String: Any]]) -> [UsageWindow] {
        limits.compactMap { limit in
            guard let percent = limit["percent"] as? Double else { return nil }
            return UsageWindow(
                span: span(for: limit),
                fraction: percent / 100,
                resetsAt: resetDate(limit["resets_at"])
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
            guard let bucket = utilization[key] as? [String: Any] else { return nil }
            // The statusline calls it `used_percentage` and the cache calls it
            // `utilization`; both are whole percents of the same figure.
            guard let percent = (bucket["utilization"] ?? bucket["used_percentage"]) as? Double
            else { return nil }
            return UsageWindow(
                span: span,
                fraction: percent / 100,
                resetsAt: resetDate(bucket["resets_at"])
            )
        }
    }

    /// Reset times arrive as ISO 8601 in every shape seen so far, and as epoch
    /// seconds in the one Codex uses — both are accepted here so that a change
    /// of mind upstream costs a window rather than the whole reading.
    static func resetDate(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        guard let text = value as? String else { return nil }
        return date(fromISO8601: text)
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
