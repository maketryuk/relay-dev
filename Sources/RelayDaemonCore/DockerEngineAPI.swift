import Darwin
import Foundation
import RelayProtocol

/// Reads containers from the engine itself, over the socket it serves.
///
/// Relay used to ask the `docker` binary, which meant three things it does not
/// need: a binary on a PATH a GUI-launched daemon never inherits, a process
/// spawned every time the panel refreshes, and whatever single engine that
/// binary's context happens to point at. The engine's own HTTP API has none of
/// those properties — it is a socket, and every engine on a Mac puts one
/// somewhere known.
///
/// It does not replace the CLI everywhere. Compose is a client-side tool with
/// no presence in this API at all, so starting a stack still goes through
/// `docker compose`. Reading what is running does not.
public enum DockerEngineAPI {
    /// Where each engine serves. Ordered by how specific the answer is: an
    /// explicit `DOCKER_HOST` is a decision someone made, and the rest are
    /// conventions.
    public static func candidateSockets(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        contentsOfDirectory: (String) -> [String] = {
            (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []
        }
    ) -> [String] {
        var paths: [String] = []

        if let host = environment["DOCKER_HOST"], host.hasPrefix("unix://") {
            paths.append(String(host.dropFirst("unix://".count)))
        }

        // Docker Desktop's own, and the symlink OrbStack and Rancher Desktop
        // put at the classic location when they are allowed to.
        paths.append("/var/run/docker.sock")
        paths.append("\(home)/.docker/run/docker.sock")

        // Colima keeps one per profile, and a profile is rarely "default" on a
        // machine that has more than one thing to run.
        for profile in contentsOfDirectory("\(home)/.colima").sorted() {
            paths.append("\(home)/.colima/\(profile)/docker.sock")
        }

        paths.append("\(home)/.orbstack/run/docker.sock")
        paths.append("\(home)/.rd/docker.sock")
        paths.append("\(home)/.local/share/containers/podman/machine/podman.sock")

        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    /// Every container the first engine that answers knows about, or nil when
    /// none of them does.
    ///
    /// Nil is not "no containers": it is "no engine", which the caller has to
    /// tell apart because one is an empty list and the other is a panel saying
    /// nothing is running.
    public static func listContainers(
        sockets: [String] = candidateSockets(),
        request: (String, String) -> Data? = { socket, path in
            try? UnixSocketHTTP.get(path, from: socket, timeout: 3)
        }
    ) -> [DockerContainer]? {
        for socket in sockets {
            // `all=1` because a stopped container is still this project's, and
            // a panel that hides them has nothing to offer but Up.
            guard let body = request(socket, "/v1.43/containers/json?all=1") else { continue }
            guard let containers = parseAPIContainers(body) else { continue }
            return containers
        }
        return nil
    }

    /// The `GET /containers/json` shape, which is not the shape the CLI prints:
    /// names arrive as a list with a leading slash, ports as objects, and
    /// labels already as a dictionary rather than as one comma-separated line.
    public static func parseAPIContainers(_ body: Data) -> [DockerContainer]? {
        struct Entry: Decodable {
            var Id: String?
            var Names: [String]?
            var Image: String?
            var State: String?
            var Status: String?
            var Ports: [Port]?
            var Labels: [String: String]?

            struct Port: Decodable {
                var PrivatePort: Int?
                var PublicPort: Int?
                /// Swift reserves `Type` as a member name, so the JSON key is
                /// mapped explicitly — the same dance `Protocol` needs.
                var networkProtocol: String?

                enum CodingKeys: String, CodingKey {
                    case PrivatePort
                    case PublicPort
                    case networkProtocol = "Type"
                }
            }
        }

        guard let entries = try? JSONDecoder().decode([Entry].self, from: body) else { return nil }

        return entries.compactMap { entry in
            // A container always has a name; one without is a reply Relay does
            // not understand and must not half-render.
            guard let name = entry.Names?.first.map({ $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }),
                  !name.isEmpty
            else { return nil }

            let labels = entry.Labels ?? [:]
            let ports = (entry.Ports ?? []).compactMap { port -> DockerPort? in
                guard let published = port.PublicPort, published > 0 else { return nil }
                return DockerPort(
                    published: published,
                    target: port.PrivatePort ?? published,
                    networkProtocol: port.networkProtocol ?? "tcp"
                )
            }

            var seen = Set<String>()
            let unique = ports.filter {
                seen.insert("\($0.published)-\($0.target)-\($0.networkProtocol)").inserted
            }

            return DockerContainer(
                id: entry.Id ?? name,
                name: name,
                service: labels["com.docker.compose.service"],
                image: entry.Image ?? "",
                state: entry.State ?? "unknown",
                status: entry.Status ?? "",
                publishedPorts: unique,
                composeProject: labels["com.docker.compose.project"],
                composeWorkingDirectory: labels["com.docker.compose.project.working_dir"],
                composeConfigFile: labels["com.docker.compose.project.config_files"]?
                    .split(separator: ",")
                    .first
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
            )
        }
    }
}
