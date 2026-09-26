import Foundation

/// Lengths of time as a person types them when saying how long something took.
public enum WorkDuration {
    /// Minutes in `1h 30m`, `90m`, `1.5h`, `1:30`, a bare `45`, and the same in
    /// Russian — `1ч 30м`, `2 ч`, `40 мин`. Nil for anything else, and for
    /// nothing at all.
    ///
    /// Days and weeks are refused rather than guessed at: a tracker counts a
    /// day as a working day of however many hours its administrator set, and
    /// eight hours recorded as twenty-four, or the other way round, is a
    /// mistake nobody sees until the invoice.
    public static func minutes(from text: String) -> Int? {
        let typed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ",", with: ".")
        guard !typed.isEmpty else { return nil }

        if let bare = Int(typed) {
            return bare > 0 ? bare : nil
        }

        let clock = typed.split(separator: ":", omittingEmptySubsequences: false)
        if clock.count == 2, let hours = Int(clock[0]), let minutes = Int(clock[1]), clock[1].count == 2 {
            let total = hours * 60 + minutes
            return minutes < 60 && total > 0 ? total : nil
        }

        var total = 0.0
        var rest = Substring(typed)
        var followsHours = false
        while true {
            rest = rest.drop { $0 == " " }
            guard !rest.isEmpty else { break }
            let number = rest.prefix { $0.isNumber || $0 == "." }
            guard !number.isEmpty, let amount = Double(number) else { return nil }
            rest = rest.dropFirst(number.count).drop { $0 == " " }
            let unit = rest.prefix { $0.isLetter }
            // `1h 30` means what it would on paper: the number after the hours
            // is minutes.
            guard let perUnit = unit.isEmpty && followsHours ? 1 : minutesPer(String(unit)) else { return nil }
            rest = rest.dropFirst(unit.count).drop { $0 == "." }
            total += amount * perUnit
            followsHours = perUnit == 60
        }
        let rounded = Int(total.rounded())
        return rounded > 0 ? rounded : nil
    }

    private static func minutesPer(_ unit: String) -> Double? {
        switch unit {
        case "h", "hr", "hrs", "hour", "hours", "ч", "час", "часа", "часов": 60
        case "m", "min", "mins", "minute", "minutes", "м", "мин", "минута", "минуты", "минут": 1
        default: nil
        }
    }

    /// Whole minutes in what a timer measured, rounded up: a minute started is
    /// a minute worked, and a timer stopped after twenty seconds has still
    /// measured something.
    public static func minutes(in interval: TimeInterval) -> Int {
        max(1, Int((interval / 60).rounded(.up)))
    }

    /// Hours and minutes, for writing a length back out.
    public static func parts(of minutes: Int) -> (hours: Int, minutes: Int) {
        (minutes / 60, minutes % 60)
    }

    /// `1h 30m`, the way YouTrack writes a period when it has not written it
    /// itself. The app writes its own lengths, in its own language.
    static func written(_ minutes: Int) -> String {
        let (hours, rest) = parts(of: minutes)
        switch (hours, rest) {
        case (0, _): return "\(rest)m"
        case (_, 0): return "\(hours)h"
        default: return "\(hours)h \(rest)m"
        }
    }
}
