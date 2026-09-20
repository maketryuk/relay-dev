import Foundation

/// Somebody else's code, and the small part of it worth reading.
///
/// A project's dependencies are where half of what a person ⌘-clicks is
/// declared — a framework's macro, a library's function — and they are also
/// the reason a naive scan is hopeless: one front-end checkout here has 86,640
/// files under `node_modules`, of which 19,777 are declaration files. Reading
/// all of them costs half a minute for an answer nobody waited that long for.
///
/// So a JavaScript package is read as one file — the declarations its own
/// manifest points at, which is its whole public surface bundled together by
/// every modern build. A Composer package has no such thing and is 96 MB of
/// source in a Laravel checkout, forty seconds of parsing for an answer that
/// is usually the file name: PHP puts one class in one file and names the
/// file after the class, so those are indexed by name and not read at all.
/// Clicking `Model` opens `Model.php`; clicking a method of it does not, and
/// that is the part this trades away.
enum DependencyScan {
    /// The directory names a project keeps other people's code in.
    static let roots = ["node_modules", "vendor"]

    /// The same stop the project's own scan has.
    static let fileLimit = 20_000
    /// Bigger than this is generated — an autoload class map, an SDK's
    /// endpoint table written out as a PHP array — and declares nothing
    /// anybody jumps to.
    static let sizeLimit = 512 * 1_024

    /// Whether a path belongs to a dependency rather than to the project.
    ///
    /// What makes such a file read-only when it is opened: an edit to it is
    /// undone by the next install, silently, and a person who did not notice
    /// where they were typing has no way to find that out afterwards.
    static func isDependency(_ path: String) -> Bool {
        (path as NSString).pathComponents.contains { roots.contains($0) }
    }

    /// The files worth reading: one bundled declaration per JavaScript
    /// package.
    static func declarations(under root: String) -> [String] {
        guard let modules = directory("node_modules", under: root) else { return [] }
        return Array(packageEntries(in: modules).prefix(fileLimit))
    }

    /// The files worth knowing the name of, which for a class-per-file
    /// language is most of what anybody looks for.
    static func classFiles(under root: String) -> [String] {
        guard let vendor = directory("vendor", under: root) else { return [] }
        return Array(sources(in: vendor).prefix(fileLimit))
    }

    private static func directory(_ name: String, under root: String) -> String? {
        let path = (root as NSString).appendingPathComponent(name)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
        else { return nil }
        return path
    }

    // MARK: - Packages

    /// The declarations each installed package points at.
    private static func packageEntries(in modules: String) -> [String] {
        packageRoots(in: modules).compactMap(typesEntry(of:))
    }

    /// Every installed package directory.
    ///
    /// Two layouts to know about. npm and yarn put the package itself at
    /// `node_modules/<name>`; pnpm puts a link there and the package under
    /// `node_modules/.pnpm/<name>@<version>/node_modules/<name>`, which a walk
    /// misses twice over — once for the leading dot and once for the link.
    private static func packageRoots(in modules: String) -> [String] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: modules) else { return [] }

        var roots: [String] = []
        for name in names {
            let path = (modules as NSString).appendingPathComponent(name)
            if name == ".pnpm" {
                for version in (try? manager.contentsOfDirectory(atPath: path)) ?? [] {
                    let inner = (path as NSString)
                        .appendingPathComponent(version)
                        .appending("/node_modules")
                    roots += packageRoots(in: inner)
                }
                continue
            }
            guard !name.hasPrefix(".") else { continue }
            // A scope is a directory of packages rather than a package.
            guard name.hasPrefix("@") else {
                roots.append(path)
                continue
            }
            for scoped in (try? manager.contentsOfDirectory(atPath: path)) ?? [] where !scoped.hasPrefix(".") {
                roots.append((path as NSString).appendingPathComponent(scoped))
            }
        }
        return roots
    }

    /// The declaration file a package's manifest points at, if it has one.
    private static func typesEntry(of package: String) -> String? {
        let manifest = (package as NSString).appendingPathComponent("package.json")
        guard let data = FileManager.default.contents(atPath: manifest),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let named = (json["types"] as? String) ?? (json["typings"] as? String)
        for candidate in [named, "index.d.ts"].compactMap({ $0 }) {
            let path = (package as NSString).appendingPathComponent(candidate)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
            guard isDirectory.boolValue else { return path }
            // `"types": "./dist"` is allowed, and means the index inside it.
            let inside = (path as NSString).appendingPathComponent("index.d.ts")
            if FileManager.default.fileExists(atPath: inside) { return inside }
        }
        return nil
    }

    // MARK: - Sources

    /// What a Composer dependency is read by: its own files.
    ///
    /// There is no bundled surface to read instead, and a class per file is
    /// the whole convention. What is left out is what nobody navigates to.
    private static let skipped: Set<String> = [
        "tests", "Tests", "test", "docs", "doc", "examples", "example", "bin", "node_modules", ".git",
    ]

    private static func sources(in directory: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: directory) else { return [] }
        var found: [String] = []

        while let relative = walker.nextObject() as? String {
            guard !Task.isCancelled, found.count < fileLimit else { break }
            let name = (relative as NSString).lastPathComponent
            let attributes = walker.fileAttributes

            if attributes?[.type] as? FileAttributeType == .typeDirectory {
                if name.hasPrefix(".") || skipped.contains(name) { walker.skipDescendants() }
                continue
            }
            guard attributes?[.type] as? FileAttributeType == .typeRegular,
                  (name as NSString).pathExtension.lowercased() == "php",
                  (attributes?[.size] as? Int ?? 0) <= sizeLimit
            else { continue }
            found.append((directory as NSString).appendingPathComponent(relative))
        }
        return found
    }
}
