import Foundation
import Observation
import RelayUI

/// Every file in a project, by path.
///
/// The symbol index walks the project too, but only opens what a grammar can
/// read; finding a file by name and searching what is in one have to know
/// about the `.md`, the `.json` and the `Dockerfile` as well. One walk, kept,
/// and both are answered from it.
enum ProjectFiles {
    /// Enough for a repository nobody would try to search by hand anyway.
    static let limit = 50_000

    /// What is never worth listing or reading: it is not text, and a search
    /// through a megabyte of PNG finds nothing but costs the same as a file
    /// that would have.
    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "bmp", "tiff", "ico", "icns", "webp", "avif", "heic",
        "pdf", "zip", "gz", "tar", "bz2", "xz", "7z", "dmg", "pkg",
        "mp3", "mp4", "mov", "avi", "wav", "aiff", "m4a", "webm",
        "woff", "woff2", "ttf", "otf", "eot",
        "so", "dylib", "a", "o", "bin", "exe", "wasm", "class", "jar", "pyc",
        "sqlite", "db", "psd", "sketch", "xcuserstate",
    ]

    static func walk(root: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        var found: [String] = []

        while let relative = walker.nextObject() as? String {
            guard !Task.isCancelled, found.count < limit else { break }
            let name = (relative as NSString).lastPathComponent
            let attributes = walker.fileAttributes

            if attributes?[.type] as? FileAttributeType == .typeDirectory {
                // The same list the symbol index skips, for the same reason:
                // `node_modules` is not what anybody means by "in the project".
                if name.hasPrefix(".") || SymbolScan.skipped.contains(name) { walker.skipDescendants() }
                continue
            }
            guard attributes?[.type] as? FileAttributeType == .typeRegular,
                  !binaryExtensions.contains((name as NSString).pathExtension.lowercased())
            else { continue }

            found.append((root as NSString).appendingPathComponent(relative))
        }
        return found
    }
}

/// Finding a file by its name.
///
/// The name is what is searched. The folder is searched too, but only for what
/// is written out in full: a query is allowed to skip letters inside a name —
/// `gtpnl` finds `GitPanel.swift` — and allowing the same across a path finds
/// almost everything, because a path is long. Typing `useplatform` in a web
/// project came back with `types.ts`, whose path happened to contain those
/// eleven letters in that order among two hundred others, and the file that
/// was actually meant was somewhere below it.
enum FileMatching {
    /// The files a query answers to, best first.
    static func matches(
        _ text: String,
        in paths: [String],
        under root: String,
        limit: Int
    ) -> [(score: Int, path: String)] {
        let query = RelaySearchQuery(text)
        guard !query.isEmpty else { return [] }
        let written = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        var scored: [(score: Int, path: String)] = []
        for path in paths {
            let name = (path as NSString).lastPathComponent
            let relative = self.relative(path, to: root)
            guard let score = score(name: name, relative: relative, query: query, written: written)
            else { continue }
            scored.append((score, path))
        }
        scored.sort { $0.score == $1.score ? $0.path < $1.path : $0.score > $1.score }
        return Array(scored.prefix(limit))
    }

    private static func score(
        name: String,
        relative: String,
        query: RelaySearchQuery,
        written: String
    ) -> Int? {
        // The name, where skipping letters is allowed and where a keyboard
        // layout or a transliteration is still worth trying.
        var best = query.score([name])

        // The folder, where it is not. `views/git` finds
        // `Views/GitPanel.swift`; `composables` finds everything in that
        // folder; and eleven letters scattered across a path find nothing.
        if !written.isEmpty, let found = relative.lowercased().range(of: written) {
            let distance = relative.distance(from: relative.startIndex, to: found.lowerBound)
            let score = pathScore - min(distance, 120)
            if best == nil || score > best! { best = score }
        }
        return best
    }

    /// Below a name matched whole and above one matched by its initials: a
    /// folder somebody has written out is a strong hint and a weaker answer
    /// than the file's own name.
    private static let pathScore = 500

    /// The path as it reads inside the project, which is how a person names a
    /// file to themselves.
    static func relative(_ path: String, to root: String) -> String {
        guard path.hasPrefix(root) else { return path }
        return String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

/// The walk, kept for as long as it is true.
@MainActor
@Observable
final class FileIndex {
    private var roots: [String: [String]] = [:]
    private var scans: [String: Task<[String], Never>] = [:]

    func files(in root: String) -> [String] { roots[root] ?? [] }

    func isReady(_ root: String) -> Bool { roots[root] != nil }

    /// Walks the project if it has not been walked, and waits for a walk
    /// already under way rather than starting a second one.
    func prepare(root: String) async {
        guard roots[root] == nil else { return }

        let scan: Task<[String], Never>
        if let running = scans[root] {
            scan = running
        } else {
            scan = Task.detached(priority: .userInitiated) { ProjectFiles.walk(root: root) }
            scans[root] = scan
        }

        let found = await scan.value
        roots[root] = found
        scans[root] = nil
    }

    func invalidate(root: String) {
        scans[root]?.cancel()
        scans[root] = nil
        roots[root] = nil
    }
}
