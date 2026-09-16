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
            composeWorkingDirectory: labels["com.docker.compose.project.working_dir"],
            // Compose records every file it was given, comma separated. The
            // first is the one the rest override, and it is the one to run.
            composeConfigFile: labels["com.docker.compose.project.config_files"]?
                .split(separator: ",")
                .first
                .map { String($0).trimmingCharacters(in: .whitespaces) }
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
        dockerPath: String? = locateDockerCLI(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        /// The engine asked directly. Injected so a test never depends on what
        /// happens to be running on the machine running it.
        engineContainers: () -> [DockerContainer]? = { DockerEngineAPI.listContainers() }
    ) -> DockerSnapshot {
        let projectName = URL(fileURLWithPath: projectDirectory).lastPathComponent

        // The engine's own socket first. It answers for whichever engine is
        // actually running rather than for whichever one a CLI context points
        // at, it needs no binary on a PATH the daemon never inherited, and it
        // costs no process — which matters when the panel asks every few
        // seconds for as long as it is open.
        if let containers = engineContainers() {
            return matching(
                containers,
                projectName: projectName,
                projectDirectory: projectDirectory,
                runner: runner,
                dockerPath: dockerPath,
                fileExists: fileExists
            )
        }

        guard let dockerPath else {
            // The one Relay genuinely cannot help with. It shows containers; it
            // does not carry an engine, and pretending otherwise with a button
            // would waste the click it took to find out.
            return DockerSnapshot(
                isAvailable: false,
                message: "Docker is not installed on this Mac.",
                absence: .notInstalled
            )
        }

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
            let stderr = listing.standardError.trimmingCharacters(in: .whitespacesAndNewlines)
            let reason = firstLine(of: stderr)
            if isEngineDown(stderr) {
                // Four lines about a socket path mean one thing, and it is not
                // something the person reading them has to diagnose.
                return DockerSnapshot(
                    isAvailable: false,
                    message: reason.isEmpty ? "Docker is unavailable" : reason,
                    absence: .engineStopped(installedEngine(
                        pointedAtBy: stderr,
                        fileExists: fileExists
                    ))
                )
            }
            return DockerSnapshot(
                isAvailable: false,
                message: reason.isEmpty ? "Docker is unavailable" : reason,
                absence: .failed
            )
        }

        return matching(
            parseContainers(listing.standardOutput),
            projectName: projectName,
            projectDirectory: projectDirectory,
            runner: runner,
            dockerPath: dockerPath,
            fileExists: fileExists
        )
    }

    /// Which of the machine's containers belong to the project in front of you.
    ///
    /// Shared by both ways of asking, because the answer has nothing to do with
    /// how the list was obtained.
    private static func matching(
        _ all: [DockerContainer],
        projectName: String,
        projectDirectory: String,
        runner: some CommandRunning,
        dockerPath: String?,
        fileExists: (String) -> Bool
    ) -> DockerSnapshot {
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
        // create, which also reports stopped services. The file is named
        // explicitly because Compose looks in the working directory otherwise,
        // and a stack kept in `docker/` would never be found.
        guard let dockerPath,
              let composeFile = ComposeLocator.file(forProjectAt: projectDirectory, fileExists: fileExists)
        else {
            // Either there is no file to read or no CLI to read it with:
            // Compose is a client-side tool and has no presence in the engine's
            // API, so this is the one question the socket cannot answer.
            return DockerSnapshot(isAvailable: true, composeProjectName: projectName, containers: [])
        }
        guard let compose = runner.run(
            dockerPath,
            arguments: ["compose", "--file", composeFile, "ps", "--all", "--format", "json"],
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

    /// True when the CLI is in working order and simply has nobody to talk to.
    ///
    /// Every engine phrases it differently, and the phrasing has changed
    /// between Docker versions, so several are recognised rather than one.
    static func isEngineDown(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if lowered.contains("cannot connect to the docker daemon") { return true }
        if lowered.contains("failed to connect to the docker api") { return true }
        if lowered.contains("is the docker daemon running") { return true }
        if lowered.contains("connection refused") { return true }
        // The shape Docker Desktop leaves behind when it quits: the socket it
        // was serving is simply gone.
        return lowered.contains("docker.sock") && lowered.contains("no such file or directory")
    }

    /// Which engine is installed and could be started, judged first by the
    /// socket the CLI failed to reach and then by what is actually on disk.
    ///
    /// Returns nil when nothing recognisable is installed, which is not the
    /// same as no engine being needed — it means Relay has nothing to offer to
    /// press, and should say the engine is not running rather than invent one.
    static func installedEngine(
        pointedAtBy reason: String,
        fileExists: (String) -> Bool
    ) -> DockerEngine? {
        let hasColima = colimaPaths.contains(where: fileExists)
        let hasDesktop = fileExists(dockerDesktopPath)

        if reason.lowercased().contains(".colima"), hasColima { return .colima }
        if hasDesktop { return .dockerDesktop }
        if hasColima { return .colima }
        return nil
    }

    public static let dockerDesktopPath = "/Applications/Docker.app"
    public static let colimaPaths = ["/opt/homebrew/bin/colima", "/usr/local/bin/colima"]

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
