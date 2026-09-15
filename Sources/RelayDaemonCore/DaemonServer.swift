import Darwin
import Foundation
import RelayProtocol

/// Owns every session and every connected client.
///
/// This is the "runtime state is the source of truth" half of the architecture:
/// the GUI persists configuration, the daemon persists nothing and simply keeps
/// processes alive across GUI restarts.
public final class DaemonServer: @unchecked Sendable {
    public static let version = RelayVersion.current

    /// How often live sessions are re-classified. Cheap enough to be invisible
    /// and only scheduled while at least one session is running.
    private static let tickInterval: TimeInterval = 0.35
    /// Exiting after the last client disconnects would defeat the entire point
    /// of the daemon, so it only exits when it has nothing left to supervise.
    private static let idleShutdownDelay: TimeInterval = 60 * 30
    /// How long a port scan stays fresh. Long enough to make repeated popover
    /// opens free, short enough that a just-started dev server shows up.
    private static let portCacheLifetime: TimeInterval = 2.0
    private static let dockerCacheLifetime: TimeInterval = 4.0

    private var listener: SocketListener?
    private var sessions: [SessionID: SessionRuntime] = [:]
    private var sessionOrder: [SessionID] = []
    private var clients: [UInt64: ClientConnection] = [:]
    private var nextClientID: UInt64 = 1
    private var ticker: DispatchSourceTimer?
    private var portCache: [ProjectID: (timestamp: Date, ports: [ListeningPort])] = [:]
    private var dockerCache: [String: (timestamp: Date, snapshot: DockerSnapshot)] = [:]
    private let commandRunner: any CommandRunning = SystemCommandRunner()
    private var idleTimer: DispatchSourceTimer?
    private let startedAt = Date()
    private let socketURL: URL
    private let logURL: URL

    /// The socket path is injectable so tests can run a real daemon on a
    /// throwaway path without colliding with the user's live one.
    /// Invoked when the daemon has finished tearing down and the process should
    /// end. Exiting is the entry point's decision, not the server's — otherwise
    /// the server could not be hosted inside another process, including tests.
    public var onExitRequested: (@Sendable () -> Void)?

    public init(socketURL: URL = RelayPaths.socketURL, logURL: URL = RelayPaths.daemonLogURL) {
        self.socketURL = socketURL
        self.logURL = logURL
    }

    // MARK: - Server lifecycle

    public func start() throws {
        DaemonLog.shared.open(url: logURL)
        try RelayPaths.ensureDirectories()

        let listener = SocketListener(url: socketURL) { [weak self] descriptor in
            self?.acceptClient(descriptor: descriptor)
        }
        try listener.start()
        self.listener = listener
        DaemonLog.shared.write("daemon \(Self.version) listening on \(socketURL.path)")
        scheduleIdleShutdownCheck()
    }

    /// Safe to call from any queue.
    public func shutdown() {
        if DispatchQueue.getSpecific(key: DaemonQueue.identityKey) != nil {
            performShutdown()
        } else {
            DaemonQueue.shared.sync { performShutdown() }
        }
        DaemonLog.shared.write("daemon stopped")
    }

    private func performShutdown() {
        DaemonQueue.assertIsolated()
        broadcast(.daemonStopping)
        for session in sessions.values {
            session.tearDown()
        }
        sessions.removeAll()
        sessionOrder.removeAll()
        for client in clients.values {
            client.close()
        }
        listener?.stop()
    }

    // MARK: - Clients

    private func acceptClient(descriptor: Int32) {
        DaemonQueue.assertIsolated()
        let identifier = nextClientID
        nextClientID += 1

        let connection = ClientConnection(
            id: identifier,
            descriptor: descriptor,
            onMessage: { [weak self] client, message in
                self?.handle(message: message, from: client)
            },
            onClose: { [weak self] client in
                self?.clients.removeValue(forKey: client.id)
                DaemonLog.shared.write("client \(client.id) disconnected")
            }
        )
        clients[identifier] = connection
        connection.start()
        DaemonLog.shared.write("client \(identifier) connected")
    }

