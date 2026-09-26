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

        /// How long the window is, for telling the one a working day runs
        /// into from the ones behind it. A model's cap is a weekly one.
        var minutes: Int {
            switch self {
            case let .rolling(minutes): minutes
            case .weekly, .model: 7 * 1_440
            }
        }
    }

    var span: Span
    /// 0…1. The providers report whole percents; the fraction is what a meter
    /// wants.
    var fraction: Double
    /// When the window rolls over, if the provider said.
    var resetsAt: Date?

    var id: String { label }

    var percent: Int { Int((fraction * 100).rounded()) }

    /// Whether the window this figure belongs to has already been replaced.
    ///
    /// Both agents report what has been spent in the window running when they
    /// were asked, so a reading whose reset has passed is an answer about a
    /// window that is over. What the one after it holds is a separate question,
    /// and each reader answers it differently.
    func hasRolledOver(by now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

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
                return relayLocalized("Every %d days", count: minutes / 1_440)
            }
            if minutes >= 60 {
                return relayLocalized("Every %d hours", count: minutes / 60)
            }
            return relayLocalized("Every %d minutes", count: minutes)
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

    /// The window a single line shows: the shortest, which is the limit a
    /// working day runs into, unless a longer one is nearly spent and fuller.
    ///
    /// Not simply the fullest. A week at 35% outranks an afternoon at 20% for
    /// most of the week, while neither is about to stop anyone, and a line that
    /// followed it would show the week all week. A longer window matters when
    /// it is close to its end — a five-hour bar at 5% matters less than a
    /// weekly one at 90% — and then it is the one shown.
    var headlineWindow: UsageWindow? {
        guard let shortest = windows.min(by: { $0.span.minutes < $1.span.minutes }) else { return nil }
        let pressing = windows.filter { $0.fraction >= Self.nearlySpent && $0.fraction > shortest.fraction }
        return pressing.max { $0.fraction < $1.fraction } ?? shortest
    }

    /// How full a longer window has to be to take the line from the shortest.
    static let nearlySpent = 0.8

    /// The reset a line of this detail counts down to. One window shown is
    /// counted down on its own: beside `wk`, the five-hour window's two hours
    /// read as the week's.
    func countdownTarget(for detail: UsageDetail) -> Date? {
        switch detail {
        case .compact: headlineWindow?.resetsAt
        case .detailed: nextReset
        }
    }
}

/// How much of the usage figures the status bar shows.
///
/// Only the bar: the popover is where you go to look properly, and a panel that
/// hid half of what it was opened for would be answering a question nobody
/// asked.
enum UsageDetail: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Every window, for each agent.
    case detailed
    /// Only the window closest to running out.
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
/// `2h 12m`, `1d 6h`, `59m` — and `2 ч 12 мин` in Russian, whose window used to
/// show the English letters. Never `0m`, because a window that has just rolled
/// over reads better as "now" than as nothing at all.
enum UsageFormatting {
    static func countdown(to date: Date, from now: Date = Date(), locale: Locale) -> String? {
        let seconds = Int(date.timeIntervalSince(now))
        guard seconds > 0 else { return nil }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        // Cut to two units here, so the formatter decides only how they are
        // spelled and never which of them are shown.
        var shown = DateComponents()
        if days > 0 {
            shown.day = days
            shown.hour = hours > 0 ? hours : nil
        } else if hours > 0 {
            shown.hour = hours
            shown.minute = minutes > 0 ? minutes : nil
        } else {
            shown.minute = max(minutes, 1)
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let formatter = DateComponentsFormatter()
        formatter.calendar = calendar
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute]
        return formatter.string(from: shown)
    }
}
