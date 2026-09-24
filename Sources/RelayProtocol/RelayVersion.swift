import Foundation

/// The single source of truth for the application version.
///
/// `Scripts/build-app.sh` reads it from here so the bundle, the daemon and the
/// About pane can never disagree about which build is running.
public enum RelayVersion {
    /// `MAJOR.MINOR.BUILD`, where the last number counts published builds
    /// rather than bug fixes: it goes up for every build that ships and resets
    /// when the minor moves. Bumped with `Scripts/bump-version.sh`, never by
    /// hand, so that nothing else in the file can be edited by mistake.
    public static let current = "0.7.0"
}
