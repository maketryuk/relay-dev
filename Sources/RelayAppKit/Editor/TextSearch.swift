import Foundation

/// A line of a file that a search matched.
struct TextHit: Identifiable, Hashable, Sendable {
    let path: String
    /// 1-based, as every editor counts lines.
    let line: Int
    /// The line itself, for reading the answer without opening the file.
    let text: String
    /// Where the match is in the file, for putting the caret on it.
    let range: NSRange
    /// Where it is within `text`, for marking it in the row.
    let inLine: NSRange

    var id: String { "\(path):\(range.location)" }
}

/// Searching what is in a project's files.
///
/// Ours rather than `rg`'s: a tool that may not be installed is a feature that
/// works on the machine it was written on. The files are already walked for
/// the palette, reading them is what a search is, and the work is spread over
/// the cores the same way the symbol index spreads its parsing.
enum TextSearch {
    /// How the query is read.
    ///
    /// The three switches every find has, in the order every find puts them:
    /// case, whole words, and the one that makes the query a pattern.
    struct Options: Equatable, Sendable {
        var isCaseSensitive = false
        var matchesWholeWords = false
        var isRegularExpression = false
    }

    /// What a query turns into, once the switches have been read.
    ///
    /// The plain case stays a string comparison rather than becoming a
    /// pattern of its own: a literal search of a project is most of what is
    /// ever run here, and `NSString` finds a substring several times faster
    /// than a regular expression matches one.
    enum Matcher {
        case literal(String, NSString.CompareOptions)
        case expression(NSRegularExpression)

        static func make(_ query: String, options: Options) -> Matcher? {
            guard !query.isEmpty else { return nil }

            var expression = options.isRegularExpression ? query : NSRegularExpression.escapedPattern(for: query)
            if options.matchesWholeWords { expression = "\\b" + expression + "\\b" }

            guard options.isRegularExpression || options.matchesWholeWords else {
                return .literal(query, options.isCaseSensitive ? [] : [.caseInsensitive])
            }
            guard let compiled = try? NSRegularExpression(
                pattern: expression,
                options: options.isCaseSensitive ? [] : [.caseInsensitive]
            ) else { return nil }
            return .expression(compiled)
        }

        func firstMatch(in source: NSString, from start: Int) -> NSRange? {
            let rest = NSRange(location: start, length: source.length - start)
            switch self {
            case let .literal(query, options):
                let found = source.range(of: query, options: options, range: rest)
                return found.location == NSNotFound ? nil : found
            case let .expression(compiled):
                return compiled.firstMatch(in: source as String, options: [], range: rest)?.range
            }
        }
    }

    /// Enough to find what was meant, and a stop before a two-letter query
    /// fills a window with a hundred thousand lines.
    static let limit = 300
    /// Per file, so one generated file cannot be the whole answer.
    static let perFile = 20
    /// A file bigger than this is a log or a dump, and searching it finds
    /// every line of it.
    static let sizeLimit = 2 * 1_024 * 1_024

    static func find(_ query: String, in paths: [String], options: Options = Options()) async -> [TextHit] {
        guard !paths.isEmpty, Matcher.make(query, options: options) != nil else { return [] }

        let groups = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
        let size = (paths.count + groups - 1) / groups

        let found = await withTaskGroup(of: [TextHit].self) { group in
            for start in stride(from: 0, to: paths.count, by: size) {
                let chunk = Array(paths[start ..< min(start + size, paths.count)])
                group.addTask { hits(of: query, in: chunk, options: options) }
            }
            var all: [TextHit] = []
            for await part in group { all += part }
            return all
        }

        return Array(
            found
                .sorted { $0.path == $1.path ? $0.line < $1.line : $0.path < $1.path }
                .prefix(limit)
        )
    }

    /// Every match in one text, for a find inside the file being read.
    ///
    /// Ranges rather than lines: what a find bar walks through is matches,
    /// two of which can be on the same line.
    static func ranges(
        of query: String,
        in text: String,
        options: Options = Options(),
        limit: Int = 2_000
    ) -> [NSRange] {
        let source = text as NSString
        guard source.length > 0, let matcher = Matcher.make(query, options: options) else { return [] }

        var found: [NSRange] = []
        var start = 0
        while start < source.length, found.count < limit {
            guard let match = matcher.firstMatch(in: source, from: start) else { break }
            found.append(match)
            start = match.location + max(1, match.length)
        }
        return found
    }

    static func hits(of query: String, in paths: [String], options: Options = Options()) -> [TextHit] {
        var found: [TextHit] = []
        for path in paths {
            guard !Task.isCancelled, found.count < limit else { break }
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  (attributes[.size] as? Int ?? 0) <= sizeLimit,
                  let text = try? String(contentsOfFile: path, encoding: .utf8)
            else { continue }
            found += hits(of: query, in: text, path: path, options: options)
        }
        return found
    }

    /// Every line of this text that contains the query, case ignored.
    ///
    /// Case-insensitively because that is what a person means by searching for
    /// a word, and because the alternative is a switch nobody would find.
    static func hits(
        of query: String,
        in text: String,
        path: String,
        options: Options = Options(),
        limit: Int = perFile
    ) -> [TextHit] {
        let source = text as NSString
        guard source.length > 0, let matcher = Matcher.make(query, options: options) else { return [] }

        var found: [TextHit] = []
        var start = 0
        var number = 1

        while start < source.length, found.count < limit {
            let lineRange = source.lineRange(for: NSRange(location: start, length: 0))
            let line = source.substring(with: lineRange).trimmingCharacters(in: .newlines)
            let inLine = matcher.firstMatch(in: line as NSString, from: 0) ?? NSRange(location: NSNotFound, length: 0)

            if inLine.location != NSNotFound {
                let (shown, marked) = trimmed(line, around: inLine)
                found.append(TextHit(
                    path: path,
                    line: number,
                    text: shown,
                    range: NSRange(location: lineRange.location + inLine.location, length: inLine.length),
                    inLine: marked
                ))
            }

            number += 1
            let next = NSMaxRange(lineRange)
            guard next > start else { break }
            start = next
        }
        return found
    }

    /// A window of a long line around the match.
    ///
    /// A minified bundle is one line of a hundred thousand characters, and a
    /// row of a result list is one line of about a hundred.
    private static func trimmed(_ line: String, around match: NSRange) -> (String, NSRange) {
        let source = line as NSString
        let width = 160
        guard source.length > width else { return (line, match) }

        let start = max(0, match.location - 40)
        let length = min(width, source.length - start)
        let window = source.substring(with: NSRange(location: start, length: length))
        let shifted = NSRange(
            location: max(0, match.location - start),
            length: min(match.length, max(0, length - (match.location - start)))
        )
        return (start > 0 ? "…" + window : window, start > 0 ? NSRange(location: shifted.location + 1, length: shifted.length) : shifted)
    }
}
