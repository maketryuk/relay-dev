import Foundation
import RelayTracker

/// The time recorded on an issue, as the issue pane lists it: by day, newest
/// first, with what each day and each person came to.
enum WorkLog {
    struct Day: Identifiable, Equatable {
        /// The start of the day, in the calendar it was grouped by.
        var start: Date
        var minutes: Int
        var items: [TrackerWorkItem]

        var id: Date { start }
    }

    static func days(of items: [TrackerWorkItem], in calendar: Calendar) -> [Day] {
        let grouped = Dictionary(grouping: items) { calendar.startOfDay(for: $0.date) }
        return grouped
            .map { start, items in
                Day(start: start, minutes: minutes(in: items), items: items.sorted { $0.date > $1.date })
            }
            .sorted { $0.start > $1.start }
    }

    static func minutes(in items: [TrackerWorkItem]) -> Int {
        items.reduce(0) { $0 + $1.minutes }
    }

    /// What one person recorded. Nil for an account nobody is signed in as,
    /// which has recorded nothing.
    static func items(_ items: [TrackerWorkItem], by login: String?) -> [TrackerWorkItem] {
        guard let login else { return [] }
        return items.filter { $0.author?.login == login }
    }
}
