import Foundation

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
}
