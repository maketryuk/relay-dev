import Foundation
import RelayTracker

/// The days a timesheet lays out, and what was recorded on each: a week of
/// columns, or a month of whole weeks.
enum Timesheet {
    enum Span: String, CaseIterable, Identifiable {
        case week
        case month

        var id: String { rawValue }

        var component: Calendar.Component {
            switch self {
            case .week: .weekOfYear
            case .month: .month
            }
        }
    }

    struct Day: Identifiable, Equatable {
        /// The start of the day, in the calendar it was laid out in.
        var start: Date
        var entries: [TrackerTimeEntry]
        var minutes: Int
        /// What a working day asks for; nothing on a day off.
        var expected: Int
        /// False for the days a month grid borrows from the months either side
        /// to fill its first and last weeks.
        var isInPeriod: Bool

        var id: Date { start }
    }

    /// The first and last day of the week or month a day is in.
    static func period(_ span: Span, around day: Date, in calendar: Calendar) -> (first: Date, last: Date) {
        let interval = calendar.dateInterval(of: span.component, for: day)
            ?? DateInterval(start: calendar.startOfDay(for: day), duration: 86_400)
        let last = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
        return (interval.start, calendar.startOfDay(for: last))
    }

    /// The days to lay out and read: a week is its seven, a month is every
    /// week it touches, whole, so that its grid starts on the first day of a
    /// week like every calendar does.
    static func shown(_ span: Span, around day: Date, in calendar: Calendar) -> (first: Date, last: Date) {
        let (first, last) = period(span, around: day, in: calendar)
        guard span == .month else { return (first, last) }
        return (period(.week, around: first, in: calendar).first, period(.week, around: last, in: calendar).last)
    }

    static func days(
        _ span: Span,
        around day: Date,
        entries: [TrackerTimeEntry],
        schedule: TrackerWorkSchedule,
        in calendar: Calendar
    ) -> [Day] {
        let period = period(span, around: day, in: calendar)
        let (first, last) = shown(span, around: day, in: calendar)
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.item.date) }

        var days: [Day] = []
        var cursor = first
        while cursor <= last {
            let recorded = (byDay[cursor] ?? []).sorted { $0.item.date < $1.item.date }
            let isWorkday = schedule.workdays.contains(calendar.component(.weekday, from: cursor))
            days.append(Day(
                start: cursor,
                entries: recorded,
                minutes: recorded.reduce(0) { $0 + $1.item.minutes },
                expected: isWorkday ? schedule.minutesADay : 0,
                isInPeriod: cursor >= period.first && cursor <= period.last
            ))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }

    /// What the period came to, and what it asked for: the borrowed days of a
    /// month grid count towards neither.
    static func totals(of days: [Day]) -> (minutes: Int, expected: Int) {
        days.filter(\.isInPeriod).reduce(into: (0, 0)) { total, day in
            total.0 += day.minutes
            total.1 += day.expected
        }
    }

    /// The same day a week or a month on, or back.
    static func moving(_ day: Date, by steps: Int, _ span: Span, in calendar: Calendar) -> Date {
        calendar.date(byAdding: span.component, value: steps, to: day) ?? day
    }
}
