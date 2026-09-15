import Foundation

/// The single source of truth for the application version.
///
/// `Scripts/build-app.sh` reads it from here so the bundle, the daemon and the
/// About pane can never disagree about which build is running.
public enum RelayVersion {
    /// Pre-release. Nothing has shipped yet; 0.1.0 will be the first release,
    /// cut when the app is judged ready rather than when a day of work ends.
    public static let current = "0.1.0-dev"
}
