import Foundation

/// Reading a directory for the file tree.
///
/// Pure and one level deep on purpose: the tree reads a folder when it is
/// opened rather than walking the project at launch. A repository with a
/// `node_modules` in it is hundreds of thousands of files, and the ones a
/// person wants are almost always three clicks from the root.
enum FileTree {
    struct Entry: Identifiable, Hashable, Sendable {
        let path: String
        let name: String
        let isDirectory: Bool

        var id: String { path }
    }

    /// What a directory contains, in the order it should be shown.
    ///
    /// Folders first and then by name, which is the arrangement every file
    /// browser uses and the only one where a folder can be found without
    /// reading every row.
    ///
    /// Throws rather than returning nothing when the directory cannot be read.
    /// An empty folder and a folder macOS will not let this application look
    /// into are the same picture, and the second one needs saying.
    static func entries(in directory: String) throws -> [Entry] {
        let manager = FileManager.default
        let names = try manager.contentsOfDirectory(atPath: directory)

        let entries = names.compactMap { name -> Entry? in
            guard !isHidden(name) else { return nil }
            let path = (directory as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
            return Entry(path: path, name: name, isDirectory: isDirectory.boolValue)
        }

        return entries.sorted { first, second in
            if first.isDirectory != second.isDirectory { return first.isDirectory }
            return first.name.localizedStandardCompare(second.name) == .orderedAscending
        }
    }

    /// The folders between a project and a file, outermost first.
    ///
    /// Which are exactly the ones that have to be open for the file to be
    /// visible: a tree that reads folders when they are opened cannot point
    /// at a file four levels down without opening the four.
    static func ancestors(of path: String, under root: String) -> [String] {
        let root = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard path.hasPrefix(root + "/") else { return [] }

        var ancestors: [String] = []
        var directory = (path as NSString).deletingLastPathComponent
        while directory.count > root.count, directory.hasPrefix(root) {
            ancestors.append(directory)
            directory = (directory as NSString).deletingLastPathComponent
        }
        return ancestors.reversed()
    }

    /// What never appears.
    ///
    /// Short by design. `.env`, `.gitignore` and the rest of the dotfiles are
    /// exactly the files somebody opens a tree to find, so hiding everything
    /// beginning with a dot — which is what a file browser does — would hide
    /// the useful half. Only the two that are never opened by hand are left
    /// out: git's own database, and the folder Finder leaves behind.
    static func isHidden(_ name: String) -> Bool {
        name == ".git" || name == ".DS_Store"
    }
}
