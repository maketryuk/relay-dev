import RelayProtocol
import SwiftUI

public extension RuntimeStatus {
    var tint: Color {
        switch self {
        case .working: Theme.Palette.statusWorking
        case .waiting: Theme.Palette.statusWaiting
        case .error: Theme.Palette.statusError
        case .finished: Theme.Palette.statusFinished
        case .starting: Theme.Palette.statusWorking
        case .idle: Theme.Palette.statusIdle
        case .offline: Theme.Palette.statusOffline
        }
    }

    /// Only genuinely transient states animate; a wall of pulsing dots would be
    /// noise rather than signal.
    var pulses: Bool {
        switch self {
        case .working, .starting, .waiting: true
        default: false
        }
    }
}
