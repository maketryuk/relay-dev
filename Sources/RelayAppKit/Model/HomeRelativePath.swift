import Foundation

/// A path as a person writes it.
///
/// Four places had grown their own copy of this, and a panel that says
/// `/Users/someone/.ssh/config` where the rest of the app says `~/.ssh/config`
/// reads as a different file.
enum HomeRelativePath {
    static func abbreviating(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    static func abbreviating(_ url: URL) -> String {
        abbreviating(url.path)
    }
}
