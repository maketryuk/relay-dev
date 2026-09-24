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
}

/// The shape a status is drawn as. Colour only confirms it.
enum StatusMark: Equatable {
    /// Something is under way — the one mark that moves.
    case spinner
    /// An agent has asked something and nothing goes on until it is answered.
    case question
    /// Done, with a result waiting to be read.
    case check
    /// At rest or stopped, where a colour is all there is to say.
    case dot
}

extension RuntimeStatus {
    var mark: StatusMark {
        switch self {
        case .working, .starting: .spinner
        case .waiting: .question
        case .finished: .check
        case .error, .idle, .offline: .dot
        }
    }
}
