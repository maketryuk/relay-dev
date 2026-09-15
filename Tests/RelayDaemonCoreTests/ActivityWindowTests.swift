import Foundation
import Testing

@testable import RelayDaemonCore

@Suite("Activity window")
struct ActivityWindowTests {
    private let start = Date(timeIntervalSince1970: 1_000)

    private func at(_ offset: TimeInterval) -> Date {
        start.addingTimeInterval(offset)
    }

    @Test("A repaint is not work")
    func shortBurstIsNotWork() {
        // An idle agent still redraws its spinner and its status line. Counting
        // that as work made the status flicker between Working and Idle for as
        // long as the agent sat there doing nothing.
        var window = ActivityWindow(startedAt: start)
        window.noteOutput(at: at(5))
        window.noteOutput(at: at(5.05))

        #expect(window.isProducingOutput(now: at(5.1)))
        #expect(!window.isWorking(now: at(5.1)))
    }

    @Test("Output that keeps coming is work")
    func sustainedOutputIsWork() {
        var window = ActivityWindow(startedAt: start)
        for step in stride(from: 5.0, through: 6.0, by: 0.1) {
            window.noteOutput(at: at(step))
        }
        #expect(window.isWorking(now: at(6.1)))
    }

    @Test("Work ends when the output stops")
    func silenceEndsTheRun() {
        var window = ActivityWindow(startedAt: start)
        for step in stride(from: 5.0, through: 6.0, by: 0.1) {
            window.noteOutput(at: at(step))
        }
        #expect(!window.isProducingOutput(now: at(7)))
        #expect(!window.isWorking(now: at(7)))
    }

    @Test("A new run starts after a silence, rather than continuing the last one")
    func quietBreaksTheRun() {
        // Two repaints a minute apart are two blips, not a minute of work.
        var window = ActivityWindow(startedAt: start)
        window.noteOutput(at: at(5))
        window.noteOutput(at: at(65))
        #expect(!window.isWorking(now: at(65.1)))
    }

    @Test("A keystroke starts the measurement over")
    func userInputResetsTheRun() {
        // What the user just asked for is judged on its own, not as a
        // continuation of whatever the screen happened to be redrawing.
        var window = ActivityWindow(startedAt: start)
        for step in stride(from: 5.0, through: 6.0, by: 0.1) {
            window.noteOutput(at: at(step))
        }
        window.noteUserInput(at: at(6.1))
        window.noteOutput(at: at(6.2))
        #expect(!window.isWorking(now: at(6.3)))
    }
}
