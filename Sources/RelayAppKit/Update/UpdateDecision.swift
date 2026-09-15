import Foundation
import RelayUI

/// Whether a release is worth telling the user about.
enum UpdateDecision {
    /// True when `release` is newer than what is running.
    ///
    /// Equal versions are not an update, and an older release is not either —
    /// which matters, because a build made from `main` can legitimately be
    /// ahead of the newest tag, and offering to "update" it backwards would be
    /// a downgrade dressed as progress.
    static func isWorthOffering(_ release: Release, running: SemanticVersion) -> Bool {
        // A pre-release is offered only to a build that is one itself. Somebody
        // running a cut release did not ask to be moved onto something the
        // author is still deciding about; somebody running `0.1.0-dev` plainly
        // did.
        if release.isPreRelease, running.preRelease.isEmpty { return false }
        return running < release.version
    }

    /// How long to leave between automatic checks.
    ///
    /// Long enough that Relay is not talking to GitHub while somebody works,
    /// short enough that a release lands within a day of being cut.
    static let checkInterval: TimeInterval = 6 * 60 * 60

    static func shouldCheckNow(lastCheckedAt: Date?, now: Date) -> Bool {
        guard let lastCheckedAt else { return true }
        return now.timeIntervalSince(lastCheckedAt) >= checkInterval
    }

    /// What to say when GitHub refuses the question.
    ///
    /// 404 is the one worth naming: it is what a private repository returns to
    /// an unauthenticated request, and it is indistinguishable from a repository
    /// that does not exist. Reporting it as "nothing published" would hide a
    /// setting the user can actually change.
    @MainActor
    static func message(forStatus status: Int) -> String {
        switch status {
        case 404: relayLocalized("Relay cannot see the releases. A private repository needs to be public for updates to work.")
        case 403, 429: relayLocalized("GitHub is rate-limiting the update check. It will try again later.")
        default: String(format: relayLocalized("The update check failed: HTTP %d"), status)
        }
    }
}
