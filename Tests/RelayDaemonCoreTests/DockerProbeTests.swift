import Foundation
import Testing

@testable import RelayDaemonCore
@testable import RelayProtocol

@Suite("Docker output parsing")
struct DockerProbeTests {
    @Test("Newline-delimited compose output is parsed")
    func parsesNDJSON() {
        // Compose v2.21+ emits one object per line.
        let output = """
        {"ID":"a1","Name":"shop-web-1","Service":"web","Image":"nginx:alpine","State":"running","Status":"Up 3 minutes","Publishers":[{"URL":"0.0.0.0","TargetPort":80,"PublishedPort":8080,"Protocol":"tcp"}]}
        {"ID":"b2","Name":"shop-db-1","Service":"db","Image":"postgres:16","State":"running","Status":"Up 3 minutes","Publishers":[{"URL":"0.0.0.0","TargetPort":5432,"PublishedPort":5432,"Protocol":"tcp"}]}
        """
        let containers = DockerProbe.parseContainers(output)
        #expect(containers.count == 2)
        #expect(containers[0].name == "shop-web-1")
        #expect(containers[0].service == "web")
        #expect(containers[0].image == "nginx:alpine")
        #expect(containers[0].publishedPorts == [DockerPort(published: 8080, target: 80)])
        #expect(containers[1].publishedPorts.first?.published == 5432)
    }

    @Test("A single JSON array from older Compose is parsed too")
    func parsesJSONArray() {
        let output = """
        [{"ID":"a1","Name":"legacy-web-1","Service":"web","State":"running","Status":"Up 1 hour","Publishers":[]}]
        """
        let containers = DockerProbe.parseContainers(output)
        #expect(containers.count == 1)
        #expect(containers[0].name == "legacy-web-1")
        #expect(containers[0].publishedPorts.isEmpty)
    }

    @Test("`docker ps` output with a flat port string is parsed")
    func parsesDockerPsShape() {
        let output = """
        {"ID":"c3","Names":"standalone-redis","Image":"redis:7","State":"running","Status":"Up 10 seconds","Ports":"0.0.0.0:6379->6379/tcp, :::6379->6379/tcp"}
        """
        let containers = DockerProbe.parseContainers(output)
        #expect(containers.count == 1)
        #expect(containers[0].name == "standalone-redis")
        // The dual-stack publish is one mapping from the user's point of view.
        #expect(containers[0].publishedPorts == [DockerPort(published: 6379, target: 6379)])
    }

    @Test(
        "Port strings of every shape are parsed",
        arguments: [
            ("0.0.0.0:8080->80/tcp", 8080, 80, "tcp"),
            ("127.0.0.1:5432->5432/tcp", 5432, 5432, "tcp"),
            (":::9000->9000/udp", 9000, 9000, "udp"),
        ]
    )
    func parsesPortStrings(text: String, published: Int, target: Int, networkProtocol: String) {
        let ports = DockerProbe.parsePortString(text)
        #expect(ports.count == 1)
        #expect(ports[0].published == published)
        #expect(ports[0].target == target)
        #expect(ports[0].networkProtocol == networkProtocol)
    }

    @Test("Unpublished ports produce no mapping")
    func ignoresUnpublishedPorts() {
        #expect(DockerProbe.parsePortString("80/tcp").isEmpty)
        #expect(DockerProbe.parsePortString("").isEmpty)
    }

    @Test("A publisher with no published port is skipped")
    func skipsUnpublishedPublisher() {
        let output = """
        {"Name":"internal-only","State":"running","Publishers":[{"TargetPort":80,"PublishedPort":0,"Protocol":"tcp"}]}
        """
        #expect(DockerProbe.parseContainers(output)[0].publishedPorts.isEmpty)
    }

    @Test("Empty and malformed output yields no containers rather than failing")
    func toleratesGarbage() {
        #expect(DockerProbe.parseContainers("").isEmpty)
        #expect(DockerProbe.parseContainers("   \n  ").isEmpty)
        #expect(DockerProbe.parseContainers("Cannot connect to the Docker daemon").isEmpty)
        // One bad line must not discard the good ones.
        let mixed = """
        not json
        {"Name":"good","State":"running"}
        """
        #expect(DockerProbe.parseContainers(mixed).map(\.name) == ["good"])
    }

    @Test("An entry with no name is discarded")
    func requiresName() {
        #expect(DockerProbe.parseContainers(#"{"ID":"x","State":"running"}"#).isEmpty)
    }

