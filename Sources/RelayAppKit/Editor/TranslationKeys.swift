import Foundation

/// Where a translation key is defined.
///
/// `t('common.seo.subtitle')` is a definition like any other to the
/// person writing it, and nothing like one to an index of names: what is
/// written is a string, and what defines it is a key inside a JSON file three
/// directories away. Every editor with an i18n plugin does this; without it a
/// ⌘-click on the string says the name is nowhere, which is untrue in the one
/// way that matters.
enum TranslationKeys {
    /// The directories a project keeps its translations in.
    static let folders = ["locale", "locales", "lang", "langs", "i18n", "translation", "translations", "messages"]

    /// Files worth looking in: a JSON or YAML file somewhere under one of
    /// those names. Any JSON file in the project would mean reading
    /// `package.json` and every fixture to answer a ⌘-click.
    static func candidates(among files: [String]) -> [String] {
        files.filter { path in
            let suffix = (path as NSString).pathExtension.lowercased()
            guard suffix == "json" || suffix == "yaml" || suffix == "yml" else { return false }
            let components = (path as NSString).pathComponents.map { $0.lowercased() }
            return components.contains { folders.contains($0) }
        }
    }

    /// Everywhere this key is defined.
    ///
    /// A key is usually written in full — `common.seo.subtitle` —
    /// while the file it lives in is named after its first segment, so the
    /// same path is tried both with and without that segment.
    static func find(_ key: String, in files: [String]) -> [SymbolDefinition] {
        let segments = key.split(separator: ".").map(String.init)
        guard segments.count > 1 else { return [] }

        var found: [SymbolDefinition] = []
        for path in candidates(among: files) {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension

            var wanted = segments
            if !defines(segments, in: text, path: path) {
                guard name == segments[0], defines(Array(segments.dropFirst()), in: text, path: path)
                else { continue }
                wanted = Array(segments.dropFirst())
            }
            guard let place = locate(wanted, in: text) else { continue }

            found.append(SymbolDefinition(
                name: wanted.last ?? key,
                kind: .constant,
                path: path,
                range: place.range,
                line: place.line
            ))
        }
        return found
    }

    /// Whether the file really has that path in it.
    ///
    /// Parsed rather than searched, because a file that merely contains the
    /// words is not a file that defines the key: `seo` and `subtitle`
    /// turn up in half the locale files a project has.
    private static func defines(_ segments: [String], in text: String, path: String) -> Bool {
        let suffix = (path as NSString).pathExtension.lowercased()
        guard suffix == "json" else {
            // YAML is not parsed here. Its keys are its lines, so the
            // sequence being found in order is the whole of the evidence
            // available.
            return locate(segments, in: text) != nil
        }
        guard let data = text.data(using: .utf8),
              var node = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }

        for segment in segments.dropLast() {
            guard let next = node[segment] as? [String: Any] else { return false }
            node = next
        }
        return segments.last.map { node[$0] != nil } ?? false
    }

    /// The line the last segment is written on.
    ///
    /// Each segment is looked for after the one above it, which is what makes
    /// this right for a file that uses the same word at two depths: locale
    /// files are written out one key per line, and the nesting is the order.
    private static func locate(_ segments: [String], in text: String) -> (line: Int, range: NSRange)? {
        let source = text as NSString
        var searched = 0
        var place: NSRange?

        for segment in segments {
            let rest = NSRange(location: searched, length: source.length - searched)
            let found = source.range(of: "\"\(segment)\"", range: rest)
            let plain = found.location == NSNotFound
                ? source.range(of: "\(segment):", range: rest)
                : found
            guard plain.location != NSNotFound else { return nil }
            place = NSRange(location: plain.location, length: segment.count + (found.location == NSNotFound ? 0 : 2))
            searched = NSMaxRange(plain)
        }

        guard let place else { return nil }
        return (line(of: place.location, in: source), place)
    }

    private static func line(of offset: Int, in source: NSString) -> Int {
        var start = 0
        var number = 1
        while start < offset, start < source.length {
            let range = source.lineRange(for: NSRange(location: start, length: 0))
            let next = NSMaxRange(range)
            guard next > start, next <= offset else { break }
            start = next
            number += 1
        }
        return number
    }
}
