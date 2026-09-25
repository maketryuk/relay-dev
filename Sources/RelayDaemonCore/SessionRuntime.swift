import Foundation
import RelayProtocol

/// One live session: its PTY child, its history, and its derived status.
///
/// Every method must be called on `DaemonQueue.shared`.
public final class SessionRuntime: @unchecked Sendable {
    /// Grace period between SIGHUP and SIGKILL. Agents that trap SIGHUP to save
    /// state get a chance to do so; ones that ignore it still go away.
    private static let terminationGrace: TimeInterval = 3.0
    /// Output below this many bytes since the last command is assumed to be
    /// the interface redrawing rather than real work.
    private static let meaningfulOutputBytes = 120
    /// Output this soon after a key that edits a line is the key's echo, or
    /// the input box it was typed into redrawing — never work.
    private static let echoWindow: TimeInterval = 0.25
    /// How much raw output the classifier looks at.
    private static let recentBytesCapacity = 8 * 1024

    public let id: SessionID
    public private(set) var spec: SessionSpec
    public private(set) var status: RuntimeStatus
    public private(set) var pid: Int32?
    public private(set) var exitCode: Int32?
    public private(set) var scrollback: ScrollbackBuffer

    private let startedAt: Date
    private let adapter: any ActivityAdapter
    private var process: PTYProcess?
    private var activity: ActivityWindow
    private var lastActivityAt: Date
    private var needsReclassification = false
    private var bytesSinceUserInput = 0
    /// Raw tail kept for classification. Escape processing is deliberately
    /// deferred until a verdict is needed: applying it per chunk would make
    /// carriage-return collapsing depend on how the PTY happened to split the
    /// stream, and the same output could then classify differently run to run.
    private var recentBytes = Data()
    private var titleParser = TerminalTitleParser()
    private var agentStatus = AgentStatusTracker()
    private var lastEditAt = Date.distantPast
    private var reportedTitle: String?
    private var isNameUserDefined = false
    private var hasReceivedUserInput = false
    private var isTerminatingByRequest = false
    private var columns: Int
    private var rows: Int

    public init(id: SessionID, spec: SessionSpec, scrollbackCapacity: Int = 512 * 1024) {
        self.id = id
        self.spec = spec
        status = .starting
        scrollback = ScrollbackBuffer(capacity: scrollbackCapacity)
        adapter = ActivityAdapters.adapter(for: spec.kind)
        startedAt = Date()
        activity = ActivityWindow(startedAt: startedAt)
        lastActivityAt = startedAt
        columns = spec.columns
        rows = spec.rows
    }

    /// Whether the child process is still running. Deliberately independent
    /// from `status`: an agent that reports `.finished` after completing a task
    /// is still alive and can accept the next prompt.
    public var isAlive: Bool { process != nil }

