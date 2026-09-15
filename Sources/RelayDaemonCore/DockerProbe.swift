import Foundation
import RelayProtocol

/// Reads Docker state through the user's own CLI.
///
/// Relay ships no engine and replaces no part of Docker Desktop: it only shows
/// the containers belonging to the project in front of you.
public enum DockerProbe {
    /// Compose `ps --format json` shape.
    private struct ComposeEntry: Decodable {
        var ID: String?
        var Name: String?
        var Service: String?
        var Image: String?
        var State: String?
        var Status: String?
        var Publishers: [Publisher]?
        /// `docker ps` uses a flat string instead of structured publishers.
        var Ports: String?
        var Names: String?
        var Labels: String?

        struct Publisher: Decodable {
            var URL: String?
            var TargetPort: Int?
            var PublishedPort: Int?
            /// Swift reserves `Protocol` as a member name, so the JSON key is
            /// mapped explicitly.
            var networkProtocol: String?

            enum CodingKeys: String, CodingKey {
                case URL
                case TargetPort
                case PublishedPort
                case networkProtocol = "Protocol"
            }
        }
    }

    /// Parses both shapes docker emits: newline-delimited objects (Compose v2.21+
    /// and `docker ps`) and a single JSON array (older Compose).
    public static func parseContainers(_ output: String) -> [DockerContainer] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let decoder = JSONDecoder()
        var entries: [ComposeEntry] = []

        if trimmed.hasPrefix("[") {
            entries = (try? decoder.decode([ComposeEntry].self, from: Data(trimmed.utf8))) ?? []
        } else {
            for line in trimmed.split(separator: "\n", omittingEmptySubsequences: true) {
                let candidate = line.trimmingCharacters(in: .whitespaces)
                guard candidate.hasPrefix("{") else { continue }
                if let entry = try? decoder.decode(ComposeEntry.self, from: Data(candidate.utf8)) {
                    entries.append(entry)
                }
            }
        }

