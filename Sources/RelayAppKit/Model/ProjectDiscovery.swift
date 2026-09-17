import Foundation
import RelayProtocol

/// What Relay can infer about a directory the moment the user adds it.
struct ProjectFacts: Equatable, Sendable {
    var suggestedName: String
    var isGitRepository: Bool
    var packageManager: String?
    var devCommand: String?
    var hasDockerfile: Bool
    /// Full path, because where the stack is defined decides where Compose
    /// has to be run from.
    var composeFile: String?

    var hasDocker: Bool { hasDockerfile || composeFile != nil }
}

enum ProjectDiscovery {
    /// Ordered by how likely the script is to be "the dev server".
    private static let devScriptCandidates = ["dev", "start", "serve", "develop"]

    static func inspect(path: String) -> ProjectFacts {
        let directory = URL(fileURLWithPath: path)
        let manager = FileManager.default

        var facts = ProjectFacts(
            suggestedName: directory.lastPathComponent,
            isGitRepository: GitProbe.isRepository(at: path),
            packageManager: nil,
            devCommand: nil,
            hasDockerfile: manager.fileExists(atPath: directory.appendingPathComponent("Dockerfile").path),
            // Through the shared locator, so a stack kept in `docker/` counts as
            // this project having one — which is what the Docker tab asks.
            composeFile: ComposeLocator.file(forProjectAt: path) {
                manager.fileExists(atPath: $0)
            }
        )

        let packageManager = detectPackageManager(in: directory)
        facts.packageManager = packageManager

        // The name is the folder's, and only the folder's. `package.json` is
        // written by a scaffold and almost never edited afterwards, so what it
        // says is `nuxt-app`, `vite-project`, `my-app` — a name that belongs to
        // the tool that made the directory rather than to the project in it.
        // The folder is what the user chose, it is unique on their disk, and it
        // is what the path printed under the name already says.
        if let package = readPackageJSON(in: directory) {
            if let scripts = package["scripts"] as? [String: Any],
               let script = devScriptCandidates.first(where: { scripts[$0] != nil }) {
                facts.devCommand = "\(packageManager ?? "npm") run \(script)"
            }
        }

        return facts
    }

    private static func detectPackageManager(in directory: URL) -> String? {
        let manager = FileManager.default
        // Lockfiles are the only trustworthy signal; package.json says nothing.
        if manager.fileExists(atPath: directory.appendingPathComponent("pnpm-lock.yaml").path) { return "pnpm" }
        if manager.fileExists(atPath: directory.appendingPathComponent("bun.lockb").path) { return "bun" }
        if manager.fileExists(atPath: directory.appendingPathComponent("bun.lock").path) { return "bun" }
        if manager.fileExists(atPath: directory.appendingPathComponent("yarn.lock").path) { return "yarn" }
        if manager.fileExists(atPath: directory.appendingPathComponent("package-lock.json").path) { return "npm" }
        if manager.fileExists(atPath: directory.appendingPathComponent("package.json").path) { return "npm" }
        return nil
    }

    private static func readPackageJSON(in directory: URL) -> [String: Any]? {
        let url = directory.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }
}