    private func broadcast(_ event: DaemonEvent) {
        DaemonQueue.assertIsolated()
        for client in clients.values {
            client.send(.event(event))
        }
    }

    /// Output only goes to clients that asked for it.
    private func broadcastOutput(_ sessionID: SessionID, _ data: Data) {
        DaemonQueue.assertIsolated()
        for client in clients.values where client.attachedSessions.contains(sessionID) {
            client.send(.event(.output(sessionID, data)))
        }
    }

    private func broadcastSnapshot(_ sessionID: SessionID) {
        DaemonQueue.assertIsolated()
        guard let session = sessions[sessionID] else { return }
        broadcast(.sessionUpdated(session.snapshot()))
    }

    // MARK: - Request routing

    private func handle(message: ClientMessage, from client: ClientConnection) {
        DaemonQueue.assertIsolated()
        do {
            let reply = try perform(message.request, for: client)
            client.send(.reply(requestID: message.requestID, reply))
        } catch let error as DaemonError {
            client.send(.failure(requestID: message.requestID, error))
        } catch {
            client.send(.failure(
                requestID: message.requestID,
                DaemonError(code: "internal", message: String(describing: error))
            ))
        }
    }

    private func perform(_ request: DaemonRequest, for client: ClientConnection) throws -> DaemonReply {
        switch request {
        case let .handshake(protocolVersion, clientName):
            guard protocolVersion == RelayProtocolVersion.current else {
                throw DaemonError.protocolMismatch(protocolVersion)
            }
            client.didHandshake = true
            DaemonLog.shared.write("client \(client.id) handshake as \(clientName)")
            return pong()

        case .ping:
            return pong()

        case .listSessions:
            return .sessions(sessionOrder.compactMap { sessions[$0]?.snapshot() })

        case let .listPorts(projectID):
            return .ports(listPorts(for: projectID))

        case let .dockerStatus(projectDirectory):
            return .docker(dockerStatus(for: projectDirectory))

        case let .dockerCommand(projectDirectory, arguments):
            return runDockerCommand(projectDirectory: projectDirectory, arguments: arguments)

        case let .terminateProcess(pid, force):
            return terminateProcess(pid: pid, force: force)

        case let .createSession(spec):
            let session = try createSession(spec: spec)
            return .session(session)

        case let .attach(sessionID, replayScrollback):
            guard let session = sessions[sessionID] else { throw DaemonError.unknownSession(sessionID) }
            client.attachedSessions.insert(sessionID)
            if replayScrollback, !session.scrollback.isEmpty {
                client.send(.event(.output(sessionID, session.scrollback.bytes)))
            }
            return .session(session.snapshot())

        case let .detach(sessionID):
            client.attachedSessions.remove(sessionID)
            return .ok

        case let .input(sessionID, data):
            guard let session = sessions[sessionID] else { throw DaemonError.unknownSession(sessionID) }
            let previousStatus = session.snapshot().status
            session.write(data)
            if session.snapshot().status != previousStatus {
                broadcastSnapshot(sessionID)
            }
            return .ok

        case let .resize(sessionID, columns, rows):
            guard let session = sessions[sessionID] else { throw DaemonError.unknownSession(sessionID) }
            session.resize(columns: columns, rows: rows)
            return .ok

        case let .rename(sessionID, name):
            guard let session = sessions[sessionID] else { throw DaemonError.unknownSession(sessionID) }
            session.rename(to: name)
            broadcastSnapshot(sessionID)
            return .session(session.snapshot())

        case let .terminate(sessionID):
            guard let session = sessions[sessionID] else { throw DaemonError.unknownSession(sessionID) }
            session.terminate()
            return .ok

        case let .forget(sessionID):
            guard let session = sessions[sessionID] else { throw DaemonError.unknownSession(sessionID) }
            session.tearDown()
            sessions.removeValue(forKey: sessionID)
            sessionOrder.removeAll { $0 == sessionID }
            for connection in clients.values {
                connection.attachedSessions.remove(sessionID)
            }
            broadcast(.sessionRemoved(sessionID))
            updateTicker()
            return .ok

        case .shutdownDaemon:
            // Reply first, then stop: the client is usually waiting to relaunch
            // a newer daemon on the same socket.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self else { return }
                self.shutdown()
                self.onExitRequested?()
            }
            return .ok
        }
    }

    private func pong() -> DaemonReply {
        .pong(
            daemonVersion: Self.version,
            protocolVersion: RelayProtocolVersion.current,
            buildIdentity: BuildIdentity.current,
            uptime: Date().timeIntervalSince(startedAt)
        )
    }

    // MARK: - Sessions

    private func createSession(spec: SessionSpec) throws -> SessionSnapshot {
        DaemonQueue.assertIsolated()
        let identifier = SessionID.generate()
        let runtime = SessionRuntime(id: identifier, spec: spec)

        do {
            try runtime.start(
                onOutput: { [weak self] sessionID, data in
                    self?.broadcastOutput(sessionID, data)
                },
                onChange: { [weak self] sessionID in
                    self?.broadcastSnapshot(sessionID)
                }
            )
        } catch {
            throw DaemonError.spawnFailed(String(describing: error))
        }

        sessions[identifier] = runtime
        sessionOrder.append(identifier)
        let snapshot = runtime.snapshot()
        broadcast(.sessionCreated(snapshot))
        DaemonLog.shared.write("session \(identifier) started: \(spec.kind.rawValue) in \(spec.workingDirectory)")
        updateTicker()
        return snapshot
    }

    // MARK: - Ports

    /// Ports are resolved on demand and cached briefly: the scan spawns `ps` and
    /// `lsof`, which is far too expensive to run on a timer.
    ///
    /// The whole machine is scanned, not just this project. A developer looking
    /// at a port list wants to know what is on 3000 regardless of who started
    /// it; ports Relay owns are attributed, the rest are reported as-is.
    private func listPorts(for projectID: ProjectID) -> [ListeningPort] {
        DaemonQueue.assertIsolated()
        if let cached = portCache[projectID], Date().timeIntervalSince(cached.timestamp) < Self.portCacheLifetime {
            return cached.ports
        }

        var ports = PortScanner.scanAll(runner: commandRunner)
        let parents = PortScanner.processParents(runner: commandRunner)

        // Map every live session's pid back to its session so a listener several
        // forks deep can still be named.
        var sessionByPID: [Int32: SessionRuntime] = [:]
        for identifier in sessionOrder {
            guard let session = sessions[identifier], session.isAlive,
                  let pid = session.snapshot().pid
            else { continue }
            sessionByPID[pid] = session
        }
        let candidates = Set(sessionByPID.keys)

        // One syscall per port; the answer is what tells two `node` servers
        // apart.
        var directories: [Int32: String] = [:]
        for port in ports where directories[port.pid] == nil {
            directories[port.pid] = PortScanner.workingDirectory(of: port.pid) ?? ""
        }

        for index in ports.indices {
            let directory = directories[ports[index].pid]
            ports[index].workingDirectory = directory?.isEmpty == true ? nil : directory

            guard let ancestor = PortScanner.nearestAncestor(
                of: ports[index].pid,
                among: candidates,
                parents: parents
            ), let owner = sessionByPID[ancestor] else { continue }

            let snapshot = owner.snapshot()
            ports[index].ownerSessionID = owner.id
            ports[index].ownerName = snapshot.displayName
            ports[index].ownerProjectID = snapshot.projectID
        }

        portCache[projectID] = (Date(), ports)
        return ports
    }

    /// Stops a process the ports list is showing.
    ///
    /// Polite first: a dev server asked to stop usually wants to clean up after
    /// itself. The caller decides whether to escalate, because killing outright
    /// is a different act from asking.
    private func terminateProcess(pid: Int32, force: Bool) -> DaemonReply {
        DaemonQueue.assertIsolated()
        guard pid > 1 else {
            return .commandOutput(status: 1, output: "Refusing to signal pid \(pid)")
        }
        guard kill(pid, 0) == 0 else {
            return .commandOutput(status: 1, output: "No process with pid \(pid)")
        }

        let signalNumber = force ? SIGKILL : SIGTERM
        // The whole group, so a shell wrapper does not leave its child behind.
        _ = killpg(getpgid(pid), signalNumber)
        let result = kill(pid, signalNumber)
        portCache.removeAll()

        guard result == 0 else {
            return .commandOutput(status: 1, output: String(cString: strerror(errno)))
        }
        return .commandOutput(status: 0, output: "")
    }

    // MARK: - Docker

    /// Compose status is cached like ports are: the CLI round trip is slow and
    /// the sidebar asks for it whenever the project changes.
    private func dockerStatus(for projectDirectory: String) -> DockerSnapshot {
        DaemonQueue.assertIsolated()
        if let cached = dockerCache[projectDirectory],
           Date().timeIntervalSince(cached.timestamp) < Self.dockerCacheLifetime {
            return cached.snapshot
        }
        let snapshot = DockerProbe.snapshot(projectDirectory: projectDirectory, runner: commandRunner)
        dockerCache[projectDirectory] = (Date(), snapshot)
        return snapshot
    }

    /// Runs a short docker command and invalidates the cached status, so the
    /// sidebar reflects the change on its next refresh.
    ///
    /// Starting and stopping a container does not deserve a terminal session:
    /// it finishes in a second and leaves nothing worth reading behind. Logs,
    /// which do, still open as a session.
    private func runDockerCommand(projectDirectory: String, arguments: [String]) -> DaemonReply {
        DaemonQueue.assertIsolated()
        guard let dockerPath = DockerProbe.locateDockerCLI() else {
            return .commandOutput(status: 127, output: "Docker CLI not found")
        }
        let result = commandRunner.run(dockerPath, arguments: arguments, timeout: 30)
        dockerCache.removeValue(forKey: projectDirectory)

        guard let result else {
            return .commandOutput(status: 127, output: "Could not run the Docker CLI")
        }
        let output = result.succeeded
            ? result.standardOutput
            : (result.standardError.isEmpty ? result.standardOutput : result.standardError)
        return .commandOutput(status: result.status, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Timers

    /// The classification timer only runs while something is alive, keeping the
    /// daemon at zero CPU when the user is not working.
    private func updateTicker() {
        DaemonQueue.assertIsolated()
        let hasLiveSessions = sessions.values.contains { $0.isAlive }
        if hasLiveSessions, ticker == nil {
            let timer = DispatchSource.makeTimerSource(queue: DaemonQueue.shared)
            timer.schedule(deadline: .now() + Self.tickInterval, repeating: Self.tickInterval, leeway: .milliseconds(80))
            timer.setEventHandler { [weak self] in self?.tick() }
            ticker = timer
            timer.resume()
        } else if !hasLiveSessions, ticker != nil {
            ticker?.cancel()
            ticker = nil
        }
    }

    private func tick() {
        DaemonQueue.assertIsolated()
        let now = Date()
        for identifier in sessionOrder {
            guard let session = sessions[identifier] else { continue }
            if session.reclassifyIfQuiet(now: now) {
                broadcast(.sessionUpdated(session.snapshot()))
            }
        }
        updateTicker()
    }

    private func scheduleIdleShutdownCheck() {
        let timer = DispatchSource.makeTimerSource(queue: DaemonQueue.shared)
        timer.schedule(
            deadline: .now() + Self.idleShutdownDelay,
            repeating: Self.idleShutdownDelay,
            leeway: .seconds(30)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.clients.isEmpty, self.sessions.isEmpty else { return }
            DaemonLog.shared.write("no clients and no sessions for \(Int(Self.idleShutdownDelay))s, exiting")
            self.shutdown()
            self.onExitRequested?()
        }
        idleTimer = timer
        timer.resume()
    }
}
