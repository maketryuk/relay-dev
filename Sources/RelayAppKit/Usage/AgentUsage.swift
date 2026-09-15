import Foundation
import RelayProtocol

/// One rate-limit window an agent reports against.
struct UsageWindow: Equatable, Identifiable, Sendable {
    /// Short label for the bar: `5h`, `wk`, or a model's name when the limit is
    /// scoped to one.
    var label: String
    /// 0…1. The providers report whole percents; the fraction is what a meter
    /// wants.
    var fraction: Double
    /// When the window rolls over, if the provider said.
    var resetsAt: Date?

    var id: String { label }

    var percent: Int { Int((fraction * 100).rounded()) }
}

/// What one agent's limits look like right now.
struct AgentUsage: Equatable, Identifiable, Sendable {
    var kind: SessionKind
    var windows: [UsageWindow]
    /// When the CLI last heard this from its provider. Relay reads a cache, not
    /// a live figure, and an hour-old number should not be presented as one.
    var fetchedAt: Date?

    var id: String { kind.rawValue }

    /// The window closest to rolling over, which is the one worth showing a
    /// countdown for.
    var nextReset: Date? {
        windows.compactMap(\.resetsAt).min()
    }
}

/// Turns a duration into the shape both CLIs use: the two largest units that
/// still say something.
///
/// `2h 12m`, `1d 6h`, `59m`. Never `0m`, because a window that has just rolled
/// over reads better as "now" than as nothing at all.
enum UsageFormatting {
    static func countdown(to date: Date, from now: Date = Date()) -> String? {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return nil }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        return "\(max(minutes, 1))m"
    }
}
