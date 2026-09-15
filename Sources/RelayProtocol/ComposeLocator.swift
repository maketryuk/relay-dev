import Foundation

/// Finds the Compose file a project's stack is defined in.
///
/// The project root is the obvious answer and frequently the wrong one: keeping
/// the stack in `docker/` is common enough that running Compose from the root is
/// exactly how "no configuration file provided" happens.
///
/// The search stays shallow and conventional rather than walking the tree. A
/// deep scan would find vendored compose files belonging to dependencies, and
/// starting one of those is worse than finding nothing.
public enum ComposeLocator {
    /// In Compose's own precedence order.
    public static let fileNames = [
        "compose.yaml",
        "compose.yml",
        "docker-compose.yaml",
        "docker-compose.yml",
    ]

    /// Where people put it when it is not at the root.
    public static let searchedSubdirectories = [
        "docker",
        ".docker",
        "deploy",
        "deployment",
        "infra",
        "ops",
        "compose",
        "docker-compose",
    ]

    /// The Compose file to use, or nil when the project defines none.
    ///
    /// `fileExists` is a parameter so the search can be tested without laying
    /// out directories on disk.
    public static func file(
        forProjectAt root: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        let base = URL(fileURLWithPath: root)
        for directory in [base] + searchedSubdirectories.map(base.appendingPathComponent) {
            for name in fileNames {
                let candidate = directory.appendingPathComponent(name).path
                if fileExists(candidate) { return candidate }
            }
        }
        return nil
    }

    /// The directory Compose should run from, falling back to the project root
    /// so a command still runs somewhere sensible when nothing was found.
    public static func directory(
        forProjectAt root: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        guard let file = file(forProjectAt: root, fileExists: fileExists) else { return root }
        return URL(fileURLWithPath: file).deletingLastPathComponent().path
    }
}
