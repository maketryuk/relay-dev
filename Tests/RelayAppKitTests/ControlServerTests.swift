import Darwin
import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

/// The control socket as the `relay` command meets it: a real listener on a
/// throwaway path, spoken to by the client the command uses.
@Suite("Control socket", .serialized)
struct ControlServerTests {
    /// Short, because a socket's path has 104 bytes and a temporary
    /// directory's name uses most of them.
    private func socketPath() -> String {
        "/tmp/relay-ctl-\(UUID().uuidString.prefix(8)).sock"
    }

    private func server(at path: String, handler: @escaping ControlServer.Handler) throws -> ControlServer {
        let server = ControlServer(socketURL: URL(fileURLWithPath: path), handler: handler)
        try server.start()
        return server
    }

    private static let echo: ControlServer.Handler = { request in
        ControlResponse(project: ControlProject(id: request.sessionID ?? "", name: "echo", path: request.directory))
    }

    @Test("A request comes back answered by the handler")
    func requestAndResponse() throws {
        let path = socketPath()
        let server = try server(at: path, handler: Self.echo)
        defer { server.stop() }

        let request = ControlRequest(directory: "/Users/me/shop", sessionID: "S-7", command: .worktreeList)
        let response = try ControlClient.send(request, to: path, timeout: 5).get()
        #expect(response.ok)
        #expect(response.project == ControlProject(id: "S-7", name: "echo", path: "/Users/me/shop"))
    }

    @Test("Only this user may connect")
    func ownerOnly() throws {
        let path = socketPath()
        let server = try server(at: path, handler: Self.echo)
        defer { server.stop() }

        var status = stat()
        #expect(lstat(path, &status) == 0)
        #expect(status.st_mode & 0o777 == 0o600)
        #expect(status.st_uid == getuid())
    }

    @Test("A line that is not JSON is answered, not dropped")
    func badJSON() throws {
        let path = socketPath()
        let server = try server(at: path, handler: Self.echo)
        defer { server.stop() }

        let response = try answer(to: Data("this is not json\n".utf8), at: path)
        #expect(!response.ok)
        #expect(response.error?.code == .badRequest)
    }

    @Test("A command the app does not know is refused by name")
    func unknownCommand() throws {
        let path = socketPath()
        let server = try server(at: path, handler: Self.echo)
        defer { server.stop() }

        let line = #"{"version":1,"directory":"/","command":{"worktreeTeleport":{}}}"# + "\n"
        let response = try answer(to: Data(line.utf8), at: path)
        #expect(response.error?.code == .unknownCommand)
        #expect(response.error?.message.contains("worktreeTeleport") == true)
    }

    @Test("A line over the limit is refused before it is all read")
    func oversizedLine() throws {
        let path = socketPath()
        let server = try server(at: path, handler: Self.echo)
        defer { server.stop() }

        let flood = Data(repeating: UInt8(ascii: "a"), count: ControlProtocol.requestLimit + 4096)
        let response = try answer(to: flood, at: path)
        #expect(response.error?.code == .requestTooLarge)
    }

    @Test("A client that hangs up before it is answered does not take the app down")
    func clientHangsUp() throws {
        let path = socketPath()
        let server = try server(at: path, handler: Self.echo)
        defer { server.stop() }

        // What probing a socket for life does: connect and go. The answer to
        // that connection is written to nobody, which without SO_NOSIGPIPE on
        // the listener is a SIGPIPE and the end of the process.
        for _ in 0 ..< 3 {
            let probe = socket(AF_UNIX, SOCK_STREAM, 0)
            #expect(UnixSocketAddress.connect(probe, to: path))
            close(probe)
        }
        #expect(try ControlClient.send(ControlRequest(directory: "/", command: .worktreeList), to: path, timeout: 5).get().ok)
    }

    @Test("A request written a moment after connecting is waited for")
    func slowWriter() throws {
        let path = socketPath()
        let server = try server(at: path, handler: Self.echo)
        defer { server.stop() }

        // A connection inherits the listener's O_NONBLOCK on macOS; read as it
        // came, a request not there yet was "no request" at all.
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(client) }
        #expect(UnixSocketAddress.connect(client, to: path))
        usleep(200_000)
        let line = try ControlProtocol.encodeLine(ControlRequest(directory: "/late", command: .worktreeList))
        #expect(UnixSocketAddress.writeAll(line, to: client))

        var answer = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !answer.contains(MessageFraming.delimiter) {
            let count = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress, $0.count) }
            guard count > 0 else { break }
            answer.append(contentsOf: buffer[0 ..< count])
        }
        let response = try MessageFraming.makeDecoder().decode(ControlResponse.self, from: answer.dropLast())
        #expect(response.ok, "\(String(describing: response.error))")
        #expect(response.project?.path == "/late")
    }

    @Test("A socket left by a copy that crashed is taken over")
    func staleSocket() throws {
        let path = socketPath()
        // Bound and closed without being removed, as a crash leaves it.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(UnixSocketAddress.withAddress(of: path) { bind(stale, $0, $1) } == 0)
        close(stale)
        #expect(FileManager.default.fileExists(atPath: path))

        let server = try server(at: path, handler: Self.echo)
        defer { server.stop() }
        #expect(try ControlClient.send(ControlRequest(directory: "/", command: .worktreeList), to: path, timeout: 5).get().ok)
    }

    @Test("A socket another copy is listening on is left to it")
    func liveSocket() throws {
        let path = socketPath()
        let first = try server(at: path, handler: Self.echo)
        defer { first.stop() }

        let second = ControlServer(socketURL: URL(fileURLWithPath: path), handler: Self.echo)
        #expect(throws: ControlServer.StartError.self) { try second.start() }
        #expect(try ControlClient.send(ControlRequest(directory: "/", command: .worktreeList), to: path, timeout: 5).get().ok)
    }

    @Test("Stopping takes the socket away, and the command then says Relay is not running")
    func stopRemovesSocket() throws {
        let path = socketPath()
        let server = try server(at: path, handler: Self.echo)
        server.stop()

        #expect(!FileManager.default.fileExists(atPath: path))
        let result = ControlClient.send(ControlRequest(directory: "/", command: .worktreeList), to: path, timeout: 1)
        #expect(result == .failure(.notRunning(socket: path)))
    }

    @Test("A handler that takes its time is waited for, and others are answered meanwhile")
    func slowHandlerDoesNotBlockOthers() async throws {
        let path = socketPath()
        let gate = Gate()
        let server = try server(at: path) { request in
            if request.sessionID == "slow" { await gate.wait() }
            return ControlResponse(project: ControlProject(id: request.sessionID ?? "", name: "", path: ""))
        }
        defer { server.stop() }

        let slow = Task.detached {
            ControlClient.send(ControlRequest(directory: "/", sessionID: "slow", command: .worktreeList), to: path, timeout: 10)
        }
        let quick = ControlClient.send(ControlRequest(directory: "/", sessionID: "quick", command: .worktreeList), to: path, timeout: 5)
        #expect(try quick.get().project?.id == "quick")
        await gate.open()
        #expect(try await slow.value.get().project?.id == "slow")
    }

    /// Sends bytes as they are, as no command would.
    private func answer(to bytes: Data, at path: String) throws -> ControlResponse {
        let line = try ControlClient.exchange(bytes, with: path, timeout: 5).get()
        return try MessageFraming.makeDecoder().decode(ControlResponse.self, from: line)
    }
}

private actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}
