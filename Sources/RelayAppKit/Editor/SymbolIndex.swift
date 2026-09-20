import CodeEditLanguages
import Foundation
import Observation
import SwiftTreeSitter

/// Every name a project declares, and which file declares it.
///
/// Built by reading the project once rather than by asking a language server:
/// the grammars are already here, they answer for sixteen languages at once,
/// and nothing has to be installed on the machine for a jump to work. What it
/// costs is that the answer is a name rather than a type — two classes with a
/// `handle` method give two candidates, and which one the caret meant is a
/// question only a type checker can settle. The list is offered instead.
@MainActor
@Observable
final class SymbolIndex {
    /// Definitions by name and by file, per project root. Both, because the
    /// jump reads names and re-reading one file has to replace what that file
    /// used to declare.
    private struct Contents {
        var byName: [String: [SymbolDefinition]] = [:]
        var byPath: [String: [SymbolDefinition]] = [:]
        /// Files by their name without the extension, for the names that are
        /// declared by a file existing rather than by anything written in one.
        var byBasename: [String: [String]] = [:]

        init(_ findings: SymbolScan.Findings) {
            byPath = findings.byPath
            for definitions in byPath.values {
                for definition in definitions {
                    byName[definition.name, default: []].append(definition)
                }
            }
            for path in findings.paths {
                let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                // `Page.blade.php` is `Page`, the way it is referred to.
                let stem = (name as NSString).deletingPathExtension
                byBasename[stem.isEmpty ? name : stem, default: []].append(path)
            }
        }
    }

    /// Whose code is being asked about.
    ///
    /// Two indexes rather than one, and the project's is the only one built
    /// without being asked: reading the dependencies costs seconds and
    /// answers a question most jumps never get to.
    enum Scope: String, Sendable {
        case project
        case dependencies
    }

    private var roots: [String: Contents] = [:]
    private var scans: [String: Task<SymbolScan.Findings, Never>] = [:]

    private func key(_ root: String, _ scope: Scope) -> String { "\(scope.rawValue):\(root)" }

    /// Whether this has been read yet. Nothing on screen waits for it — the
    /// first jump does — but a pane that wants to say so can.
    func isReady(_ root: String, scope: Scope = .project) -> Bool { roots[key(root, scope)] != nil }

    func isScanning(_ root: String, scope: Scope = .project) -> Bool { scans[key(root, scope)] != nil }

    /// Reads what has not been read, and waits for a reading already under
    /// way rather than starting a second one.
    func prepare(root: String, scope: Scope = .project) async {
        let key = key(root, scope)
        guard roots[key] == nil else { return }

        let scan: Task<SymbolScan.Findings, Never>
        if let running = scans[key] {
            scan = running
        } else {
            // Other people's code is read at a lower priority than the
            // project's: it is started before anybody has asked for it, and
            // it must not be what the machine is busy with while they type.
            scan = Task.detached(priority: scope == .project ? .userInitiated : .utility) {
                switch scope {
                case .project: await SymbolScan.definitions(under: root)
                case .dependencies:
                    await SymbolScan.findings(
                        in: DependencyScan.declarations(under: root),
                        naming: DependencyScan.classFiles(under: root)
                    )
                }
            }
            scans[key] = scan
        }

        let found = await scan.value
        roots[key] = Contents(found)
        scans[key] = nil
    }

    func definitions(named name: String, in root: String, scope: Scope = .project) -> [SymbolDefinition] {
        roots[key(root, scope)]?.byName[name] ?? []
    }

    /// Files whose name is this name.
    ///
    /// The answer to a component: `<UserCard />` resolves to `UserCard.vue`,
    /// and so does the `UserCard` in the import above it. Nothing inside such
    /// a file declares the name it is used by, so no tags query will ever find
    /// it.
    func files(named name: String, in root: String, scope: Scope = .project) -> [SymbolDefinition] {
        (roots[key(root, scope)]?.byBasename[name] ?? []).map {
            SymbolDefinition(name: name, kind: .file, path: $0, range: NSRange(location: 0, length: 0), line: 1)
        }
    }

    /// How many files declared something, for saying what was read.
    func fileCount(in root: String, scope: Scope = .project) -> Int {
        roots[key(root, scope)]?.byPath.count ?? 0
    }

    /// Replaces what one file declares.
    ///
    /// For the file in front of the person: it is re-read when it is saved, so
    /// a function written a minute ago can be jumped to without the project
    /// being walked again.
    func replace(_ definitions: [SymbolDefinition], for path: String, in root: String) {
        let key = key(root, .project)
        guard var contents = roots[key] else { return }
        for existing in contents.byPath[path] ?? [] {
            contents.byName[existing.name]?.removeAll { $0 == existing }
            if contents.byName[existing.name]?.isEmpty == true {
                contents.byName[existing.name] = nil
            }
        }
        contents.byPath[path] = definitions.isEmpty ? nil : definitions
        for definition in definitions {
            contents.byName[definition.name, default: []].append(definition)
        }
        roots[key] = contents
    }

    /// Forgets a project, so the next jump reads it again. What the refresh
    /// button in the file tree means for names as well as for files.
    func invalidate(root: String) {
        for scope in [Scope.project, .dependencies] {
            let key = key(root, scope)
            scans[key]?.cancel()
            scans[key] = nil
            roots[key] = nil
        }
    }
}

