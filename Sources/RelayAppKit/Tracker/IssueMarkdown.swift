import Foundation

/// YouTrack's Markdown, taken apart into what a line of text can draw and the
/// pictures it cannot.
///
/// A screenshot is how most issues are explained, and YouTrack writes one as
/// `![](Screenshot 2026-09-23 at 13.13.59.png){width=70%}`: the attachment's
/// own name, spaces and all, which no Markdown reader takes for a link — so
/// without this the picture was a line of punctuation where the explanation
/// should have been.
enum IssueMarkdown {
    enum Segment: Equatable {
        case text(String)
        /// An attachment's name, or an address, and the width it was given
        /// in points when it was given one.
        case image(reference: String, width: Double?)
    }

    static func segments(of source: String) -> [Segment] {
        guard let imagePattern else { return [.text(source)] }
        let text = source as NSString
        var segments: [Segment] = []
        var cursor = 0
        for match in imagePattern.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            appendText(text.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), to: &segments)
            let reference = text.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            let attributes = match.range(at: 2).location == NSNotFound ? "" : text.substring(with: match.range(at: 2))
            segments.append(.image(reference: reference, width: width(in: attributes)))
            cursor = match.range.location + match.range.length
        }
        appendText(text.substring(from: cursor), to: &segments)
        return segments
    }

    /// Links written to an attachment by its name, pointed at where it is, so
    /// clicking one opens the file rather than nothing.
    static func linkingAttachments(in text: String, resolve: (String) -> String?) -> String {
        guard let linkPattern else { return text }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in linkPattern.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let target = source.substring(with: match.range(at: 2))
            guard let resolved = resolve(target) else { continue }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += "[\(source.substring(with: match.range(at: 1)))](\(resolved))"
            cursor = match.range.location + match.range.length
        }
        return result + source.substring(from: cursor)
    }

    private static func appendText(_ piece: String, to segments: inout [Segment]) {
        let trimmed = piece.trimmingCharacters(in: .newlines)
        guard !trimmed.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        segments.append(.text(trimmed))
    }

    /// `{width=320}` or `{width=320px}` is a width; `{width=70%}` is a share
    /// of a page Relay's pane is not, and the picture is fitted instead.
    private static func width(in attributes: String) -> Double? {
        let text = attributes as NSString
        guard let match = widthPattern?.firstMatch(in: attributes, range: NSRange(location: 0, length: text.length))
        else { return nil }
        return Double(text.substring(with: match.range(at: 1)))
    }

    // Made when asked for rather than kept: a text is taken apart once per
    // drawing of a pane, and a stored expression would have to be shared
    // across threads on the word of an SDK that has not always said it can be.
    private static var imagePattern: NSRegularExpression? {
        try? NSRegularExpression(pattern: #"!\[[^\]\n]*\]\(([^)\n]+)\)(\{[^}\n]*\})?"#)
    }

    private static var linkPattern: NSRegularExpression? {
        try? NSRegularExpression(pattern: #"(?<!!)\[([^\]\n]*)\]\(([^)\n]+)\)"#)
    }

    private static var widthPattern: NSRegularExpression? {
        try? NSRegularExpression(pattern: #"width\s*=\s*(\d+(?:\.\d+)?)\s*(?:px)?\s*(?:[;}\s]|$)"#)
    }
}
