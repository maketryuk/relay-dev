import Foundation
import RelayTracker
import Testing

@testable import RelayAppKit

@Suite("Timesheet")
struct TimesheetTests {
    /// Weeks from Monday, in UTC: nothing here may depend on where the Mac
    /// running the tests thinks it is.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func day(_ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }

    private func entry(_ id: String, minutes: Int, on month: Int, _ day: Int, hour: Int = 12) -> TrackerTimeEntry {
        let date = calendar.date(byAdding: .hour, value: hour, to: self.day(month, day))!
        return TrackerTimeEntry(item: TrackerWorkItem(id: id, minutes: minutes, date: date), issueKey: "WEB-1", summary: "")
    }

    @Test("A week is the seven days from its first, whichever of them it was opened on")
    func week() {
        let days = Timesheet.days(.week, around: day(10, 1), entries: [], schedule: .standard, in: calendar)
        #expect(days.map(\.start) == [day(9, 28), day(9, 29), day(9, 30), day(10, 1), day(10, 2), day(10, 3), day(10, 4)])
        let borrowed = days.filter { !$0.isInPeriod }
        #expect(borrowed.isEmpty)
    }

    @Test("Time lands on the day it was recorded on, and a day off asks for none")
    func dayTotals() {
        let days = Timesheet.days(
            .week,
            around: day(9, 28),
            entries: [
                entry("late", minutes: 40, on: 9, 28, hour: 17),
                entry("early", minutes: 30, on: 9, 28, hour: 9),
                entry("saturday", minutes: 20, on: 10, 3),
            ],
            schedule: .standard,
            in: calendar
        )

        #expect(days[0].entries.map(\.id) == ["early", "late"])
        #expect(days[0].minutes == 70)
        #expect(days[0].expected == 480)
        #expect(days[5].minutes == 20)
        #expect(days[5].expected == 0)
        let totals = Timesheet.totals(of: days)
        #expect(totals.minutes == 90)
        #expect(totals.expected == 5 * 480)
    }

    @Test("A month is laid out in whole weeks, and the days it borrows count towards nothing")
    func month() {
        // September 2026 begins on a Tuesday and ends on a Wednesday.
        let days = Timesheet.days(
            .month,
            around: day(9, 15),
            entries: [entry("borrowed", minutes: 45, on: 8, 31), entry("own", minutes: 60, on: 9, 1)],
            schedule: .standard,
            in: calendar
        )

        #expect(days.first?.start == day(8, 31))
        #expect(days.last?.start == day(10, 4))
        #expect(days.count == 35)
        #expect(days.first?.isInPeriod == false)
        #expect(days.first?.minutes == 45)
        let totals = Timesheet.totals(of: days)
        #expect(totals.minutes == 60)
        #expect(totals.expected == 22 * 480)
    }

    @Test("A month is read over the whole of the weeks it is drawn in")
    func monthIsReadWhole() {
        let shown = Timesheet.shown(.month, around: day(9, 15), in: calendar)
        #expect(shown.first == day(8, 31))
        #expect(shown.last == day(10, 4))
    }

    @Test("Paging goes by the span on screen")
    func paging() {
        #expect(Timesheet.moving(day(9, 30), by: 1, .week, in: calendar) == day(10, 7))
        #expect(Timesheet.moving(day(9, 30), by: -1, .month, in: calendar) == day(8, 30))
    }
}
