import Foundation
import Testing

@testable import RelayTracker

@Suite("Typed lengths of time")
struct WorkDurationTests {
    @Test("Hours and minutes, however they are written", arguments: [
        ("1h 30m", 90),
        ("1h30m", 90),
        ("2h", 120),
        ("45m", 45),
        ("1.5h", 90),
        ("1,5h", 90),
        ("1:30", 90),
        ("0:05", 5),
        ("45", 45),
        ("1 hour 15 minutes", 75),
        ("1h 30", 90),
        ("  3H  ", 180),
    ])
    func english(typed: String, minutes: Int) {
        #expect(WorkDuration.minutes(from: typed) == minutes)
    }

    @Test("And in Russian", arguments: [
        ("1ч 30м", 90),
        ("2 ч", 120),
        ("40 мин", 40),
        ("1 час 5 минут", 65),
        ("1ч. 10мин.", 70),
    ])
    func russian(typed: String, minutes: Int) {
        #expect(WorkDuration.minutes(from: typed) == minutes)
    }

    @Test("Nothing, nonsense and days are refused", arguments: [
        "", "   ", "0", "0m", "abc", "1d", "1w 2h", "1:75", "1:5", "h", "30 apples", "-15",
    ])
    func refused(typed: String) {
        #expect(WorkDuration.minutes(from: typed) == nil)
    }

    @Test("A timer's seconds round up to the minute, and never to nothing")
    func timerRoundsUp() {
        #expect(WorkDuration.minutes(in: 20) == 1)
        #expect(WorkDuration.minutes(in: 60) == 1)
        #expect(WorkDuration.minutes(in: 61) == 2)
        #expect(WorkDuration.minutes(in: 90 * 60) == 90)
        #expect(WorkDuration.minutes(in: 0) == 1)
    }

    @Test("Written back the way YouTrack writes it")
    func written() {
        #expect(WorkDuration.written(45) == "45m")
        #expect(WorkDuration.written(120) == "2h")
        #expect(WorkDuration.written(95) == "1h 35m")
    }
}
