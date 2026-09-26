import Foundation

/// Where a YouTrack is and the token it is reached with.
public struct YouTrackConnection: Equatable, Sendable {
    /// The instance's own address — `https://studio.youtrack.cloud`, or
    /// `https://tracker.example.com/youtrack` for one under a path — with no
    /// `/api` and no trailing slash.
    public var baseURL: URL
    /// A permanent token, `perm:…`.
    public var token: String

    public init(baseURL: URL, token: String) {
        self.baseURL = baseURL
        self.token = token
    }

    /// The address as it should be stored, from what was typed or pasted.
    ///
    /// Lenient about what people paste — no scheme, a trailing slash, the API's
    /// own address — and strict about where a token may go: plain http only to
    /// this machine, since anywhere else it crosses the network readable, and
    /// never an address with a password in it.
    public static func address(from typed: String) -> URL? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        let isLocal = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        guard scheme == "https" || (scheme == "http" && isLocal) else { return nil }

        // An instance can live under a path of its own, so the path cannot
        // simply be dropped — but a page of it pasted from the address bar
        // ends where YouTrack's own pages begin.
        var segments = components.path.split(separator: "/").map(String.init)
        if let page = segments.firstIndex(where: pageSegments.contains) {
            segments.removeSubrange(page...)
        }
        components.scheme = scheme
        components.path = segments.isEmpty ? "" : "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The first path segment of every page YouTrack draws, and of its API.
    private static let pageSegments: Set<String> = [
        "api", "issue", "issues", "agiles", "dashboard", "projects", "admin", "users", "articles", "reports",
        "timesheets", "newIssue",
    ]
}
