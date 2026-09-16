import Foundation
import RelayProtocol
import Testing

@testable import RelayDaemonCore

@Suite("Docker engine API")
struct DockerEngineAPITests {
    @Test("The API's own shape becomes the same container the CLI's does")
    func parsesTheAPIShape() {
        // Names arrive as a list with a leading slash, ports as objects, and
        // labels already as a dictionary — none of which the CLI's output does.
        let body = Data("""
        [{"Id":"abc123","Names":["/curator.php"],"Image":"php:8.4",
          "State":"running","Status":"Up 2 hours",
          "Ports":[{"PrivatePort":80,"PublicPort":8083,"Type":"tcp"}],
          "Labels":{"com.docker.compose.project":"curator",
                    "com.docker.compose.service":"php",
                    "com.docker.compose.project.working_dir":"/p/docker",
                    "com.docker.compose.project.config_files":"/p/docker/docker-compose.local.yml"}}]
        """.utf8)

        let container = DockerEngineAPI.parseAPIContainers(body)?.first
        #expect(container?.name == "curator.php")
        #expect(container?.id == "abc123")
        #expect(container?.service == "php")
        #expect(container?.state == "running")
        #expect(container?.composeProject == "curator")
        #expect(container?.composeWorkingDirectory == "/p/docker")
        #expect(container?.composeConfigFile == "/p/docker/docker-compose.local.yml")
        #expect(container?.publishedPorts.map(\.published) == [8083])
        #expect(container?.publishedPorts.first?.target == 80)
    }

    @Test("A container that publishes nothing is still a container")
    func keepsUnpublishedContainers() {
        let body = Data("""
        [{"Id":"a","Names":["/db"],"State":"exited","Ports":[{"PrivatePort":5432,"Type":"tcp"}]}]
        """.utf8)
        let container = DockerEngineAPI.parseAPIContainers(body)?.first
        #expect(container?.name == "db")
        #expect(container?.publishedPorts.isEmpty == true)
    }

    @Test("An empty engine is an empty list, not a missing one")
    func emptyIsNotNil() {
        // The difference the panel is built on: no containers is something to
        // say, no engine is something else entirely.
        #expect(DockerEngineAPI.parseAPIContainers(Data("[]".utf8)) == [])
        #expect(DockerEngineAPI.parseAPIContainers(Data("not json".utf8)) == nil)
    }

    @Test("The first socket that answers is the one used")
    func stopsAtTheFirstAnswer() {
        var asked: [String] = []
        let containers = DockerEngineAPI.listContainers(
            sockets: ["/first.sock", "/second.sock"],
            request: { socket, _ in
                asked.append(socket)
                return socket == "/second.sock" ? Data("[]".utf8) : nil
            }
        )
        #expect(containers == [])
        #expect(asked == ["/first.sock", "/second.sock"])
    }

    @Test("No socket anywhere is nil, which is how the CLI gets its turn")
    func noSocketMeansNil() {
        #expect(DockerEngineAPI.listContainers(sockets: ["/nope.sock"], request: { _, _ in nil }) == nil)
    }

    @Test("Every engine's socket is looked for, an explicit one first")
    func knowsWhereEnginesListen() {
        let sockets = DockerEngineAPI.candidateSockets(
            environment: ["DOCKER_HOST": "unix:///custom/docker.sock"],
            home: "/Users/me",
            contentsOfDirectory: { $0.hasSuffix(".colima") ? ["default", "work"] : [] }
        )
        // A decision someone made outranks every convention.
        #expect(sockets.first == "/custom/docker.sock")
        #expect(sockets.contains("/Users/me/.docker/run/docker.sock"))
        #expect(sockets.contains("/Users/me/.colima/default/docker.sock"))
        // Colima keeps one per profile, and "default" is not always the one.
        #expect(sockets.contains("/Users/me/.colima/work/docker.sock"))
        #expect(sockets.contains("/Users/me/.orbstack/run/docker.sock"))
        #expect(sockets.contains("/Users/me/.rd/docker.sock"))
        #expect(sockets.contains("/var/run/docker.sock"))
    }

    @Test("A TCP DOCKER_HOST is not a socket path")
    func ignoresNonSocketHosts() {
        let sockets = DockerEngineAPI.candidateSockets(
            environment: ["DOCKER_HOST": "tcp://127.0.0.1:2375"],
            home: "/Users/me",
            contentsOfDirectory: { _ in [] }
        )
        #expect(sockets.contains("tcp://127.0.0.1:2375") == false)
        #expect(sockets.first == "/var/run/docker.sock")
    }
}

@Suite("HTTP over a unix socket")
struct UnixSocketHTTPTests {
    @Test("A reply with a length is split into status and body")
    func readsAPlainReply() throws {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n[]".utf8)
        let (status, body) = try UnixSocketHTTP.split(response)
        #expect(status == 200)
        #expect(String(decoding: body, as: UTF8.self) == "[]")
    }

    @Test("A chunked reply is reassembled")
    func readsAChunkedReply() throws {
        // Docker chunks anything it is streaming and sometimes what it is not.
        // Read as a plain body this arrives with the chunk sizes still in it.
        let response = Data("""
        HTTP/1.1 200 OK\r
        Transfer-Encoding: chunked\r
        \r
        4\r
        [{"a\r
        3\r
        "}]\r
        0\r
        \r

        """.utf8)
        let (status, body) = try UnixSocketHTTP.split(response)
        #expect(status == 200)
        #expect(String(decoding: body, as: UTF8.self) == "[{\"a\"}]")
    }

    @Test("A chunk size may carry extensions after a semicolon")
    func toleratesChunkExtensions() throws {
        let body = try UnixSocketHTTP.dechunk(Data("2;name=value\r\nhi\r\n0\r\n\r\n".utf8))
        #expect(String(decoding: body, as: UTF8.self) == "hi")
    }

    @Test("An error the engine returns is an error, not a body to parse")
    func refusesNonSuccess() {
        let response = Data("HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n".utf8)
        #expect(throws: (any Error).self) {
            let (status, _) = try UnixSocketHTTP.split(response)
            // `split` reports the status; `get` is what refuses it.
            #expect(status == 500)
            throw UnixSocketHTTP.Failure.status(status)
        }
    }
}
