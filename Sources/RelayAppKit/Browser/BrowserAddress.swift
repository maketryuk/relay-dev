import Foundation

/// What something typed into the address field means.
///
/// Mostly it means a development server, and those are typed the short way —
/// `localhost:5173`, `127.0.0.1:8000/admin` — so a bare host goes to http when
/// it is this machine or a private network and to https everywhere else, the
/// way Chrome's omnibox decides it. What looks like a sentence is searched for.
enum BrowserAddress {
    static func url(from typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("/") || text.hasPrefix("~/") {
            return URL(fileURLWithPath: (text as NSString).expandingTildeInPath)
        }

        let lowered = text.lowercased()
        let hasSpace = text.contains(where: \.isWhitespace)
        if !hasSpace, let scheme = explicitScheme(of: lowered), knownSchemes.contains(scheme) {
            return URL(string: text)
        }
        if !hasSpace, let host = host(of: text), looksLikeHost(host) {
            let scheme = isLocal(host) ? "http" : "https"
            return URL(string: "\(scheme)://\(text)")
        }
        return search(text)
    }

    /// The field's text for a page: the address, except for the blank page,
    /// which is shown as nothing so the placeholder can say what to type.
    static func display(_ url: String) -> String {
        url == "about:blank" ? "" : url
    }

    private static let knownSchemes: Set<String> = [
        "http", "https", "file", "about", "data", "chrome", "view-source",
    ]

    /// The scheme when the text names one — `https:` — and not when the colon
    /// is a port's: `localhost:3000` has none.
    private static func explicitScheme(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon]
        guard let first = scheme.first, first.isLetter,
              scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) })
        else { return nil }
        let rest = text[text.index(after: colon)...]
        if rest.first?.isNumber == true, !rest.hasPrefix("//") { return nil }
        return String(scheme)
    }

    private static func host(of text: String) -> String? {
        let authority = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? text
        if authority.hasPrefix("[") {
            return authority.firstIndex(of: "]").map { String(authority[...$0]) }
        }
        let host = authority.split(separator: ":", maxSplits: 1).first.map(String.init) ?? authority
        return host.isEmpty ? nil : host.lowercased()
    }

    private static func looksLikeHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasPrefix("[") { return true }
        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return false }
        return host.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }
    }

    private static func isLocal(_ host: String) -> Bool {
        if ["localhost", "[::1]", "0.0.0.0"].contains(host) || host.hasSuffix(".localhost")
            || host.hasSuffix(".local") || host.hasSuffix(".test") || host.hasSuffix(".internal") {
            return true
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0 ... 255).contains($0) }) else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168): return true
        case (172, 16 ... 31): return true
        default: return false
        }
    }

    private static func search(_ text: String) -> URL? {
        var components = URLComponents(string: "https://www.google.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: text)]
        return components?.url
    }
}
