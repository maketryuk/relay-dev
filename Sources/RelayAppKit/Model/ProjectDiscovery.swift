import Foundation
import RelayProtocol

/// What Relay can infer about a directory the moment the user adds it.
struct ProjectFacts: Equatable, Sendable {
    var suggestedName: String
    var isGitRepository: Bool
    var packageManager: String?
    var devCommand: String?
    var hasDockerfile: Bool
    var composeFile: String?

    var hasDocker: Bool { hasDockerfile || composeFile != nil }
}

enum ProjectDiscovery {
    private static let composeCandidates = [
        "compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml",
    ]

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
            composeFile: composeCandidates.first {
                manager.fileExists(atPath: directory.appendingPathComponent($0).path)
            }
        )

        let packageManager = detectPackageManager(in: directory)
        facts.packageManager = packageManager

        if let package = readPackageJSON(in: directory) {
            if let name = package["name"] as? String, !name.isEmpty {
                facts.suggestedName = name
            }
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