    public func snapshot() -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            projectID: spec.projectID,
            kind: spec.kind,
            name: spec.name,
            workingDirectory: spec.workingDirectory,
            command: spec.command,
            status: status,
            pid: pid,
            exitCode: exitCode,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            columns: columns,
            rows: rows,
            role: spec.role,
            title: reportedTitle,
            isNameUserDefined: isNameUserDefined,
            hostsAgent: spec.kind.isAgent || agentStatus.hasEvidence
        )
    }

    // MARK: - Lifecycle

    /// - Parameter hookEnvironment: what an agent's hooks need to find the
    ///   daemon and the `relay` command needs to find the app, handed to the
    ///   terminal along with this session's id.
    public func start(
        hookEnvironment: [String: String] = [:],
        onOutput: @escaping @Sendable (SessionID, Data) -> Void,
        onChange: @escaping @Sendable (SessionID) -> Void
    ) throws {
        DaemonQueue.assertIsolated()
        var plan = LaunchPlanBuilder.makePlan(for: spec)
        plan.environment = LaunchPlanBuilder.environment(plan.environment, telling: hookEnvironment, session: id)
        let child = try PTYProcess.launch(plan)
        process = child
        pid = child.pid
        status = .starting

        let identifier = id
        child.startStreaming(
            onOutput: { [weak self] data in
                guard let self else { return }
                self.ingest(output: data)
                onOutput(identifier, data)
                onChange(identifier)
            },
            onExit: { [weak self] code in
                guard let self else { return }
                self.handleExit(code: code)
                onChange(identifier)
            }
        )
    }

    public func write(_ data: Data) {
        DaemonQueue.assertIsolated()
        guard let process else { return }
        process.write(data)
        let now = Date()
        needsReclassification = true
        // What the terminal redraws in answer to a key is judged on its own
        // rather than as the tail of whatever came before it.
        activity.noteUserInput(at: now)
        lastActivityAt = now
        agentStatus.noteInput(data, at: now)

        // A key is not a command. Every letter typed into an agent's prompt
        // used to mark it working, and the prompt redrawing around the letter
        // then read as work done — so typing a question turned the session
        // "Working" and then "Finished" before it was sent. Only a submitted
        // line hands control to the process.
        guard Self.submits(data) else {
            lastEditAt = now
            return
        }
        hasReceivedUserInput = true
        bytesSinceUserInput = 0
        if isAlive, !agentStatus.isAuthoritative(now: now) {
            status = .working
        }
    }

    static func submits(_ data: Data) -> Bool {
        data.contains(0x0D) || data.contains(0x0A)
    }

    /// Whether an agent's hook has reached this session yet.
    public private(set) var hasHeardFromHooks = false

    /// Applies what an agent's hook reported. Returns `true` when the status
    /// changed and observers should be notified.
    public func apply(hook event: AgentHookEvent, now: Date = Date()) -> Bool {
        DaemonQueue.assertIsolated()
        guard isAlive, let pid, event.comesFromSessionAgent(sessionPID: pid) else { return false }
        hasHeardFromHooks = true
        agentStatus.apply(event, at: now)
        lastActivityAt = now
        return reclassify(now: now)
    }

    public func resize(columns newColumns: Int, rows newRows: Int) {
        DaemonQueue.assertIsolated()
        columns = max(1, newColumns)
        rows = max(1, newRows)
        process?.resize(columns: columns, rows: rows)
    }

    public func rename(to name: String) {
        DaemonQueue.assertIsolated()
        spec.name = name
        // From now on the program's own title stops overriding the user.
        isNameUserDefined = true
    }

    public func terminate() {
        DaemonQueue.assertIsolated()
        // Remember that this exit was asked for, so the non-zero status a
        // SIGHUP-ed shell returns is not reported to the user as a failure.
        isTerminatingByRequest = true
        process?.terminate()

        DaemonQueue.shared.asyncAfter(deadline: .now() + Self.terminationGrace) { [weak self] in
            guard let self, let process = self.process, process.isRunning else { return }
            process.forceKill()
        }
    }

    public func forceKill() {
        DaemonQueue.assertIsolated()
        process?.forceKill()
    }

    public func tearDown() {
        DaemonQueue.assertIsolated()
        process?.forceKill()
        // Reaped, because cancelling the exit source removes the only place
        // `waitpid` was being called and the child would linger as a zombie for
        // as long as the daemon lives — but reaped elsewhere, because waiting
        // for it here holds up every other session's output.
        process?.reapDetached()
        process?.close()
        process = nil
    }

    // MARK: - Status derivation

    private func ingest(output data: Data) {
        let now = Date()
        scrollback.append(data)
        if now.timeIntervalSince(lastEditAt) > Self.echoWindow {
            bytesSinceUserInput += data.count
        }
        activity.noteOutput(at: now)
        lastActivityAt = now
        needsReclassification = true
        // Deliberately does not declare the session busy. A terminal interface
        // repaints while doing nothing at all, and calling every byte "working"
        // made an idle agent flicker between Working and Idle forever. Whether
        // this output is work is decided on the tick, by how long it lasts.

        let titles = titleParser.consumeTitles(data)
        for title in titles {
            agentStatus.noteTitle(title, at: now)
        }
        if let title = titles.compactMap(TerminalTitleParser.sanitise).last, title != reportedTitle {
            reportedTitle = title
        }

        recentBytes.append(data)
        if recentBytes.count > Self.recentBytesCapacity {
            recentBytes.discardFirst(recentBytes.count - Self.recentBytesCapacity)
        }
    }

    /// Whether nothing but the session's own shell is running in it: the
    /// terminal's foreground process group is the one the shell leads.
    private var isShellInForeground: Bool {
        guard let process, let pid else { return false }
        let foreground = tcgetpgrp(process.masterFD)
        return foreground > 0 && foreground == pid
    }

    private func handleExit(code: Int32) {
        exitCode = code
        status = (code == 0 || isTerminatingByRequest) ? .finished : .error
        lastActivityAt = Date()
        needsReclassification = false
        process?.close()
        process = nil
    }

    /// Called periodically while the session is alive. Returns `true` when the
    /// status changed and observers should be notified.
    public func reclassify(now: Date) -> Bool {
        DaemonQueue.assertIsolated()
        guard isAlive else { return false }

        // An agent started from a shell leaves its last words behind when it
        // quits; the shell taking the terminal back is what says it has gone.
        if agentStatus.hasEvidence, !spec.kind.isAgent, isShellInForeground {
            agentStatus.forgetAgent()
        }
        if let reported = agentStatus.status(now: now) {
            guard reported != status else { return false }
            status = reported
            return true
        }

        let tail = TerminalText.tail(of: TerminalText.plainText(from: recentBytes))

        // What the agent says about itself beats anything inferred from the
        // timing of bytes: every one of them offers a way to interrupt while it
        // is busy, and a spinner that redraws slowly is still a working agent.
        if adapter.isBusy(tail: tail) {
            guard status != .working else { return false }
            status = .working
            return true
        }

        // Failing that, a sustained run of output is work and anything shorter
        // is the interface redrawing itself.
        if activity.isProducingOutput(now: now) {
            guard activity.isWorking(now: now), status != .working else { return false }
            status = .working
            return true
        }

        guard needsReclassification else { return false }
        needsReclassification = false
        // A banner printed by .zshrc on startup is not work the user asked for,
        // so a session that has never been typed into can only be idle.
        let producedOutput = hasReceivedUserInput && bytesSinceUserInput >= Self.meaningfulOutputBytes
        let verdict = adapter.verdict(tail: tail, producedOutput: producedOutput)

        let resolved: RuntimeStatus = switch verdict {
        case .waitingForUser: .waiting
        case .completed: .finished
        case .idle: .idle
        }

        guard resolved != status else { return false }
        status = resolved
        return true
    }
}