    @Test("State is inferred from the status text when absent")
    func infersState() {
        let output = """
        {"Names":"a","Status":"Up 2 minutes"}
        {"Names":"b","Status":"Exited (0) 3 minutes ago"}
        {"Names":"c","Status":"Created"}
        {"Names":"d","Status":"Restarting (1) 2 seconds ago"}
        """
        #expect(DockerProbe.parseContainers(output).map(\.state) == ["running", "exited", "created", "restarting"])
    }
}

@Suite("Docker status mapping")
struct DockerStatusMappingTests {
    private func container(state: String, status: String = "") -> DockerContainer {
        DockerContainer(id: "x", name: "x", state: state, status: status)
    }

    @Test("Docker states map onto Relay's status model")
    func mapsStates() {
        #expect(container(state: "running").runtimeStatus == .working)
        #expect(container(state: "restarting").runtimeStatus == .starting)
        #expect(container(state: "created").runtimeStatus == .idle)
        #expect(container(state: "paused").runtimeStatus == .idle)
        #expect(container(state: "dead").runtimeStatus == .error)
        #expect(container(state: "something-new").runtimeStatus == .offline)
    }

    @Test("A clean exit is finished; a failing exit is an error")
    func distinguishesExitReason() {
        #expect(container(state: "exited", status: "Exited (0) 2 minutes ago").runtimeStatus == .finished)
        #expect(container(state: "exited", status: "Exited (137) 2 minutes ago").runtimeStatus == .error)
    }

    @Test("A compose project aggregates like a project of sessions does")
    func aggregatesSnapshot() {
        let snapshot = DockerSnapshot(
            isAvailable: true,
            containers: [
                container(state: "running"),
                container(state: "exited", status: "Exited (1) ago"),
            ]
        )
        #expect(snapshot.aggregatedStatus == .error)
        #expect(DockerSnapshot(isAvailable: true).aggregatedStatus == .offline)
    }

    @Test("A published TCP port offers a localhost URL")
    func portURL() {
        #expect(DockerPort(published: 8080, target: 80).url?.absoluteString == "http://localhost:8080")
        #expect(DockerPort(published: 9000, target: 9000, networkProtocol: "udp").url == nil)
        #expect(DockerPort(published: 8080, target: 80).displayText == "8080→80")
    }
}

@Suite("Docker availability")
struct DockerAvailabilityTests {
    private func result(status: Int32, out: String = "", err: String = "") -> CommandResult {
        CommandResult(status: status, standardOutput: out, standardError: err)
    }

    private func snapshot(
        _ responses: [String: CommandResult],
        directory: String = "/Users/me/shop",
        dockerPath: String? = "/usr/local/bin/docker",
        composeFiles: [String] = ["/Users/me/shop/docker-compose.yml"]
    ) -> DockerSnapshot {
        DockerProbe.snapshot(
            projectDirectory: directory,
            runner: FakeCommandRunner(results: responses),
            dockerPath: dockerPath,
            fileExists: Set(composeFiles).contains
        )
    }

    @Test("A missing CLI is reported as the one thing Relay cannot fix")
    func missingCLI() {
        // Not an engine that needs starting: there is no engine. Relay shows
        // containers and ships none, so the panel must not offer a button.
        let result = snapshot([:], dockerPath: nil)
        #expect(!result.isAvailable)
        #expect(result.absence == .notInstalled)
    }

    @Test("An engine that is merely stopped is told apart from a failure")
    func stoppedEngineIsNotAFailure() {
        // The wall of text Docker Desktop leaves behind when it quits. It means
        // one thing, and the person reading it should not have to work it out.
        let result = snapshot([
            "docker ps": result(
                status: 1,
                err: "failed to connect to the docker API at unix:///Users/me/.docker/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /Users/me/.docker/run/docker.sock: connect: no such file or directory"
            ),
        ])
        #expect(!result.isAvailable)
        guard case .engineStopped = result.absence else {
            Issue.record("expected a stopped engine, got \(String(describing: result.absence))")
            return
        }
    }

    @Test("An error Relay has not been taught to read stays a failure")
    func unrecognisedErrorsAreNotParaphrased() {
        let result = snapshot(["docker ps": result(status: 1, err: "permission denied while trying to connect")])
        #expect(result.absence == .failed)
        #expect(result.message == "permission denied while trying to connect")
    }

