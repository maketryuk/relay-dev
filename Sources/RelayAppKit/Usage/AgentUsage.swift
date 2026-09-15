import Foundation
import RelayProtocol
import RelayUI

/// One rate-limit window an agent reports against.
struct UsageWindow: Equatable, Identifiable, Sendable {
    /// What kind of window this is, kept apart from how it is written so the bar
    /// can be terse and the tooltip can be plain. `wk` is fine in a strip four
    /// pixels from the bottom of the screen and means nothing on its own.
    enum Span: Equatable, Sendable {
        case rolling(minutes: Int)
        case weekly
        /// Capped for one model, which names itself.
        case model(String)
    }

    var span: Span
    /// 0…1. The providers report whole percents; the fraction is what a meter
    /// wants.
    var fraction: Double
    /// When the window rolls over, if the provider said.
    var resetsAt: Date?

    var id: String { label }

    var percent: Int { Int((fraction * 100).rounded()) }

    /// For the bar, where there is room for two or three characters.
    var label: String {
        switch span {
        case let .rolling(minutes):
            if minutes >= 1_440, minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
            if minutes >= 60 { return "\(minutes / 60)h" }
            return "\(minutes)m"
        case .weekly: return "wk"
        case let .model(name): return name
        }
    }

    /// For the tooltip, where the question is what the window actually is.
    @MainActor
    var name: String {
        switch span {
        case let .rolling(minutes):
            if minutes >= 1_440, minutes % 1_440 == 0 {
                return String(format: relayLocalized("Every %d days"), minutes / 1_440)
            }
            if minutes >= 60 {
                return String(format: relayLocalized("Every %d hours"), minutes / 60)
            }
            return String(format: relayLocalized("Every %d minutes"), minutes)
        case .weekly: return relayLocalized("Weekly")
        case let .model(name): return name
        }
    }
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

    /// The window nearest to stopping you, which is the one a single line should
    /// show.
    ///
    /// Not the shortest window: a five-hour bar at 5% matters less than a weekly
    /// one at 90%, and the point of a one-line summary is to name the limit that
    /// will bite first.
    var mostUsedWindow: UsageWindow? {
        windows.max { $0.fraction < $1.fraction }
    }
}

/// How much of the usage figures to show at a glance.
enum UsageDetail: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Every window, for each agent.
    case detailed
    /// Only the window closest to running out; the rest are a hover away.
    case compact

    var id: String { rawValue }

    @MainActor
    var title: String {
        switch self {
        case .detailed: relayLocalized("Detailed")
        case .compact: relayLocalized("Compact")
        }
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
