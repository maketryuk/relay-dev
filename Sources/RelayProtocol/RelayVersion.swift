import Foundation

/// The single source of truth for the application version.
///
/// `Scripts/build-app.sh` reads it from here so the bundle, the daemon and the
/// About pane can never disagree about which build is running.
public enum RelayVersion {
    /// Semantic version: breaking behaviour bumps major, features bump minor,
    /// fixes bump patch.
    public static let current = "0.2.0"
}