/// Walking a project for every name it declares.
///
/// Off the main actor, and so deliberately free of anything that is not: it is
/// handed a path and builds everything it needs — the parsers, the queries —
/// inside itself.
enum SymbolScan {
    /// Directories that are somebody else's source.
    ///
    /// A checkout's own code is what a jump is for; a jump into
    /// `node_modules` lands in a minified bundle nobody wanted to read, and
    /// reading them is most of what a scan would spend its time on.
    static let skipped: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", "bower_components", "vendor", "Pods", "Carthage",
        ".build", "build", "DerivedData", "dist", "out", "target", ".next", ".nuxt", ".venv", "venv",
        "__pycache__", ".gradle", ".terraform", "coverage", ".mypy_cache", ".pytest_cache",
    ]

    /// Enough files for any repository a person works in, and a stop for the
    /// one that turns out to be a data set.
    static let fileLimit = 20_000
    /// Bigger than this is generated: a bundle, a lockfile-as-source, a dump.
    /// Parsing one costs seconds and declares nothing anybody jumps to.
    static let sizeLimit = 512 * 1_024

    /// What one reading of a project came back with.
    struct Findings: Sendable {
        let byPath: [String: [SymbolDefinition]]
        /// Every file that was read, declarations or not: a component file is
        /// itself the declaration of the name it is used by.
        let paths: [String]
    }

    /// Every definition in the project.
    static func definitions(under root: String) async -> Findings {
        await findings(in: files(under: root))
    }

    /// What this set of files declares.
    ///
    /// The walk that found them is one pass and cheap; the parsing is the
    /// whole cost and the files are independent of each other, so they are
    /// read across the cores the machine has. A grammar is not shared between
    /// them — a parser is a mutable object — which is why the files are split
    /// into a handful of groups rather than a task each.
    ///
    /// - Parameter naming: files to know the name of without reading them.
    static func findings(in paths: [String], naming named: [String] = []) async -> Findings {
        guard !paths.isEmpty else { return Findings(byPath: [:], paths: named) }

        let groups = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))
        let size = (paths.count + groups - 1) / groups

        let byPath = await withTaskGroup(of: [String: [SymbolDefinition]].self) { group in
            for start in stride(from: 0, to: paths.count, by: size) {
                let chunk = Array(paths[start ..< min(start + size, paths.count)])
                group.addTask { definitions(in: chunk) }
            }
            var found: [String: [SymbolDefinition]] = [:]
            for await part in group {
                found.merge(part) { first, _ in first }
            }
            return found
        }
        return Findings(byPath: byPath, paths: paths + named)
    }

    /// The files worth parsing, named the way the project names them.
    ///
    /// Walked by path rather than by URL, and built back up from the root the
    /// project gave: `enumerator(at:)` resolves the symbolic links on the way
    /// in — a project under `/var/…` comes back as `/private/var/…` — and a
    /// definition spelled differently from the open buffer is a jump that
    /// opens the same file a second time.
    static func files(under root: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: root) else { return [] }
        let languages = taggedLanguages()
        var paths: [String] = []

        while let relative = walker.nextObject() as? String {
            guard !Task.isCancelled, paths.count < fileLimit else { break }
            let name = (relative as NSString).lastPathComponent
            let attributes = walker.fileAttributes

            if attributes?[.type] as? FileAttributeType == .typeDirectory {
                // Anything beginning with a dot as well as the named ones: an
                // `.idea` or a `.cache` is no more a project's own source than
                // a `node_modules` is.
                if name.hasPrefix(".") || skipped.contains(name) { walker.skipDescendants() }
                continue
            }
            guard attributes?[.type] as? FileAttributeType == .typeRegular,
                  languages[(name as NSString).pathExtension.lowercased()] != nil,
                  (attributes?[.size] as? Int ?? 0) <= sizeLimit
            else { continue }

            paths.append((root as NSString).appendingPathComponent(relative))
        }
        return paths
    }

    /// What one group of files declares.
    static func definitions(in paths: [String]) -> [String: [SymbolDefinition]] {
        let languages = taggedLanguages()
        var found: [String: [SymbolDefinition]] = [:]

        for path in paths {
            guard !Task.isCancelled else { break }
            guard let language = languages[(path as NSString).pathExtension.lowercased()],
                  let text = try? String(contentsOfFile: path, encoding: .utf8)
            else { continue }

            let definitions = SymbolTags.definitions(
                in: text,
                language: SourceLanguage(code: language),
                path: path
            )
            guard !definitions.isEmpty else { continue }
            found[path] = definitions
        }
        return found
    }

    /// Which extensions are worth opening. Checked before the file is read,
    /// so a repository of images and JSON costs a directory listing and
    /// nothing more.
    static func taggedLanguages() -> [String: CodeLanguage] {
        var map: [String: CodeLanguage] = [:]
        for language in CodeLanguage.allLanguages where SymbolTags.tagsURL(for: language) != nil {
            for suffix in language.extensions where map[suffix.lowercased()] == nil {
                map[suffix.lowercased()] = language
            }
        }
        // And the pages, which declare nothing themselves and hold a script
        // that declares everything. A single-file component — `.vue`,
        // `.svelte` — is one of those with a different extension.
        for suffix in CodeLanguage.html.extensions where map[suffix.lowercased()] == nil {
            map[suffix.lowercased()] = .html
        }
        for suffix in SourceLanguage.templateExtensions where map[suffix] == nil {
            map[suffix] = .html
        }
        return map
    }
}
