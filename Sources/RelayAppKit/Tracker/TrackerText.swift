import Foundation
import RelayTracker
import RelayUI

/// The tracker's facts in the window's words.
@MainActor
enum TrackerText {
    /// What went wrong, in a sentence, and what the tracker said about it when
    /// it said something.
    static func describe(_ error: TrackerError) -> String {
        let sentence = switch error.kind {
        case .invalidAddress:
            relayLocalized("Relay only sends a token to an https:// address. Check the tracker's address.")
        case .unreachable:
            relayLocalized("The tracker did not answer. Check the address and the connection.")
        case .timedOut:
            relayLocalized("The tracker took too long to answer.")
        case let .redirected(to):
            to.map { String(format: relayLocalized("The address sends requests on to %@. Use that address instead."), $0) }
                ?? relayLocalized("The address sends requests on somewhere else. Use the address the tracker is at.")
        case .unauthorized:
            relayLocalized("The tracker refused the token. Make a new one and connect again.")
        case .forbidden:
            relayLocalized("Your account is not allowed to do that.")
        case .notFound:
            relayLocalized("Not found, or not visible to your account.")
        case .rateLimited:
            relayLocalized("The tracker asked for fewer requests. Try again in a moment.")
        case .rejected:
            relayLocalized("The tracker refused.")
        case let .serverFailure(status):
            String(format: relayLocalized("The tracker failed (%d). Try again."), status)
        case .uncertain:
            relayLocalized("No answer came back, so it may or may not have been done. Reload before trying again.")
        case .notTheAPI:
            relayLocalized("What answered is not the tracker's API. Check the address.")
        }
        guard let said = error.message, !said.isEmpty else { return sentence }
        return sentence + "\n" + said
    }

    /// `1 h 30 min`, in the window's language.
    static func duration(minutes: Int) -> String {
        let (hours, rest) = WorkDuration.parts(of: minutes)
        switch (hours, rest) {
        case (0, _): return String(format: relayLocalized("%d min"), rest)
        case (_, 0): return String(format: relayLocalized("%d h"), hours)
        default: return String(format: relayLocalized("%d h %d min"), hours, rest)
        }
    }

    /// `14 сент. 2026 г.`, in the window's language rather than the Mac's.
    static func day(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, locale: Localization.shared.locale))
    }

    /// `1:05:09`, for a clock that is running.
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let (hours, minutes, rest) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
