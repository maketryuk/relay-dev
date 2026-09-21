import Foundation
import RelayProtocol

/// Asks Anthropic what this account's limits are, with Claude Code's own token.
///
/// The CLI knows its limits from the headers of every answer it gets, and keeps
/// them to itself; the file it writes is refreshed only when it asks this
/// endpoint, which it does seldom enough that the cache is routinely days
/// stale. A client that reads the cache therefore shows a number that was true
/// once, which is the bug this exists to fix — the endpoint is the same one the
/// CLI uses, answered for the same account, so the figure matches what the
/// status line inside the terminal says.
enum ClaudeUsageEndpoint {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// Long enough for a slow connection, short enough that a hung request does
    /// not hold the next refresh behind it.
    static let timeout: TimeInterval = 10

    static func request(token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // The header the OAuth scheme these tokens belong to is gated behind.
        // Without it the request is refused whatever the token says.
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("Relay/\(RelayVersion.current)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func parse(_ data: Data, fetchedAt: Date) -> AgentUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // The endpoint answers with the object the CLI stores verbatim under
        // `utilization`, so it is read by the same code.
        let windows = ClaudeUsageWindows.parse(root)
        guard !windows.isEmpty else { return nil }
        return AgentUsage(kind: .claude, windows: windows, fetchedAt: fetchedAt)
    }

    /// When a refusal says to come back later.
    ///
    /// The endpoint is not generous: polling it the way a status bar would like
    /// to earns a 429, and ignoring the `Retry-After` that comes with one keeps
    /// the refusal alive.
    ///
    /// A rejected token waits longer and not forever. It is Claude Code's token
    /// and Claude Code refreshes it, so the answer to being turned away is to
    /// come back after it has had the chance to — giving up for the session
    /// would leave the bar on the cache until the app is restarted.
    static func retryDate(for response: HTTPURLResponse, from now: Date) -> Date? {
        guard !(200 ..< 300).contains(response.statusCode) else { return nil }
        if response.statusCode == 401 || response.statusCode == 403 {
            return now.addingTimeInterval(rejectedTokenBackoff)
        }

        let header = response.value(forHTTPHeaderField: "Retry-After")
        if let seconds = header.flatMap(Double.init) {
            return now.addingTimeInterval(seconds)
        }
        if let date = header.flatMap(httpDate(from:)) {
            return date
        }
        return now.addingTimeInterval(defaultBackoff)
    }

    /// What to wait when a refusal names no time of its own.
    static let defaultBackoff: TimeInterval = 15 * 60

    /// Long enough for the CLI to have renewed the token it was handed.
    static let rejectedTokenBackoff: TimeInterval = 30 * 60

    private static func httpDate(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}