        return entries.compactMap(makeContainer)
    }

    private static func makeContainer(_ entry: ComposeEntry) -> DockerContainer? {
        let name = entry.Name ?? entry.Names
        guard let name, !name.isEmpty else { return nil }

        let ports: [DockerPort]
        if let publishers = entry.Publishers {
            ports = publishers.compactMap { publisher in
                guard let published = publisher.PublishedPort, published > 0 else { return nil }
                return DockerPort(
                    published: published,
                    target: publisher.TargetPort ?? published,
                    networkProtocol: publisher.networkProtocol ?? "tcp"
                )
            }
        } else {
            ports = parsePortString(entry.Ports ?? "")
        }

        let labels = parseLabels(entry.Labels)
        return DockerContainer(
            id: entry.ID ?? name,
            name: name,
            service: entry.Service ?? labels["com.docker.compose.service"],
            image: entry.Image ?? "",
            state: entry.State ?? inferState(from: entry.Status ?? ""),
            status: entry.Status ?? "",
            publishedPorts: deduplicate(ports),
            composeProject: labels["com.docker.compose.project"],
            composeWorkingDirectory: labels["com.docker.compose.project.working_dir"]
        )
    }

    /// `docker ps` reports labels as a comma-separated `key=value` list.
    static func parseLabels(_ text: String?) -> [String: String] {
        guard let text, !text.isEmpty else { return [:] }
        var labels: [String: String] = [:]
        for pair in text.split(separator: ",") {
            guard let separator = pair.firstIndex(of: "=") else { continue }
            let key = String(pair[pair.startIndex ..< separator]).trimmingCharacters(in: .whitespaces)
            let value = String(pair[pair.index(after: separator)...])
            labels[key] = value
        }
        return labels
    }

    /// `docker ps` reports ports as "0.0.0.0:8080->80/tcp, :::8080->80/tcp".
    static func parsePortString(_ text: String) -> [DockerPort] {
        var ports: [DockerPort] = []
        for mapping in text.split(separator: ",") {
            let entry = mapping.trimmingCharacters(in: .whitespaces)
            guard let arrow = entry.range(of: "->") else { continue }

            let left = String(entry[entry.startIndex ..< arrow.lowerBound])
            let right = String(entry[arrow.upperBound...])

            guard let colon = left.lastIndex(of: ":"),
                  let published = Int(left[left.index(after: colon)...])
            else { continue }

            let targetPart = right.split(separator: "/")
            guard let target = Int(targetPart.first ?? "") else { continue }
            let networkProtocol = targetPart.count > 1 ? String(targetPart[1]) : "tcp"

            ports.append(DockerPort(published: published, target: target, networkProtocol: networkProtocol))
        }
        return ports
    }

    /// A dual-stack publish appears twice; the user cares about it once.
    private static func deduplicate(_ ports: [DockerPort]) -> [DockerPort] {
        var seen = Set<String>()
        return ports.filter { seen.insert("\($0.published)-\($0.target)-\($0.networkProtocol)").inserted }
    }

    private static func inferState(from status: String) -> String {
        let lowered = status.lowercased()
        if lowered.hasPrefix("up") { return "running" }
        if lowered.hasPrefix("exited") { return "exited" }
        if lowered.hasPrefix("created") { return "created" }
        if lowered.hasPrefix("restarting") { return "restarting" }
        if lowered.hasPrefix("paused") { return "paused" }
        return "unknown"
    }

    // MARK: - Live queries

    /// Locates the `docker` binary. A GUI-launched daemon does not inherit the
    /// user's shell PATH, so the usual install locations are checked directly.
    public static func locateDockerCLI() -> String? {
        let candidates = [
            "/usr/local/bin/docker",
            "/opt/homebrew/bin/docker",
            "/usr/bin/docker",
            "\(NSHomeDirectory())/.docker/bin/docker",
            "/Applications/Docker.app/Contents/Resources/bin/docker",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func snapshot(
        projectDirectory: String,
        runner: some CommandRunning = SystemCommandRunner(),
        dockerPath: String? = locateDockerCLI()
    ) -> DockerSnapshot {
        guard let dockerPath else {
            return DockerSnapshot(isAvailable: false, message: "Docker CLI not found")
        }

        let projectName = URL(fileURLWithPath: projectDirectory).lastPathComponent

        guard let listing = runner.run(
            dockerPath,
            arguments: ["ps", "--all", "--no-trunc", "--format", "json"],
            timeout: 12
        ) else {
            return DockerSnapshot(isAvailable: false, message: "Could not run the Docker CLI")
        }
        if listing.timedOut {
            return DockerSnapshot(isAvailable: false, message: "Docker command timed out")
        }
        if !listing.succeeded {
            let reason = firstLine(of: listing.standardError.trimmingCharacters(in: .whitespacesAndNewlines))
            return DockerSnapshot(isAvailable: false, message: reason.isEmpty ? "Docker is unavailable" : reason)
        }

        let all = parseContainers(listing.standardOutput)

        // A container belongs to the project if Compose was run from anywhere
        // inside it. Matching the project root exactly is not enough: putting
        // the stack in `<project>/docker` is extremely common, and the Compose
        // project name is frequently nothing like the folder name — one real
        // example has `qrator-ru/docker` running a project called `curator`.
        let owned = all.filter { container in
            guard let workingDirectory = container.composeWorkingDirectory else { return false }
            return isPath(workingDirectory, inside: projectDirectory)
        }
        if !owned.isEmpty {
            return DockerSnapshot(
                isAvailable: true,
                composeProjectName: owned.first?.composeProject ?? projectName,
                containers: owned
            )
        }

        // Failing that, a Compose project named after the folder is a good bet.
        let byName = all.filter { $0.composeProject?.lowercased() == projectName.lowercased() }
        if !byName.isEmpty {
            return DockerSnapshot(
                isAvailable: true,
                composeProjectName: projectName,
                containers: byName
            )
        }

        // Nothing is running for this project; ask Compose what it *would*
        // create, which also reports stopped services.
        guard let compose = runner.run(
            dockerPath,
            arguments: ["compose", "--project-directory", projectDirectory, "ps", "--all", "--format", "json"],
            timeout: 12
        ), !compose.timedOut else {
            return DockerSnapshot(isAvailable: true, composeProjectName: projectName, containers: [])
        }
        if !compose.succeeded {
            return DockerSnapshot(isAvailable: true, composeProjectName: projectName, containers: [])
        }
        return DockerSnapshot(
            isAvailable: true,
            composeProjectName: projectName,
            containers: parseContainers(compose.standardOutput)
        )
    }

    /// True when `path` is the directory itself or lives underneath it.
    static func isPath(_ path: String, inside root: String) -> Bool {
        let normalise: (String) -> String = { value in
            let standardised = URL(fileURLWithPath: value).standardizedFileURL.path
            return standardised.hasSuffix("/") ? String(standardised.dropLast()) : standardised
        }
        let child = normalise(path)
        let parent = normalise(root)
        guard !parent.isEmpty else { return false }
        return child == parent || child.hasPrefix(parent + "/")
    }

    private static func isMissingComposeFile(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("no configuration file provided")
            || lowered.contains("no such file or directory")
            || lowered.contains("can't find a suitable configuration file")
    }

    private static func firstLine(of text: String) -> String {
        String(text.split(separator: "\n").first ?? "Docker is unavailable")
    }
}
