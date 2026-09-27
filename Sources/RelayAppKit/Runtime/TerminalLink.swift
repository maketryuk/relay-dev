import Foundation

/// What a link ⌘-clicked in a terminal is a link to.
///
/// SwiftTerm finds the text under the pointer — an OSC 8 target, an address
/// typed out, or a path it recognised, one an agent wrapped onto the next line
/// itself included — and hands over nothing but that text. What the text names
/// is decided here, against the disk: a path printed by `rg` or by an agent is
/// only a file once it is known which directory it was printed from, and
/// whether what follows it is part of the name or the line to go to.
///
/// Away from the surface for the reason `TerminalFileDrop` is: the view cannot
/// be made without a window, and the reading is a decision worth testing.
enum TerminalLink: Equatable {
    /// A file, with the line and column written after it, 1-based as every
    /// compiler and every `grep` counts them.
    case file(path: String, line: Int?, column: Int?)
    case folder(String)
    /// Somewhere a browser, a mail client or another application is for.
    case external(URL)

    /// What `text` names on this Mac, with a relative path read from each of
    /// `directories` in turn. Nil when it names nothing that is there.
    static func destination(
        of text: String,
        from directories: [String],
        fileManager: FileManager = .default
    ) -> TerminalLink? {
        // The disk is asked before the URL parser, which reads `README.md:3`
        // as an address whose scheme is `readme.md`.
        if let local = local(text, from: directories, fileManager: fileManager) {
            return local
        }
        guard let url = URL(string: text), url.scheme?.isEmpty == false else { return nil }
        guard url.isFileURL else { return .external(url) }
        return local(url.path, from: [], fileManager: fileManager)
    }

    /// What `text` names when the paths in it are on another machine: an
    /// address, and never a file, because the file of the same name here is
    /// somebody else's.
    static func address(of text: String) -> URL? {
        guard let url = URL(string: text), url.scheme?.isEmpty == false, !url.isFileURL else { return nil }
        return url
    }

    private static func local(_ text: String, from directories: [String], fileManager: FileManager) -> TerminalLink? {
        for spelling in spellings(of: text) {
            let expanded = (spelling.path as NSString).expandingTildeInPath
            let candidates = expanded.hasPrefix("/")
                ? [expanded]
                : directories.map { ($0 as NSString).appendingPathComponent(expanded) }
            for candidate in candidates {
                // `URL.standardized` rather than `NSString.standardizingPath`,
                // which also takes `/private` off `/private/tmp` and hands the
                // pane a different spelling of the file than the one clicked.
                let path = URL(fileURLWithPath: candidate).standardized.path
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
                return isDirectory.boolValue
                    ? .folder(path)
                    : .file(path: path, line: spelling.line, column: spelling.column)
            }
        }
        return nil
    }

    /// What the text could be a path written as, the most literal first:
    /// itself, then without a line and column after it, then all of that again
    /// without the full stop of the sentence it ended.
    ///
    /// Each is only a guess until the disk answers, which is what makes it
    /// safe to strip: a file whose name really does end in `:12` is found
    /// before the `:12` is read as a line.
    private static func spellings(of text: String) -> [(path: String, line: Int?, column: Int?)] {
        var texts = [text]
        let unpunctuated = text.replacingOccurrences(of: #"[.;!?]+$"#, with: "", options: .regularExpression)
        if !unpunctuated.isEmpty, unpunctuated != text { texts.append(unpunctuated) }

        var result: [(path: String, line: Int?, column: Int?)] = []
        for text in texts {
            result.append((text, nil, nil))
            if let match = text.wholeMatch(of: /(.+?):(\d+)(?::(\d+))?/) {
                result.append((String(match.1), Int(match.2), match.3.flatMap { Int($0) }))
            }
        }
        return result
    }
}
