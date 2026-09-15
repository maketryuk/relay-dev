import Foundation

/// Decides whether the output arriving from a session means it is working.
///
/// A terminal interface that is doing nothing still repaints — a spinner, a
/// blinking cursor, a status line that redraws every second — and treating every
/// byte as work made an idle agent flicker between "Working" and "Idle"
/// indefinitely. Work is *sustained* output; a repaint is a blip.
///
/// A value type with the clock passed in, so the rule can be exercised directly
/// instead of only through a real PTY and real waiting.
struct ActivityWindow {
    /// How long output must be quiet before the session counts as settled.
    static let quietThreshold: TimeInterval = 0.7
    /// How long output must keep coming before it counts as work. Long enough
    /// that a redraw does not qualify, short enough that a real reply is
    /// reported while it is still being written.
    static let sustainedOutput: TimeInterval = 0.5

    private(set) var lastOutputAt: Date
    /// When the current unbroken run of output began.
    private var burstStartedAt: Date

    init(startedAt: Date) {
        lastOutputAt = startedAt
        burstStartedAt = startedAt
    }

    mutating func noteOutput(at moment: Date) {
        if moment.timeIntervalSince(lastOutputAt) >= Self.quietThreshold {
            burstStartedAt = moment
        }
        lastOutputAt = moment
    }

    /// Resets the run, so what the user just triggered is judged on its own.
    mutating func noteUserInput(at moment: Date) {
        lastOutputAt = moment
        burstStartedAt = moment
    }

    /// True while output is still arriving, as opposed to having stopped.
    func isProducingOutput(now: Date) -> Bool {
        now.timeIntervalSince(lastOutputAt) < Self.quietThreshold
    }

    func isWorking(now: Date) -> Bool {
        isProducingOutput(now: now) && lastOutputAt.timeIntervalSince(burstStartedAt) >= Self.sustainedOutput
    }
}