    @Test("An unreachable engine surfaces the CLI's own message")
    func engineNotRunning() {
        // The CLI puts the reason on stderr and exits non-zero while writing
        // nothing at all to stdout, which is why the status has to be consulted.
        let result = snapshot([
            "docker ps": result(
                status: 1,
                err: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock."
            ),
        ])
        #expect(!result.isAvailable)
        #expect(result.message?.contains("Cannot connect") == true)
    }

    @Test("Containers are found by their compose working-directory label")
    func findsContainersByWorkingDirectoryLabel() {
        // The stack is often defined in a subdirectory, so the label is the only
        // reliable link between a container and the project on screen.
        let payload = """
        {"ID":"a","Names":"shop-web-1","State":"running","Status":"Up 2 minutes",        "Labels":"com.docker.compose.project=shop,com.docker.compose.service=web"}
        """
        let result = snapshot(["docker ps": result(status: 0, out: payload)])
        #expect(result.isAvailable)
        #expect(result.composeProjectName == "shop")
        #expect(result.containers.map(\.name) == ["shop-web-1"])
        #expect(result.containers.first?.service == "web")
    }

    @Test("A project with no containers and no compose file is fine, just unused")
    func missingComposeFileIsNotAnOutage() {
        // Reporting "Docker unavailable" for a project that simply has no stack
        // would be wrong and alarming.
        let result = snapshot([
            "docker ps": result(status: 0, out: ""),
            "docker compose": result(status: 1, err: "no configuration file provided: not found"),
        ])
        #expect(result.isAvailable)
        #expect(result.containers.isEmpty)
        #expect(result.message == nil)
    }

    @Test("Compose is consulted when nothing is running for the project")
    func fallsBackToCompose() {
        let payload = #"{"ID":"b","Name":"legacy-api-1","Service":"api","State":"exited","Status":"Exited (0)"}"#
        let result = snapshot([
            "docker ps": result(status: 0, out: ""),
            "docker compose": result(status: 0, out: payload),
        ])
        #expect(result.isAvailable)
        #expect(result.containers.map(\.name) == ["legacy-api-1"])
    }

    @Test("A project with no compose file is not asked about one")
    func withoutAComposeFileComposeIsNotRun() {
        // Compose looks in the working directory, so running it for a project
        // that defines no stack only ever produces "no configuration file
        // provided" — a confusing way to say there is nothing here.
        let result = snapshot(
            ["docker ps": result(status: 0, out: "")],
            composeFiles: []
        )
        #expect(result.isAvailable)
        #expect(result.containers.isEmpty)
        #expect(result.message == nil)
    }

    @Test("A timeout is reported as such")
    func timeoutIsReported() {
        let result = snapshot([
            "docker ps": CommandResult(status: -1, standardOutput: "", standardError: "", timedOut: true),
        ])
        #expect(!result.isAvailable)
        #expect(result.message == "Docker command timed out")
    }

    @Test("A CLI that cannot be launched at all is reported")
    func cliCannotLaunch() {
        let result = DockerProbe.snapshot(
            projectDirectory: "/tmp",
            runner: FakeCommandRunner(responses: [:], isUnavailable: true),
            dockerPath: "/usr/local/bin/docker"
        )
        #expect(!result.isAvailable)
    }
}

@Suite("Docker engines")
struct DockerEngineTests {
    private func exists(_ paths: [String]) -> (String) -> Bool {
        let set = Set(paths)
        return { set.contains($0) }
    }

    @Test("The socket the CLI failed to reach names the engine behind it")
    func socketNamesTheEngine() {
        let both = exists([DockerProbe.dockerDesktopPath, "/opt/homebrew/bin/colima"])
        #expect(DockerProbe.installedEngine(
            pointedAtBy: "dial unix /Users/me/.colima/default/docker.sock: connect: no such file or directory",
            fileExists: both
        ) == .colima)
        #expect(DockerProbe.installedEngine(
            pointedAtBy: "dial unix /Users/me/.docker/run/docker.sock: connect: no such file or directory",
            fileExists: both
        ) == .dockerDesktop)
    }

    @Test("Colima alone is offered when it is the only engine installed")
    func colimaWithoutDesktop() {
        #expect(DockerProbe.installedEngine(
            pointedAtBy: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock.",
            fileExists: exists(["/usr/local/bin/colima"])
        ) == .colima)
    }

    @Test("Nothing installed means nothing offered")
    func nothingToOffer() {
        // A machine with a `docker` CLI and no engine behind it. Relay has
        // nothing it could press, and a button that cannot honour itself is
        // worse than the sentence explaining why there is none.
        #expect(DockerProbe.installedEngine(
            pointedAtBy: "Cannot connect to the Docker daemon at unix:///var/run/docker.sock.",
            fileExists: exists([])
        ) == nil)
    }

    @Test("Every way an engine says it is not there is recognised")
    func recognisesTheWordings() {
        #expect(DockerProbe.isEngineDown("Cannot connect to the Docker daemon at unix:///var/run/docker.sock."))
        #expect(DockerProbe.isEngineDown("failed to connect to the docker API at unix:///x/docker.sock: connect: no such file or directory"))
        #expect(DockerProbe.isEngineDown("Is the docker daemon running?"))
        #expect(DockerProbe.isEngineDown("dial tcp 127.0.0.1:2375: connect: connection refused"))
        #expect(DockerProbe.isEngineDown("no such file or directory") == false)
        #expect(DockerProbe.isEngineDown("permission denied") == false)
    }
}

