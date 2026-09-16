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

    /// Suffixes a project names its environments with, most local first.
    ///
    /// A stack split into `docker-compose.local.yml`, `.stage.yml` and
    /// `.prod.yml` has no file under any of the names Compose looks for, which
    /// is the other half of how "no configuration file provided" happens.
    ///
    /// Deliberately not every suffix that exists: the file this picks is the
    /// one an Up button starts, and guessing at a name nobody recognised is how
    /// a laptop ends up running a production stack. Anything else is left to be
    /// run by hand, which is the safe side to be wrong on.
    public static let localEnvironments = [
        "local",
        "dev",
        "development",
        "override",
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
            for name in candidateNames {
                let candidate = directory.appendingPathComponent(name).path
                if fileExists(candidate) { return candidate }
            }
        }
        return nil
    }

    /// Every name worth looking for, in the order they are preferred: the ones
    /// Compose finds on its own first, then the environment a laptop wants.
    static var candidateNames: [String] {
        var names = fileNames
        for environment in localEnvironments {
            for name in fileNames {
                let stem = (name as NSString).deletingPathExtension
                let suffix = (name as NSString).pathExtension
                names.append("\(stem).\(environment).\(suffix)")
            }
        }
        return names
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
