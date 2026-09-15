import Foundation

/// A published build, as the update check understands it.
struct Release: Equatable, Sendable {
    var version: SemanticVersion
    /// What the release is called, for the banner.
    var name: String
    /// The `.zip` holding `Relay.app`.
    var downloadURL: URL
    var pageURL: URL
    var notes: String
    /// Marked as a pre-release on GitHub. Offered only to a build that is
    /// itself one.
    var isPreRelease: Bool
}

/// Reads GitHub's releases API.
///
/// Parsing is separated from fetching so the shapes that matter — a draft, a
/// release with no application in it, a tag that is not a version — can be
/// covered without a network.
enum ReleaseFeed {
    static let endpoint = URL(string: "https://api.github.com/repos/maketryuk/relay-dev/releases?per_page=10")!

    /// The newest published release, or nil when there is none.
    ///
    /// Drafts are skipped — a draft is not published. Pre-releases are kept and
    /// flagged: whether one is worth offering depends on what is running, and
    /// that is not this function's question.
    static func latest(from data: Data) -> Release? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return entries.compactMap(release(from:)).max { $0.version < $1.version }
    }

    static func release(from entry: [String: Any]) -> Release? {
        guard entry["draft"] as? Bool != true else { return nil }
        guard let tag = entry["tag_name"] as? String, let version = SemanticVersion(tag) else { return nil }
        guard let page = (entry["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }

        // A release with nothing to install is an announcement, not an update.
        let assets = entry["assets"] as? [[String: Any]] ?? []
        guard let download = assets.compactMap(applicationArchive(in:)).first else { return nil }

        return Release(
            version: version,
            name: (entry["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
            downloadURL: download,
            pageURL: page,
            notes: entry["body"] as? String ?? "",
            isPreRelease: entry["prerelease"] as? Bool == true
        )
    }

    /// The asset that actually contains the application.
    ///
    /// Matched by name rather than by position: a release may also carry a
    /// checksum file, notes, or an archive of the source that GitHub adds by
    /// itself, and installing one of those would be worse than finding nothing.
    static func applicationArchive(in asset: [String: Any]) -> URL? {
        guard let name = asset["name"] as? String,
              name.lowercased().hasPrefix("relay"),
              name.lowercased().hasSuffix(".zip"),
              let address = asset["browser_download_url"] as? String
        else { return nil }
        return URL(string: address)
    }
}