@Suite("Docker labels")
struct DockerLabelTests {
    @Test("Labels parse into a dictionary")
    func parsesLabels() {
        let labels = DockerProbe.parseLabels(
            "com.docker.compose.project=shop,com.docker.compose.service=web,maintainer=me"
        )
        #expect(labels["com.docker.compose.project"] == "shop")
        #expect(labels["com.docker.compose.service"] == "web")
        #expect(labels["maintainer"] == "me")
    }

    @Test("The file Compose was given is read off the container")
    func readsTheConfigFile() {
        // Compose records it on everything it creates, which makes it the
        // answer to "which file is this stack" rather than a guess at it.
        let payload = """
        {"ID":"a","Names":"curator.php","State":"running","Status":"Up 2 hours",\
        "Labels":"com.docker.compose.project=curator,com.docker.compose.project.config_files=/p/docker/docker-compose.local.yml,com.docker.compose.project.working_dir=/p/docker"}
        """
        let container = DockerProbe.parseContainers(payload).first
        #expect(container?.composeConfigFile == "/p/docker/docker-compose.local.yml")
        #expect(container?.composeWorkingDirectory == "/p/docker")
        #expect(container?.composeProject == "curator")
    }

    @Test("Several files means the first, which the rest override")
    func readsTheFirstOfSeveralConfigFiles() {
        let payload = """
        {"ID":"a","Names":"x","State":"running",\
        "Labels":"com.docker.compose.project.config_files=/p/compose.yaml,/p/compose.override.yaml"}
        """
        #expect(DockerProbe.parseContainers(payload).first?.composeConfigFile == "/p/compose.yaml")
    }

    @Test("A value containing an equals sign survives")
    func keepsValuesWithEquals() {
        #expect(DockerProbe.parseLabels("key=a=b")["key"] == "a=b")
    }

    @Test("Missing or malformed labels are tolerated")
    func toleratesGarbage() {
        #expect(DockerProbe.parseLabels(nil).isEmpty)
        #expect(DockerProbe.parseLabels("").isEmpty)
        #expect(DockerProbe.parseLabels("novalue").isEmpty)
    }
}


@Suite("Project containment")
struct DockerPathContainmentTests {
    @Test(
        "A directory inside the project belongs to it",
        arguments: [
            ("/Users/me/shop", "/Users/me/shop", true),
            ("/Users/me/shop/docker", "/Users/me/shop", true),
            ("/Users/me/shop/deploy/compose", "/Users/me/shop", true),
            ("/Users/me/shop/", "/Users/me/shop", true),
            ("/Users/me/other", "/Users/me/shop", false),
            ("/Users/me", "/Users/me/shop", false),
        ]
    )
    func containment(child: String, root: String, expected: Bool) {
        #expect(DockerProbe.isPath(child, inside: root) == expected)
    }

    @Test("A sibling whose name merely starts the same is not inside")
    func siblingPrefixIsNotContainment() {
        // `/Users/me/shop-staging` must not be claimed by `/Users/me/shop`.
        #expect(!DockerProbe.isPath("/Users/me/shop-staging", inside: "/Users/me/shop"))
    }

    @Test("Relative segments are resolved before comparing")
    func normalisesPaths() {
        #expect(DockerProbe.isPath("/Users/me/shop/./docker", inside: "/Users/me/shop"))
        #expect(DockerProbe.isPath("/Users/me/shop/deploy/../docker", inside: "/Users/me/shop"))
    }
}
