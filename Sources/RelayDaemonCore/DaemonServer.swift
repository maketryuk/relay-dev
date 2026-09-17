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
    /// Long enough for a first `compose up` to pull its images.
    private static let dockerCommandTimeout: TimeInterval = 150

    private var listener: SocketListener?
    private var sessions: [SessionID: SessionRuntime] = [:]
    private var sessionOrder: [SessionID] = []
    private var clients: [UInt64: ClientConnection] = [:]
    private var nextClientID: UInt64 = 1
    private var ticker: DispatchSourceTimer?
    private var portCache: (timestamp: Date, ports: [ListeningPort])?
    private var portWaiters: [(clientID: UInt64, requestID: UInt64)] = []
    private var isScanningPorts = false
    private var dockerCache: [String: (timestamp: Date, snapshot: DockerSnapshot)] = [:]
    private var dockerWaiters: [String: [(clientID: UInt64, requestID: UInt64)]] = [:]
    private let commandRunner: any CommandRunning
    /// Everything that shells out runs here, never on `DaemonQueue.shared`.
    ///
    /// That queue carries PTY output, keystrokes and session creation. `lsof`
    /// takes a moment, `docker ps` takes seconds when the engine is starting,
    /// and `docker compose up` can take minutes — run inline, each of them
    /// froze every terminal in the app for its whole duration, which is how a
    /// new session came to sit at "Starting" with a blank screen for a minute.
    private let commandQueue = DispatchQueue(
        label: "com.maketryuk.relay.daemon.commands",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var idleTimer: DispatchSourceTimer?
    private let startedAt = Date()
    private let socketURL: URL
    private let logURL: URL

    /// The socket path and the command runner are injectable so tests can run a
    /// real daemon on a throwaway path, and can make `lsof` or `docker` take as
    /// long as they like without depending on the machine underneath.
    /// Invoked when the daemon has finished tearing down and the process should
    /// end. Exiting is the entry point's decision, not the server's — otherwise
    /// the server could not be hosted inside another process, including tests.
    public var onExitRequested: (@Sendable () -> Void)?

    public init(
        socketURL: URL = RelayPaths.socketURL,
        logURL: URL = RelayPaths.daemonLogURL,
        commandRunner: any CommandRunning = SystemCommandRunner()
    ) {
        self.socketURL = socketURL
        self.logURL = logURL
        self.commandRunner = commandRunner
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
        // Read now rather than at the first handshake. An update deletes the
        // bundle this daemon was started from while it keeps running, and a
        // hash taken afterwards is "unknown" — which reads to the new GUI as a
        // daemon it cannot identify, exactly when it is deciding whether the
        // sessions inside it can be kept.
        DaemonLog.shared.write(
            "daemon \(Self.version) (\(BuildIdentity.current)) listening on \(socketURL.path)"
        )
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
            // A `nil` reply means the request had to shell out: it answers
            // itself once the command returns, from another queue.
            guard let reply = try perform(message.request, requestID: message.requestID, for: client) else { return }
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

    private func perform(
        _ request: DaemonRequest,
        requestID: UInt64,
        for client: ClientConnection
    ) throws -> DaemonReply? {
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

        case .listPorts:
            beginPortScan(requestID: requestID, for: client)
            return nil

        case let .dockerStatus(projectDirectory):
            beginDockerStatus(projectDirectory: projectDirectory, requestID: requestID, for: client)
            return nil

        case let .dockerCommand(projectDirectory, arguments):
            beginDockerCommand(
                projectDirectory: projectDirectory,
                arguments: arguments,
                requestID: requestID,
                for: client
            )
            return nil

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

    /// Ports are scanned on demand, off the daemon queue, and cached briefly.
    ///
    /// The whole machine is scanned, not just the project in front of the user:
    /// the question a developer has is "what is on 3000", and the answer is just
    /// as often a server they started elsewhere. That also means the result does
    /// not depend on who asked, so one scan answers everyone waiting for it —
    /// which matters, because the ports window rescans itself while it is open.
    private func beginPortScan(requestID: UInt64, for client: ClientConnection) {
        DaemonQueue.assertIsolated()
        if let cached = portCache, Date().timeIntervalSince(cached.timestamp) < Self.portCacheLifetime {
            client.send(.reply(requestID: requestID, .ports(cached.ports)))
            return
        }

        portWaiters.append((client.id, requestID))
        guard !isScanningPorts else { return }
        isScanningPorts = true

        // Session ownership is daemon state, so it is read here; the forks it
        // takes to turn that into a port list happen elsewhere.
        let owners = livePortOwners()
        let runner = commandRunner
        commandQueue.async { [weak self] in
            let ports = PortScanner.survey(runner: runner, owners: owners)
            guard let self else { return }
            DaemonQueue.shared.async { self.finishPortScan(ports) }
        }
    }

    private func livePortOwners() -> [PortScanner.PortOwner] {
        DaemonQueue.assertIsolated()
        return sessionOrder.compactMap { identifier in
            guard let session = sessions[identifier], session.isAlive else { return nil }
            let snapshot = session.snapshot()
            guard let pid = snapshot.pid else { return nil }
            return PortScanner.PortOwner(
                pid: pid,
                sessionID: session.id,
                name: snapshot.displayName,
                projectID: snapshot.projectID
            )
        }
    }

    private func finishPortScan(_ ports: [ListeningPort]) {
        DaemonQueue.assertIsolated()
        isScanningPorts = false
        portCache = (Date(), ports)
        let waiting = portWaiters
        portWaiters.removeAll()
        for waiter in waiting {
            clients[waiter.clientID]?.send(.reply(requestID: waiter.requestID, .ports(ports)))
        }
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
        portCache = nil

        guard result == 0 else {
            return .commandOutput(status: 1, output: String(cString: strerror(errno)))
        }
        return .commandOutput(status: 0, output: "")
    }

    // MARK: - Docker

    /// Compose status is cached like ports are, and read off the daemon queue
    /// for the same reason: a `docker` call against an engine that is still
    /// starting up takes seconds to answer.
    private func beginDockerStatus(projectDirectory: String, requestID: UInt64, for client: ClientConnection) {
        DaemonQueue.assertIsolated()
        if let cached = dockerCache[projectDirectory],
           Date().timeIntervalSince(cached.timestamp) < Self.dockerCacheLifetime {
            client.send(.reply(requestID: requestID, .docker(cached.snapshot)))
            return
        }

        let alreadyProbing = dockerWaiters[projectDirectory] != nil
        dockerWaiters[projectDirectory, default: []].append((client.id, requestID))
        guard !alreadyProbing else { return }

        let runner = commandRunner
        commandQueue.async { [weak self] in
            let snapshot = DockerProbe.snapshot(projectDirectory: projectDirectory, runner: runner)
            guard let self else { return }
            DaemonQueue.shared.async {
                self.finishDockerStatus(projectDirectory: projectDirectory, snapshot: snapshot)
            }
        }
    }

    private func finishDockerStatus(projectDirectory: String, snapshot: DockerSnapshot) {
        DaemonQueue.assertIsolated()
        dockerCache[projectDirectory] = (Date(), snapshot)
        let waiting = dockerWaiters.removeValue(forKey: projectDirectory) ?? []
        for waiter in waiting {
            clients[waiter.clientID]?.send(.reply(requestID: waiter.requestID, .docker(snapshot)))
        }
    }

    /// Runs a short docker command and invalidates the cached status, so the
    /// sidebar reflects the change on its next refresh.
    ///
    /// Starting and stopping a container does not deserve a terminal session:
    /// it finishes in a second and leaves nothing worth reading behind. Logs,
    /// which do, still open as a session.
    private func beginDockerCommand(
        projectDirectory: String,
        arguments: [String],
        requestID: UInt64,
        for client: ClientConnection
    ) {
        DaemonQueue.assertIsolated()
        guard let dockerPath = DockerProbe.locateDockerCLI() else {
            client.send(.reply(requestID: requestID, .commandOutput(status: 127, output: "Docker CLI not found")))
            return
        }

        let clientID = client.id
        let runner = commandRunner
        commandQueue.async { [weak self] in
            // Generous, because the first `compose up` of a stack pulls images.
            // Nothing waits on this but the button that started it.
            let result = runner.run(dockerPath, arguments: arguments, timeout: Self.dockerCommandTimeout)
            let reply: DaemonReply
            if let result {
                let output = result.succeeded
                    ? result.standardOutput
                    : (result.standardError.isEmpty ? result.standardOutput : result.standardError)
                reply = .commandOutput(
                    status: result.status,
                    output: output.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } else {
                reply = .commandOutput(status: 127, output: "Could not run the Docker CLI")
            }

            guard let self else { return }
            DaemonQueue.shared.async {
                // Dropped here rather than before the command, so a status probe
                // that overlapped it cannot leave a pre-command snapshot cached.
                self.dockerCache.removeValue(forKey: projectDirectory)
                self.clients[clientID]?.send(.reply(requestID: requestID, reply))
            }
        }
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
            if session.reclassify(now: now) {
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
