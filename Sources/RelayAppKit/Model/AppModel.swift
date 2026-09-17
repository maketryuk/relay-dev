import AppKit
import Foundation
import Observation
import RelayProtocol
import RelayUI

@MainActor
@Observable
final class AppModel {
    enum ConnectionState: Equatable {
        case connecting
        case connected
        case disconnected(String)

        var isConnected: Bool { self == .connected }
    }

    // MARK: - Persisted configuration

    private(set) var projects: [Project] = []
    var sidebarWidth: Double = Theme.Metrics.sidebarWidth
    var rightSidebarWidth: Double = Theme.Metrics.rightSidebarWidth
    private(set) var collapsedSections: Set<String> = []

    // MARK: - Runtime

    private(set) var sessions: [SessionID: SessionSnapshot] = [:]
    private(set) var sessionOrder: [SessionID] = []
    private(set) var connectionState: ConnectionState = .connecting
    private(set) var gitStatuses: [ProjectID: GitStatus] = [:]
    /// Which projects have a repository in them.
    ///
    /// Read off the disk rather than inferred from the first `git status`
    /// coming back. The status costs two processes, and what it gates is the
    /// Git tab: until it answered, the tab was disabled and its tooltip said
    /// the project was not a repository — which for the first seconds of every
    /// launch was a guess, and a wrong one.
    private(set) var gitRepositories: Set<ProjectID> = []
    /// What has changed in each project's working copy.
    ///
    /// Read only while something is looking: the list costs a process, and it
    /// is on screen in two places only — the Git panel and the review window.
    private(set) var gitChanges: [ProjectID: GitWorkingCopy] = [:]
    /// Which files are open in the panel, and what has been read for them.
    private(set) var expandedChanges: Set<String> = []
    private(set) var fileDiffs: [String: FileDiff] = [:]
    private(set) var loadingDiffs: Set<String> = []
    /// How many unchanged lines each open file is showing around its changes.
    /// Raised when the reader asks to see further.
    private(set) var diffContext: [String: Int] = [:]
    /// Remarks left on lines, waiting to be handed to an agent.
    private(set) var reviewComments: [ReviewComment] = []
    /// What each project has left itself to do, once it has been searched for.
    ///
    /// Not persisted: the notes live in the code, and a list restored from disk
    /// would describe a working copy that has moved on since.
    private(set) var todoScans: [ProjectID: TodoScan] = [:]
    private(set) var projectsScanningTodos: Set<ProjectID> = []
    /// Which notes have been picked up to hand over, by `TodoItem.id`.
    private(set) var pickedTodoIDs: [ProjectID: Set<String>] = [:]
    /// What the picked notes are to be done about, per project. Kept on the
    /// model rather than in the panel for the reason the commit message is:
    /// switching tabs to check something must not lose a half-written
    /// sentence — and kept per project because it was written about that
    /// project's notes and belongs to none of the others.
    private(set) var todoInstructions: [ProjectID: String] = [:]
    /// Branches of each project, read when the switcher is opened.
    private(set) var branches: [ProjectID: [GitBranch]] = [:]
    private(set) var projectsReadingBranches: Set<ProjectID> = []
    /// Text meant for a session that is still starting up.
    ///
    /// An agent's prompt does not exist for the first second or two of its
    /// life, and anything typed into the terminal before it does is swallowed
    /// by whatever the CLI prints over it.
    @ObservationIgnored private var queuedInput: [SessionID: String] = [:]
    /// Kept on the model rather than in the panel, so switching tabs to look at
    /// something does not throw away a half-written message.
    var commitMessage = ""
    private(set) var isCommitting = false
    /// A remote command in flight, named so the panel can say which.
    private(set) var runningRemoteCommand: GitActions.Remote?
    private(set) var projectFacts: [ProjectID: ProjectFacts] = [:]
    /// The image each project is drawn with, once it has been read.
    ///
    /// Observed, because a tile has to redraw when its icon arrives, and written
    /// only from a task — never while a view is drawing.
    private(set) var projectIcons: [ProjectID: ProjectArtwork] = [:]
    private(set) var sshHosts: [SSHHost] = []
    /// The host a confirmation dialog is currently asking about.
    var sshHostPendingDeletion: SSHHost?
    /// Fingerprints the ssh-agent is holding, or nil when there is no agent.
    private(set) var sshAgentKeys: Set<String>?
    /// Whether `Host *` already carries the settings that make a passphrase be
    /// asked for once.
    private(set) var sshUsesKeychain = false
    private(set) var ports: [ListeningPort] = []
    private(set) var isRefreshingPorts = false
    /// Development ports only, by default: an unfiltered list is mostly macOS.
    var showsAllPorts = false
    var portPendingTermination: ListeningPort?
    private(set) var dockerSnapshots: [ProjectID: DockerSnapshot] = [:]
    /// Projects whose Docker state is being looked up right now, so the tab can
    /// say it is checking rather than appearing to ignore the click.
    private(set) var projectsCheckingDocker: Set<ProjectID> = []
    private(set) var notificationSettings = NotificationSettings()
    private(set) var shortcutSettings = ShortcutSettings()
    private(set) var presets: [SessionPreset] = SessionPresets.defaultSet
    private(set) var sessionHistory: [SessionHistoryEntry] = []
    private(set) var inbox: [InboxItem] = []
    private(set) var toasts: [ToastContent] = []
    var isRightSidebarVisible = true
    var isLeftSidebarVisible = true
    private(set) var language: AppLanguage = .system
    private(set) var checksForUpdates = true
    private(set) var showsStatusBar = true
    private(set) var usageBarDetail: UsageDetail = .compact
    /// How large the terminals are drawn, in points.
    private(set) var terminalFontSize = Double(TerminalZoom.defaultSize)
    /// Whether terminals are drawn on the GPU. On by default, because scrolling
    /// a full window of text is what the CPU path is worst at; a machine where
    /// it cannot be had falls back on its own, and the switch is here for one
    /// where it can be had but should not.
    private(set) var terminalUsesGPURendering = true
    var isUsagePopoverOpen = false
    private(set) var paneLayouts: [ProjectID: PaneNode] = [:] {
        // Splitting, dropping and closing all move a terminal on screen without
        // going through the selection, and the context readers follow what is
        // on screen.
        didSet { watchContextForVisiblePanes() }
    }
    var rightSidebarTab: RightSidebarTab = .services

    // MARK: - Selection and UI

    var selectedProjectID: ProjectID?
    var selectedSessionID: SessionID?
    var isCommandPaletteOpen = false
    var isInboxOpen = false
    /// The panels open over the window, innermost last.
    ///
    /// A stack rather than a single value because some panels are opened from
    /// inside another — the preset editor lives in Settings — and closing one
    /// has to return to where it was opened from rather than to nothing. Peers
    /// still replace each other; only a panel that was opened from within one
    /// stacks on it.
    private(set) var modalStack: [RelayModal] = []

    var activeModal: RelayModal? { modalStack.last }
    /// Set by the rename shortcut and consumed by the sidebar row.
    var renamingSessionID: SessionID?
    /// Bumped to ask the visible terminal to take focus.
    private(set) var focusTerminalRequest = 0

    private let client = DaemonClient()
    private let store = WorkspaceStore()
    private var lastActiveSessionByProject: [String: String] = [:]
    @ObservationIgnored private let surfaceCache = TerminalSurfaceCache(limit: maxCachedSurfaces)
    private var eventTask: Task<Void, Never>?
    private var gitRefreshTask: Task<Void, Never>?
    private var portRefreshTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// True while the previous build's daemon is being handed over from.
    private var isReplacingDaemon = false
    /// Sessions the user has closed but the daemon has not finished forgetting.
    ///
    /// Everything in flight about them — the reply that created them, the exit
    /// their termination causes — arrives after the decision to close and would
    /// otherwise put them back.
    private var closingSessionIDs: Set<SessionID> = []
    private let notifier = AttentionNotifier()
    /// The update check and, when the user asks for it, the install.
    let updates = UpdateController()
    /// What the agents have left of their rate limits, read from their own
    /// caches on disk.
    let usage = UsageMonitor()
    /// How full each visible agent session's context window is.
    let context = ContextMonitor()
    /// Past conversations for the selected project, from the agents' own
    /// transcripts rather than from what Relay happens to have run.
    private(set) var conversations: [Conversation] = []
    private(set) var isLoadingConversations = false
    private var conversationsTask: Task<Void, Never>?
    var sessionShowingContextDetail: SessionID?
    private var updateTask: Task<Void, Never>?

    /// Cap on cached terminal renderers. Beyond this the least recently viewed
    /// surface is released; its session keeps running in the daemon and is
    /// re-attached with full scrollback when the user comes back.
    private static let maxCachedSurfaces = 8

    // MARK: - Lifecycle

    func bootstrap() async {
        let state = store.load()
        projects = state.projects
        sidebarWidth = state.sidebarWidth
        rightSidebarWidth = state.rightSidebarWidth
        collapsedSections = Set(state.collapsedSections)
        notificationSettings = state.notifications
        shortcutSettings = state.shortcuts
        presets = state.presets ?? SessionPresets.migrate(custom: state.customPresets, enabledIDs: state.enabledPresetIDs)
        sessionHistory = state.sessionHistory
        sessionOrder = state.sessionOrder.map { SessionID(rawValue: $0) }
        isRightSidebarVisible = state.isRightSidebarVisible
        isLeftSidebarVisible = state.isLeftSidebarVisible
        language = state.language
        checksForUpdates = state.checksForUpdates
        showsStatusBar = state.showsStatusBar
        usageBarDetail = state.usageBarDetail
        terminalFontSize = state.terminalFontSize
        terminalUsesGPURendering = state.terminalUsesGPURendering
        reviewComments = state.reviewComments
        paneLayouts = Dictionary(uniqueKeysWithValues: state.paneLayouts.map {
            (ProjectID(rawValue: $0.key), $0.value)
        })
        Localization.shared.language = state.language
        rightSidebarTab = state.rightSidebarTab.flatMap(RightSidebarTab.init(rawValue:)) ?? .services
        lastActiveSessionByProject = state.lastActiveSessionByProject
        selectedProjectID = state.lastActiveProjectID.map { ProjectID(rawValue: $0) }
            ?? projects.first?.id

        // Before the daemon, because git has nothing to do with it: waiting for
        // a session host to start is what left the Git tab dead for the first
        // seconds of a launch.
        gitRepositories = Set(
            projects.filter { GitProbe.isRepository(at: $0.rootPath) }.map(\.id)
        )
        scheduleGitRefresh()

        client.onDisconnect = { [weak self] in
            Task { @MainActor in self?.handleDisconnect() }
        }

        await connect()
        refreshAllProjectFacts()
        loadSSHHosts()
        scheduleUpdateChecks()
        if showsStatusBar { usage.start() }
    }

    private func connect() async {
        connectionState = .connecting
        do {
            try await client.connect()
            connectionState = .connected
            dismissToasts(key: "daemon")
            startEventLoop()
            try await reconcileSessions()
            restoreSelection()
            announceInheritedDaemon()
            finishInheritedDaemonIfEmpty()
        } catch {
            connectionState = .disconnected(error.localizedDescription)
            present(ToastContent(
                kind: .error,
                title: relayLocalized("Could not reach the session daemon"),
                message: error.localizedDescription,
                duration: nil,
                key: "daemon",
                action: ToastAction(title: relayLocalized("Retry")) { [weak self] in
                    self?.retryConnection()
                }
            ))
        }
    }

    func retryConnection() {
        reconnectTask?.cancel()
        Task { await connect() }
    }

    /// Says so when the sessions on screen belong to the daemon the previous
    /// build left running.
    ///
    /// Worth a line: an update used to end every session, and now it does not —
    /// but the terminals are being supervised by code one version behind the
    /// window around them, which is a thing to know rather than to discover.
    private func announceInheritedDaemon() {
        guard client.isInheritedDaemon, !sessions.isEmpty else { return }
        present(ToastContent(
            kind: .info,
            title: relayLocalized("Sessions from the previous version kept running"),
            message: relayLocalized("Relay takes over supervising them once they are closed."),
            key: "daemon"
        ))
    }

    /// Completes the changeover the moment there is nothing left to lose.
    ///
    /// Replacing the daemon ends every session inside it, so an update that
    /// arrives while work is in progress leaves the old one running. With the
    /// last session gone that objection disappears, and the app picks up the
    /// daemon it actually shipped with.
    private func finishInheritedDaemonIfEmpty() {
        guard client.isInheritedDaemon, sessions.isEmpty, !isReplacingDaemon else { return }
        isReplacingDaemon = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.client.replaceDaemon()
                self.connectionState = .connected
                self.dismissToasts(key: "daemon")
                self.startEventLoop()
                try await self.reconcileSessions()
            } catch {
                // Nothing was lost — there were no sessions — so this is not
                // worth interrupting anyone over. The next launch tries again.
                self.scheduleReconnect()
            }
            self.isReplacingDaemon = false
        }
    }

    /// Reconnects on its own after a brief pause, which covers the common case
    /// of the daemon being retired and relaunched.
    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            for delay in [1.5, 3.0, 6.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self, !Task.isCancelled, !self.connectionState.isConnected else { return }
                await self.connect()
                if self.connectionState.isConnected { return }
            }
        }
    }

    private func handleDisconnect() {
        connectionState = .disconnected("Daemon connection lost")
        present(ToastContent(
            kind: .error,
            title: relayLocalized("Session daemon disconnected"),
            message: relayLocalized("Running sessions are unaffected. Reconnecting restores them."),
            duration: nil,
            key: "daemon",
            action: ToastAction(title: relayLocalized("Reconnect")) { [weak self] in
                self?.retryConnection()
            }
        ))
        eventTask?.cancel()
        eventTask = nil
        // Surfaces are stale once the stream is gone; drop them so a reconnect
        // rebuilds each terminal from the daemon's scrollback.
        surfaceCache.removeAll()
    }

    private func startEventLoop() {
        eventTask?.cancel()
        // A new stream per connection, taken out *before* reconciling, so no
        // state change between the two is missed. Reusing the previous one
        // would deliver nothing: cancelling its consumer above closes it for
        // good, and events from the daemon just retired are not worth replaying
        // against the daemon that replaced it.
        let stream = client.eventStream()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self, !Task.isCancelled else { return }
                self.handle(event: event)
            }
        }
    }

    /// Pulls the daemon's live session list into the UI. This is what makes a
    /// relaunched GUI show everything that kept running while it was closed.
    private func reconcileSessions() async throws {
        let snapshots = try await client.listSessions()
        sessions = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        // The arrangement outlives the window: sessions survive a relaunch, so
        // the order they were dragged into has to survive it too.
        sessionOrder = SessionOrdering.applying(sessionOrder, to: snapshots.map(\.id))
        prunePaneLayouts()
    }

    private func restoreSelection() {
        guard let projectID = selectedProjectID else { return }
        if let raw = lastActiveSessionByProject[projectID.rawValue] {
            let sessionID = SessionID(rawValue: raw)
            if sessions[sessionID] != nil {
                selectSession(sessionID)
                return
            }
        }
        if let first = interactiveSessions(in: projectID).first {
            selectSession(first.id)
        }
    }

    // MARK: - Event handling

    private func handle(event: DaemonEvent) {
        switch event {
        case let .sessionCreated(snapshot):
            SessionMerge.merging(snapshot, into: &sessions, closing: closingSessionIDs)
            if sessions[snapshot.id] != nil, !sessionOrder.contains(snapshot.id) {
                sessionOrder.append(snapshot.id)
            }

        case let .sessionUpdated(snapshot):
            let previous = sessions[snapshot.id]
            SessionMerge.merging(snapshot, into: &sessions, closing: closingSessionIDs)
            flushQueuedInput(for: snapshot)
            if let previous {
                notifyIfNeeded(previous: previous.status, snapshot: snapshot)
                if previous.exitCode == nil, snapshot.exitCode != nil {
                    recordHistory(for: snapshot)
                }
            }

        case let .sessionRemoved(sessionID):
            if let ending = sessions[sessionID] {
                recordHistory(for: ending)
            }
            sessions.removeValue(forKey: sessionID)
            sessionOrder.removeAll { $0 == sessionID }
            releaseSurface(for: sessionID)
            prunePaneLayouts()
            if selectedSessionID == sessionID {
                selectedSessionID = selectedProjectID.flatMap { sessions(in: $0).first?.id }
                if let next = selectedSessionID { selectSession(next) }
            }
            finishInheritedDaemonIfEmpty()

        case let .output(sessionID, data):
            surfaceCache.existing(sessionID)?.feed(data)

        case .daemonStopping:
            connectionState = .disconnected("Daemon is shutting down")
            present(ToastContent(
                kind: .warning,
                title: relayLocalized("Session daemon is shutting down"),
                message: relayLocalized("Sessions it was supervising have ended."),
                duration: nil,
                key: "daemon",
                action: ToastAction(title: relayLocalized("Reconnect")) { [weak self] in
                    self?.retryConnection()
                }
            ))
            // A daemon that stops on purpose is usually being replaced, so the
            // app tries to pick the new one up rather than waiting to be told.
            scheduleReconnect()
        }
    }

    // MARK: - Projects

    func project(_ id: ProjectID) -> Project? {
        projects.first { $0.id == id }
    }

    var selectedProject: Project? {
        selectedProjectID.flatMap(project)
    }

    func addProject(at url: URL) {
        let path = url.standardizedFileURL.path
        if let existing = projects.first(where: { $0.rootPath == path }) {
            selectProject(existing.id)
            return
        }

        let facts = ProjectDiscovery.inspect(path: path)
        var project = Project(name: facts.suggestedName, rootPath: path)
        project.defaultServiceCommand = facts.devCommand
        if let devCommand = facts.devCommand {
            project.services = [ServiceDefinition(name: "Dev", command: devCommand, isDefault: true)]
        }
        projects.append(project)
        projectFacts[project.id] = facts
        persist()
        selectProject(project.id)
        refreshGit(for: project.id)
        refreshProjectIcons()
    }

    func removeProject(_ id: ProjectID) {
        // Sessions are the daemon's, not the project's: closing them is an
        // explicit action, so removing a project only forgets configuration.
        projects.removeAll { $0.id == id }
        projectFacts.removeValue(forKey: id)
        gitStatuses.removeValue(forKey: id)
        lastActiveSessionByProject.removeValue(forKey: id.rawValue)
        if selectedProjectID == id {
            selectedProjectID = projects.first?.id
            selectedSessionID = nil
            restoreSelection()
        }
        persist()
    }

    func updateProject(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let iconChanged = projects[index].iconPath != project.iconPath
        let markersChanged = projects[index].todoMarkers != project.todoMarkers
        projects[index] = project
        persist()
        if iconChanged { refreshProjectIcons() }
        // A list found with the old words describes a search nobody asked for
        // any more, and the panel's own timer would leave it up for half a
        // minute after the setting was changed.
        if markersChanged {
            todoScans.removeValue(forKey: project.id)
            pickedTodoIDs.removeValue(forKey: project.id)
            todoInstructions.removeValue(forKey: project.id)
            refreshTodos(for: project.id)
        }
    }

    func selectProject(_ id: ProjectID) {
        guard selectedProjectID != id else { return }
        selectedProjectID = id
        selectedSessionID = nil
        restoreSelection()
        persist()
        refreshGit(for: id)
        refreshDocker(for: id)
    }

    func selectNextProject(offset: Int) {
        guard !projects.isEmpty else { return }
        let currentIndex = projects.firstIndex { $0.id == selectedProjectID } ?? 0
        let nextIndex = (currentIndex + offset + projects.count) % projects.count
        selectProject(projects[nextIndex].id)
    }

    /// Puts a project beside another one in the rail.
    ///
    /// The rail is the one list in the window with no sort order of its own —
    /// it is whatever the user arranged, which is why the arrangement is worth
    /// remembering.
    func moveProject(_ moved: ProjectID, beside target: ProjectID, side: RowDropSide) {
        draggingProjectID = nil
        guard let movedProject = project(moved), let targetProject = project(target) else { return }
        let reordered = ListReordering.moving(movedProject, beside: targetProject, side: side, in: projects)
        guard reordered.map(\.id) != projects.map(\.id) else { return }
        projects = reordered
        persist()
    }

    /// The project being dragged in the rail, for the same reason a session's
    /// identifier is held here while it is dragged: the row the pointer is over
    /// has to know what is coming before the drop resolves the payload.
    var draggingProjectID: ProjectID?

    func revealInFinder(_ project: Project) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.rootPath)
    }

    /// Opens one file the way the project opens files: the editor it names, or
    /// whatever macOS would open it with.
    func openFileInEditor(_ path: String, in project: Project) {
        let url = URL(fileURLWithPath: project.rootPath).appendingPathComponent(path)
        if let editor = project.preferredEditor, !editor.isEmpty {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [editor, url.path]
            try? process.run()
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Opens one file at one line, for the editors that can be told which.
    ///
    /// `code` and its relatives take `--goto path:line`; `zed` and `subl` take
    /// the same suffix with no flag before it. Anything else is handed the
    /// plain path, which opens the right file at the wrong line — better than
    /// a filename it would fail to find.
    func openFileInEditor(_ path: String, line: Int, in project: Project) {
        let url = URL(fileURLWithPath: project.rootPath).appendingPathComponent(path)
        guard let editor = project.preferredEditor, !editor.isEmpty else {
            NSWorkspace.shared.open(url)
            return
        }
        let arguments: [String] = switch (editor as NSString).lastPathComponent {
        case "code", "code-insiders", "codium", "cursor", "windsurf":
            [editor, "--goto", "\(url.path):\(line)"]
        case "zed", "subl", "mate", "bbedit":
            [editor, "\(url.path):\(line)"]
        default:
            [editor, url.path]
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments
        try? process.run()
    }

    func openInEditor(_ project: Project) {
        if let editor = project.preferredEditor, !editor.isEmpty {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [editor, project.rootPath]
            try? process.run()
            return
        }
        NSWorkspace.shared.open(project.url)
    }

    // MARK: - Sessions

    /// What a session is called on screen, made unmistakable among its peers.
    func label(for session: SessionSnapshot) -> String {
        SessionNaming.labels(for: sessions(in: session.projectID))[session.id] ?? session.displayName
    }

    func sessions(in projectID: ProjectID) -> [SessionSnapshot] {
        sessionOrder.compactMap { sessions[$0] }.filter { $0.projectID == projectID }
    }

    /// Terminals the user opened, excluding services — those have their own
    /// section and their own controls.
    func interactiveSessions(in projectID: ProjectID) -> [SessionSnapshot] {
        sessions(in: projectID).filter { !$0.role.isService }
    }

    /// The rail indicator: one glance tells the user which project needs them.
    func aggregatedStatus(for projectID: ProjectID) -> RuntimeStatus {
        let statuses = sessions(in: projectID).map(\.status)
        return statuses.isEmpty ? .offline : RuntimeStatus.aggregate(statuses)
    }

    /// The presets the new-session menu offers.
    var sessionPresets: [SessionPreset] { presets }

    func addPreset(_ preset: SessionPreset) {
        presets.append(preset)
        persist()
    }

    func updatePreset(_ preset: SessionPreset) {
        guard let index = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[index] = preset
        persist()
    }

    func removePreset(_ preset: SessionPreset) {
        // There has to be a way to open a plain terminal.
        guard !preset.isProtected else { return }
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    func resetPresets() {
        presets = SessionPresets.defaultSet
        persist()
    }

    /// Starts a session from a preset, naming it after the preset rather than
    /// the bare kind so "Claude · ask first" is distinguishable in the list.
    func createSession(
        from preset: SessionPreset,
        in projectID: ProjectID,
        thenType pendingInput: String? = nil
    ) {
        guard let project = project(projectID) else { return }
        let name = SessionNaming.nextName(
            base: preset.name,
            existing: sessions(in: projectID).map(\.name)
        )
        launch(SessionSpec(
            projectID: projectID,
            kind: preset.kind,
            name: name,
            workingDirectory: project.rootPath,
            command: preset.command
        ), pendingInput: pendingInput)
    }

    func createSession(kind: SessionKind, in projectID: ProjectID, command: [String] = []) {
        guard let project = project(projectID) else { return }
        let name = SessionNaming.nextName(
            for: kind,
            existing: sessions(in: projectID).map(\.name)
        )
        let rootPath = project.rootPath

        let spec = SessionSpec(
            projectID: projectID,
            kind: kind,
            name: name,
            workingDirectory: rootPath,
            command: command
        )

        launch(spec)
    }

    private func launch(_ spec: SessionSpec, selecting: Bool = true, pendingInput: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.client.createSession(spec)
                // Events may already have moved this session on; the reply must
                // not rewind it.
                SessionMerge.merging(snapshot, into: &self.sessions, closing: self.closingSessionIDs)
                // Closed while the daemon was still answering: the session is
                // already being forgotten, so it must not be listed or selected.
                guard self.sessions[snapshot.id] != nil else { return }
                if !self.sessionOrder.contains(snapshot.id) {
                    self.sessionOrder.append(snapshot.id)
                }
                if let pendingInput { self.queuedInput[snapshot.id] = pendingInput }
                // A background service must not yank the user out of the
                // terminal they are working in.
                if selecting { self.selectSession(snapshot.id) }
            } catch {
                self.present(ToastContent(
                    kind: .error,
                    title: "Could not start \(spec.name)",
                    message: error.localizedDescription
                ))
            }
        }
    }

    func selectSession(_ id: SessionID) {
        selectedSessionID = id
        surfaceCache.touch(id)
        if let projectID = sessions[id]?.projectID {
            showInFocusedPane(id, projectID: projectID)
            lastActiveSessionByProject[projectID.rawValue] = id.rawValue
            persist()
        }
        // After the pane has been given its session, not before: asked any
        // earlier, the layout still describes what was on screen a moment ago
        // and the terminal the user just opened is the one nobody reads a
        // context figure for.
        watchContextForVisiblePanes()
        _ = surface(for: id)
    }

    func selectAdjacentSession(offset: Int) {
        guard let projectID = selectedProjectID else { return }
        let list = sessions(in: projectID)
        guard !list.isEmpty else { return }
        let currentIndex = list.firstIndex { $0.id == selectedSessionID } ?? 0
        let nextIndex = (currentIndex + offset + list.count) % list.count
        selectSession(list[nextIndex].id)
    }

    /// Puts a session beside another one in the sidebar.
    ///
    /// Only within a project, because that is the only list the order is ever
    /// read in; the daemon's own order is untouched, since it describes when
    /// things started rather than how they are arranged.
    func moveSession(_ moved: SessionID, beside target: SessionID, side: RowDropSide) {
        draggingSessionID = nil
        guard let projectID = sessions[moved]?.projectID,
              sessions[target]?.projectID == projectID
        else { return }

        let reordered = ListReordering.moving(moved, beside: target, side: side, in: sessionOrder)
        guard reordered != sessionOrder else { return }
        sessionOrder = reordered
        persist()
    }

    func renameSession(_ id: SessionID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        client.post(.rename(id, name: trimmed))
    }

    func terminateSession(_ id: SessionID) {
        client.post(.terminate(id))
    }

    /// Starts the session again the way it was started the first time.
    ///
    /// Read from the snapshot, which carries the command and the directory the
    /// daemon was given, rather than rebuilt from the kind — the kind alone
    /// does not know which host an SSH session was connected to.
    func restartSession(_ id: SessionID) {
        guard let session = sessions[id] else { return }
        closeSession(id)
        launch(SessionRestart.spec(for: session))
    }

    /// Stops the process if needed and drops the session from the workspace.
    ///
    /// The row disappears immediately rather than after the daemon has finished
    /// signalling the process. Closing a tab should feel instant; a shell that
    /// takes a moment to die is the daemon's problem, not the user's. Should the
    /// daemon disagree, the next reconcile puts the session back.
    func closeSession(_ id: SessionID) {
        guard let snapshot = sessions[id] else { return }
        let isRunning = snapshot.exitCode == nil

        recordHistory(for: snapshot)
        closingSessionIDs.insert(id)
        sessions.removeValue(forKey: id)
        sessionOrder.removeAll { $0 == id }
        releaseSurface(for: id)
        prunePaneLayouts()
        persist()
        if selectedSessionID == id {
            selectedSessionID = interactiveSessions(in: snapshot.projectID).first?.id
            if let next = selectedSessionID { selectSession(next) }
        }

        Task { [weak self] in
            guard let self else { return }
            if isRunning {
                _ = try? await self.client.send(.terminate(id))
            }
            _ = try? await self.client.send(.forget(id))
            self.closingSessionIDs.remove(id)
            self.finishInheritedDaemonIfEmpty()
        }
    }

    /// Drops a session the daemon turns out not to know.
    ///
    /// Not an error worth showing: it means this client's list is stale, which
    /// happens whenever a session ends while the window is closed or a daemon is
    /// replaced. The answer is to forget it, not to interrupt the user with
    /// something they cannot act on.
    private func forgetLocally(_ id: SessionID) {
        guard sessions[id] != nil else { return }
        sessions.removeValue(forKey: id)
        sessionOrder.removeAll { $0 == id }
        releaseSurface(for: id)
        prunePaneLayouts()
        if selectedSessionID == id {
            selectedSessionID = selectedProjectID.flatMap { interactiveSessions(in: $0).first?.id }
        }
    }

    // MARK: - Panes

    /// What the main area shows for a project.
    func paneLayout(for projectID: ProjectID) -> PaneNode? {
        paneLayouts[projectID]
    }

    /// The session being dragged out of the sidebar or a pane header.
    ///
    /// Held here rather than in the drag payload because every pane needs to
    /// know, while the pointer is still moving, whether what is coming is one of
    /// ours — the drop zones only light up for a session.
    var draggingSessionID: SessionID?

    /// Splits the focused pane, starting a terminal beside it.
    func splitFocusedPane(axis: PaneAxis) {
        splitPane(showing: selectedSessionID, axis: axis)
    }

    /// Splits the pane showing `sessionID`, starting a terminal beside it.
    func splitPane(showing sessionID: SessionID?, axis: PaneAxis) {
        guard let projectID = selectedProjectID, let project = project(projectID) else { return }
        let preset = SessionPresets.preferred(for: .shell, in: presets)
        let name = SessionNaming.nextName(base: preset.name, existing: sessions(in: projectID).map(\.name))

        let spec = SessionSpec(
            projectID: projectID,
            kind: preset.kind,
            name: name,
            workingDirectory: project.rootPath,
            command: preset.command
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.client.createSession(spec)
                SessionMerge.merging(snapshot, into: &self.sessions, closing: self.closingSessionIDs)
                guard self.sessions[snapshot.id] != nil else { return }
                if !self.sessionOrder.contains(snapshot.id) {
                    self.sessionOrder.append(snapshot.id)
                }

                if let layout = self.paneLayouts[projectID] {
                    // Falling back to the focused pane, and then to any pane at
                    // all, rather than to a fresh layout: replacing the tree
                    // would throw away every other split to make room for one.
                    let target = [sessionID, self.selectedSessionID]
                        .compactMap { $0 }
                        .first { PaneLayout.contains($0, in: layout) }
                        ?? PaneLayout.sessions(in: layout).last

                    self.paneLayouts[projectID] = target.map {
                        PaneLayout.split(layout, target: $0, with: snapshot.id, axis: axis)
                    } ?? .session(snapshot.id)
                } else {
                    self.paneLayouts[projectID] = .session(snapshot.id)
                }
                self.selectSession(snapshot.id)
                self.persist()
            } catch {
                self.present(ToastContent(
                    kind: .error,
                    title: relayLocalized("Could not start") + " \(name)",
                    message: error.localizedDescription
                ))
            }
        }
    }

    /// Shows a session in the focused pane, or focuses it if already on screen.
    ///
    /// Choosing a session from the sidebar replaces what the active pane is
    /// showing rather than tearing the split down — the same as opening a file
    /// into the active editor.
    private func showInFocusedPane(_ sessionID: SessionID, projectID: ProjectID) {
        guard let layout = paneLayouts[projectID] else {
            paneLayouts[projectID] = .session(sessionID)
            return
        }
        guard !PaneLayout.contains(sessionID, in: layout) else { return }

        if let focused = selectedSessionID, PaneLayout.contains(focused, in: layout) {
            paneLayouts[projectID] = PaneLayout.replacing(focused, with: sessionID, in: layout)
        } else {
            paneLayouts[projectID] = .session(sessionID)
        }
    }

    /// Lands a dragged session on the pane showing `target`.
    ///
    /// Moving rather than copying: a session is one running process and showing
    /// it in two panes at once would give the user two views of one terminal,
    /// which is a bug dressed as a feature.
    func movePane(_ moved: SessionID, onto target: SessionID, edge: PaneDropEdge) {
        draggingSessionID = nil
        guard let projectID = sessions[moved]?.projectID,
              sessions[target]?.projectID == projectID
        else { return }

        if let layout = paneLayouts[projectID] {
            paneLayouts[projectID] = PaneLayout.moving(moved, onto: target, edge: edge, in: layout)
        } else {
            paneLayouts[projectID] = .session(moved)
        }
        selectSession(moved)
        persist()
    }

    func setPaneFraction(_ fraction: Double, forSplit id: UUID, in projectID: ProjectID) {
        guard let layout = paneLayouts[projectID] else { return }
        paneLayouts[projectID] = PaneLayout.setting(fraction: fraction, forSplit: id, in: layout)
    }

    func commitPaneLayout() {
        persist()
    }

    func focusNextPane() {
        guard let projectID = selectedProjectID,
              let layout = paneLayouts[projectID],
              let current = selectedSessionID,
              let next = PaneLayout.session(after: current, in: layout)
        else { return }
        selectSession(next)
    }

    /// Lists the agent conversations belonging to a project.
    ///
    /// Reading a transcript each is not free, so it happens when the History
    /// panel asks rather than on a timer.
    func loadConversations(for projectID: ProjectID) {
        guard let project = project(projectID) else { return }
        conversationsTask?.cancel()
        isLoadingConversations = true

        let path = project.rootPath
        conversationsTask = Task { [weak self] in
            let found = await Task.detached(priority: .utility) { () -> [Conversation] in
                ConversationSorting.byRecency(
                    ClaudeConversationReader.list(forDirectory: path)
                        + CodexConversationReader.list(forDirectory: path)
                )
            }.value

            guard let self, !Task.isCancelled else { return }
            self.conversations = found
            self.isLoadingConversations = false
        }
    }

    /// Picks a conversation back up in a session of its own.
    ///
    /// The agent is asked to resume it, so the conversation continues where it
    /// was rather than starting again with its history pasted in — which is the
    /// difference between resuming and quoting.
    func resume(_ conversation: Conversation, in projectID: ProjectID) {
        guard let project = project(projectID) else { return }
        launch(SessionSpec(
            projectID: projectID,
            kind: conversation.kind,
            name: SessionNaming.nextName(
                base: conversation.sessionName,
                existing: sessions(in: projectID).map(\.name)
            ),
            workingDirectory: project.rootPath,
            command: conversation.resumeCommand
        ))
    }

    /// Keeps the context readers pointed at what is actually on screen.
    private func watchContextForVisiblePanes() {
        guard let projectID = selectedProjectID, let layout = paneLayouts[projectID] else {
            context.watch([])
            return
        }
        context.watch(PaneLayout.sessions(in: layout).compactMap { sessions[$0] })
    }

    /// Drops panes whose session has gone.
    private func prunePaneLayouts() {
        let known = Set(sessions.keys)
        for (projectID, layout) in paneLayouts {
            paneLayouts[projectID] = PaneLayout.pruning(layout, keeping: known)
        }
    }

    // MARK: - Terminal surfaces

    /// Called from a view body, so it touches nothing the interface observes.
    func surface(for sessionID: SessionID) -> TerminalSurface? {
        guard sessions[sessionID] != nil else { return nil }
        if let existing = surfaceCache.existing(sessionID) {
            return existing
        }

        let surface = TerminalSurface(
            sessionID: sessionID,
            client: client,
            fontSize: CGFloat(terminalFontSize),
            usesAcceleratedRendering: terminalUsesGPURendering
        )
        for evicted in surfaceCache.store(surface, for: sessionID, keeping: selectedSessionID) {
            client.post(.detach(evicted))
        }

        // Replaying scrollback on attach is what makes a restarted GUI feel like
        // it never went away.
        Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await self.client.attach(sessionID, replayScrollback: true)
            } catch let error as DaemonError where error.code == "unknown_session" {
                self.forgetLocally(sessionID)
            } catch {
                self.present(ToastContent(
                    kind: .error,
                    title: relayLocalized("Could not attach to the session"),
                    message: error.localizedDescription
                ))
            }
        }
        return surface
    }


    private func releaseSurface(for sessionID: SessionID) {
        guard surfaceCache.remove(sessionID) else { return }
        client.post(.detach(sessionID))
    }

    // MARK: - Git and discovery

    func refreshGit(for projectID: ProjectID) {
        guard let path = project(projectID)?.rootPath else { return }
        // Re-read each time rather than only at launch: a repository cloned
        // into a project that is already open must not need a relaunch to be
        // noticed, and asking is one look at the filesystem.
        if GitProbe.isRepository(at: path) {
            gitRepositories.insert(projectID)
        } else {
            gitRepositories.remove(projectID)
        }
        Task { [weak self] in
            // Only Sendable values cross into the detached task; the model stays
            // firmly on the main actor.
            let status = await Task.detached(priority: .utility) {
                GitProbe.status(at: path)
            }.value
            guard let self else { return }
            if let status {
                self.gitStatuses[projectID] = status
            } else {
                self.gitStatuses.removeValue(forKey: projectID)
            }
        }
    }

    // MARK: - Working copy

    /// The default number of unchanged lines around a change, which is what
    /// `git diff` shows and what a first look wants.
    static let diffContextLines = 3
    /// What "show me the rest of the file" asks for. Larger than any file worth
    /// reading in a panel, and cheaper than asking git how long the file is.
    static let fullDiffContextLines = 100_000

    func changes(in projectID: ProjectID) -> GitWorkingCopy {
        gitChanges[projectID] ?? GitWorkingCopy()
    }

    func refreshChanges(for projectID: ProjectID) {
        guard let path = project(projectID)?.rootPath else { return }
        Task { [weak self] in
            let copy = await Task.detached(priority: .utility) {
                GitWorkingCopyReader.changes(at: path)
            }.value
            guard let self else { return }
            let previous = self.gitChanges[projectID]
            guard previous != copy else { return }

            if let copy {
                self.gitChanges[projectID] = copy
            } else {
                self.gitChanges.removeValue(forKey: projectID)
            }
            // A file that is no longer changed has no diff to keep open.
            let present = Set((copy?.changes ?? []).map(\.path))
            self.expandedChanges.formIntersection(present)
            self.fileDiffs = self.fileDiffs.filter { present.contains($0.key) }
            for path in self.expandedChanges {
                guard let change = copy?.changes.first(where: { $0.path == path }) else { continue }
                // Only the files that actually moved. Re-reading an unchanged
                // diff replaces it with an identical one and flashes its
                // spinner, which while reading one is worse than being stale.
                guard previous?.changes.first(where: { $0.path == path }) != change else { continue }
                self.loadDiff(change, in: projectID)
            }
        }
    }

    /// Opens the panel where the working copy lives.
    ///
    /// Not a window over the app: reading a diff is something you do *while*
    /// working, with the terminal that produced it still on screen.
    func reviewChanges(in projectID: ProjectID) {
        // Set rather than toggled: `⌘G` means "show me the changes", and a
        // second press while they are showing must not be the way to hide them.
        rightSidebarTab = .git
        isRightSidebarVisible = true
        // The panel used to widen itself here, on the grounds that a diff in a
        // narrow column is a column of fragments. It is — but the panel is
        // dragged to a width on purpose, and a button that resizes the window's
        // furniture as a side effect of showing something is a button nobody
        // can predict. Narrow is the user's to fix, and theirs to keep.
        refreshChanges(for: projectID)
        persist()
    }

    func isExpanded(_ change: GitChange) -> Bool {
        expandedChanges.contains(change.path)
    }

    func toggleExpansion(of change: GitChange, in projectID: ProjectID) {
        if expandedChanges.contains(change.path) {
            expandedChanges.remove(change.path)
        } else {
            expandedChanges.insert(change.path)
            loadDiff(change, in: projectID)
        }
    }

    /// Re-reads one file with every unchanged line included.
    func expandContext(of change: GitChange, in projectID: ProjectID) {
        diffContext[change.path] = Self.fullDiffContextLines
        loadDiff(change, in: projectID)
    }

    func isShowingWholeFile(_ change: GitChange) -> Bool {
        diffContext[change.path] == Self.fullDiffContextLines
    }

    private func loadDiff(_ change: GitChange, in projectID: ProjectID) {
        guard let root = project(projectID)?.rootPath else { return }
        let context = diffContext[change.path] ?? Self.diffContextLines
        loadingDiffs.insert(change.path)
        Task { [weak self] in
            let diff = await Task.detached(priority: .userInitiated) {
                GitWorkingCopyReader.diff(at: root, change: change, context: context)
            }.value
            guard let self else { return }
            self.loadingDiffs.remove(change.path)
            self.fileDiffs[change.path] = diff
        }
    }

    // MARK: - Staging and committing

    /// The tick beside a file: on means the change is in the index and would be
    /// carried by the next commit.
    func setStaged(_ change: GitChange, _ staged: Bool, in projectID: ProjectID) {
        perform(in: projectID, title: relayLocalized("Could not stage")) { root in
            staged
                ? GitActions.stage([change.path], at: root)
                : GitActions.unstage([change.path], at: root)
        }
    }

    func setAllStaged(_ staged: Bool, in projectID: ProjectID) {
        // No path list: by the time a second click arrives the list on screen
        // describes the index as it was before the first one.
        perform(in: projectID, title: relayLocalized("Could not stage")) { root in
            staged ? GitActions.stageAll(at: root) : GitActions.unstageAll(at: root)
        }
    }

    func discard(_ change: GitChange, in projectID: ProjectID) {
        perform(in: projectID, title: relayLocalized("Could not discard")) { root in
            GitActions.discard(change, at: root)
        }
    }

    /// Commits what is ticked, and pushes it when asked in the same breath.
    func commitStagedChanges(in projectID: ProjectID, andPush push: Bool = false) {
        let message = commitMessage
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isCommitting = true
        perform(in: projectID, title: relayLocalized("Could not commit")) { root in
            if let failure = GitActions.commit(message: message, at: root) { return failure }
            guard push else { return nil }
            return GitActions.run(.push, at: root)
        } onSuccess: { [weak self] in
            self?.commitMessage = ""
        }
    }

    func run(_ command: GitActions.Remote, in projectID: ProjectID) {
        runningRemoteCommand = command
        perform(
            in: projectID,
            title: String(format: relayLocalized("%@ failed"), relayLocalized(command.title))
        ) { root in
            GitActions.run(command, at: root)
        } onSuccess: { [weak self] in
            self?.present(ToastContent(
                kind: .success,
                title: relayLocalized(command.title),
                message: relayLocalized("Done")
            ))
        }
    }

    /// Hands over what was waiting, once there is a prompt to hand it to.
    ///
    /// The status is the signal: Relay already works out when an agent has
    /// stopped printing and is waiting for a person, which is exactly the
    /// moment its prompt will keep what is typed into it.
    private func flushQueuedInput(for snapshot: SessionSnapshot) {
        guard let text = queuedInput[snapshot.id] else { return }
        guard snapshot.status == .waiting || snapshot.status == .idle else { return }
        queuedInput.removeValue(forKey: snapshot.id)
        type(text, into: snapshot.id)
    }

    // MARK: - Branches

    func isLoadingBranches(_ projectID: ProjectID) -> Bool {
        projectsReadingBranches.contains(projectID)
    }

    func refreshBranches(for projectID: ProjectID) {
        guard let path = project(projectID)?.rootPath else { return }
        projectsReadingBranches.insert(projectID)
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                GitWorkingCopyReader.branches(at: path)
            }.value
            guard let self else { return }
            self.projectsReadingBranches.remove(projectID)
            self.branches[projectID] = found
        }
    }

    /// Opens the branch switcher, reading the list while it appears.
    func pickBranch(in projectID: ProjectID) {
        presentModal(.branches(projectID))
        refreshBranches(for: projectID)
    }

    func branches(in projectID: ProjectID) -> [GitBranch] {
        branches[projectID] ?? []
    }

    func switchBranch(to name: String, creating: Bool = false, in projectID: ProjectID) {
        perform(
            in: projectID,
            title: String(format: relayLocalized("Could not switch to %@"), name)
        ) { root in
            GitActions.switchTo(name, creating: creating, at: root)
        } onSuccess: { [weak self] in
            self?.refreshBranches(for: projectID)
        }
    }

    // MARK: - Review comments

    /// The notes on one project, which is all a window ever shows.
    func comments(in projectID: ProjectID) -> [ReviewComment] {
        reviewComments.filter { $0.projectID == projectID }
    }

    func comments(for path: String, in projectID: ProjectID) -> [ReviewComment] {
        reviewComments.filter { $0.projectID == projectID && $0.path == path }
    }

    func comment(on path: String, line: Int?, code: String, text: String, in projectID: ProjectID) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        reviewComments.append(ReviewComment(
            projectID: projectID,
            path: path,
            line: line,
            code: code,
            text: trimmed
        ))
        persist()
    }

    func removeComment(_ comment: ReviewComment) {
        reviewComments.removeAll { $0.id == comment.id }
        persist()
    }

    func clearComments(in projectID: ProjectID) {
        reviewComments.removeAll { $0.projectID == projectID }
        persist()
    }

    /// The agents a review can be handed to: every one whose process is still
    /// there to receive it.
    ///
    /// Judged by the process rather than by the status, because `finished`
    /// describes the agent's *turn* — it has answered and is waiting at its
    /// prompt, which is the state you most want to send a review into.
    func agentsForReview(in projectID: ProjectID) -> [SessionSnapshot] {
        sessions(in: projectID).filter { $0.kind.isAgent && $0.exitCode == nil }
    }

    /// The one a review would go to without being asked.
    func agentForReview(in projectID: ProjectID) -> SessionSnapshot? {
        if let selected = selectedSessionID.flatMap({ sessions[$0] }), selected.kind.isAgent {
            return selected
        }
        return agentsForReview(in: projectID).first
    }

    func updateComment(_ comment: ReviewComment, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = reviewComments.firstIndex(where: { $0.id == comment.id })
        else { return }
        reviewComments[index].text = trimmed
        persist()
    }

    /// Types the notes into an agent's prompt, and stops there.
    ///
    /// Deliberately not submitted: a review is something to read over before
    /// sending, and an agent that starts work while the last remark is still
    /// being typed is worse than one that waits to be told.
    func send(_ comments: [ReviewComment], to sessionID: SessionID) {
        guard !comments.isEmpty else { return }
        // Selected first, so the terminal exists to be asked how it wants its
        // text before anything is typed into it.
        selectSession(sessionID)
        type(ReviewCommentTranscript.compose(comments), into: sessionID)
        focusTerminal()
        remove(comments)
    }

    /// Types text into a session the way a paste arrives.
    ///
    /// A bare newline at a prompt means "send this", so a review of three lines
    /// would be three half-written messages. A program that has turned on
    /// bracketed paste is saying it can tell a paste from typing, and then the
    /// whole thing lands in the prompt as one piece — which is what pasting a
    /// review into it by hand would do.
    private func type(_ text: String, into sessionID: SessionID) {
        let terminal = surfaceCache.existing(sessionID)?.terminalView.getTerminal()
        guard terminal?.bracketedPasteMode == true else {
            client.post(.input(sessionID, Data(text.utf8)))
            return
        }
        let pasted = "\u{1B}[200~" + text + "\u{1B}[201~"
        client.post(.input(sessionID, Data(pasted.utf8)))
    }

    /// Starts an agent and hands it the notes as soon as it is listening.
    func send(_ comments: [ReviewComment], toNewSessionFrom preset: SessionPreset, in projectID: ProjectID) {
        guard !comments.isEmpty else { return }
        createSession(
            from: preset,
            in: projectID,
            thenType: ReviewCommentTranscript.compose(comments)
        )
        remove(comments)
    }

    private func remove(_ comments: [ReviewComment]) {
        let sent = Set(comments.map(\.id))
        reviewComments.removeAll { sent.contains($0.id) }
        persist()
    }

    // MARK: - Todos

    func todos(in projectID: ProjectID) -> TodoScan {
        todoScans[projectID] ?? TodoScan()
    }

    func isScanningTodos(_ projectID: ProjectID) -> Bool {
        projectsScanningTodos.contains(projectID)
    }

    /// Searches the project's comments for the words it marks its work with.
    ///
    /// One search at a time per project: the panel asks again on a timer while
    /// it is open, and a sweep of a large repository outlasts the interval.
    func refreshTodos(for projectID: ProjectID) {
        guard let project = project(projectID),
              !projectsScanningTodos.contains(projectID)
        else { return }
        let root = project.rootPath
        let markers = TodoScanner.markers(from: project.todoMarkers)

        projectsScanningTodos.insert(projectID)
        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) {
                TodoScanner.scan(at: root, markers: markers)
            }.value
            guard let self else { return }
            self.projectsScanningTodos.remove(projectID)
            guard self.todoScans[projectID] != scan else { return }
            self.todoScans[projectID] = scan
            // A note that has been dealt with cannot stay picked: it is gone
            // from the list it was picked out of.
            let present = Set(scan.items.map(\.id))
            self.pickedTodoIDs[projectID] = self.pickedTodoIDs[projectID]?.intersection(present)
        }
    }

    /// Changes which words the panel looks for, from wherever it was asked.
    ///
    /// Goes through `updateProject`, so the two places that offer this setting
    /// cannot drift: both write the project, and the project is what the scan
    /// reads.
    func setTodoMarkers(_ markers: [String], in projectID: ProjectID) {
        guard var project = project(projectID) else { return }
        project.todoMarkers = TodoScanner.markers(from: markers)
        updateProject(project)
    }

    func isPicked(_ todo: TodoItem, in projectID: ProjectID) -> Bool {
        pickedTodoIDs[projectID]?.contains(todo.id) == true
    }

    func togglePick(_ todo: TodoItem, in projectID: ProjectID) {
        var picked = pickedTodoIDs[projectID] ?? []
        if picked.contains(todo.id) {
            picked.remove(todo.id)
        } else {
            picked.insert(todo.id)
        }
        pickedTodoIDs[projectID] = picked
    }

    /// The picked notes in the order the list shows them, so what is sent
    /// reads the same way as what was ticked.
    func pickedTodos(in projectID: ProjectID) -> [TodoItem] {
        let picked = pickedTodoIDs[projectID] ?? []
        return todos(in: projectID).items.filter { picked.contains($0.id) }
    }

    func clearPickedTodos(in projectID: ProjectID) {
        pickedTodoIDs[projectID] = []
        todoInstructions[projectID] = ""
    }

    func todoInstruction(in projectID: ProjectID) -> String {
        todoInstructions[projectID] ?? ""
    }

    func setTodoInstruction(_ text: String, in projectID: ProjectID) {
        todoInstructions[projectID] = text
    }

    /// Types the notes and the instruction into an agent's prompt, and stops
    /// there — for the reason a review stops there: it is meant to be read over
    /// before it is sent.
    func send(
        _ todos: [TodoItem],
        instruction: String,
        to sessionID: SessionID,
        in projectID: ProjectID
    ) {
        guard !todos.isEmpty else { return }
        selectSession(sessionID)
        type(TodoTranscript.compose(todos, instruction: instruction), into: sessionID)
        focusTerminal()
        finishSending(todos, in: projectID)
    }

    /// Starts an agent and hands it the notes as soon as it is listening.
    func send(
        _ todos: [TodoItem],
        instruction: String,
        toNewSessionFrom preset: SessionPreset,
        in projectID: ProjectID
    ) {
        guard !todos.isEmpty else { return }
        createSession(
            from: preset,
            in: projectID,
            thenType: TodoTranscript.compose(todos, instruction: instruction)
        )
        finishSending(todos, in: projectID)
    }

    /// The notes themselves stay: they are in the code until the code changes,
    /// and the next sweep is what removes them. Only the picking goes, along
    /// with the instruction that described *this* handover — carried into the
    /// next one it would be somebody else's sentence.
    private func finishSending(_ todos: [TodoItem], in projectID: ProjectID) {
        pickedTodoIDs[projectID]?.subtract(todos.map(\.id))
        todoInstructions[projectID] = ""
    }

    /// Runs one git action off the main thread and folds the result back in:
    /// the lists are re-read either way, and a refusal is shown rather than
    /// swallowed.
    private func perform(
        in projectID: ProjectID,
        title: String,
        action: @escaping @Sendable (String) -> String?,
        onSuccess: (@MainActor () -> Void)? = nil
    ) {
        guard let root = project(projectID)?.rootPath else { return }
        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) {
                action(root)
            }.value
            guard let self else { return }
            self.isCommitting = false
            self.runningRemoteCommand = nil
            if let failure {
                self.present(ToastContent(kind: .error, title: title, message: Self.summarised(failure)))
            } else {
                onSuccess?()
            }
            self.refreshChanges(for: projectID)
            self.refreshGit(for: projectID)
        }
    }

    /// Git can refuse at length — one line per path it did not like. A toast
    /// that fills the window is read as "something broke" rather than as what
    /// broke, so it says the first of it and stops.
    static func summarised(_ message: String, lines limit: Int = 4) -> String {
        let lines = message.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count > limit else { return message }
        return lines.prefix(limit).joined(separator: "\n") + "\n…"
    }

    private func refreshAllProjectFacts() {
        let targets = projects.map { (id: $0.id, path: $0.rootPath) }
        Task { [weak self] in
            let facts = await Task.detached(priority: .utility) { () -> [ProjectID: ProjectFacts] in
                var result: [ProjectID: ProjectFacts] = [:]
                for target in targets {
                    result[target.id] = ProjectDiscovery.inspect(path: target.path)
                }
                return result
            }.value
            self?.projectFacts = facts
        }
        refreshProjectIcons()
    }

    /// Reads whatever image each project is drawn with.
    ///
    /// The bytes are fetched away from the main actor and turned into an image
    /// on it: `NSImage` cannot cross actors, and decoding a favicon is cheap
    /// enough that the crossing is not worth engineering around.
    func refreshProjectIcons() {
        let targets = projects.map { (id: $0.id, path: ProjectIconLoader.path(for: $0)) }
        Task { [weak self] in
            let payloads = await Task.detached(priority: .utility) { () -> [(ProjectID, Data)] in
                targets.compactMap { target in
                    guard let path = target.path, let data = ProjectIconLoader.read(path) else { return nil }
                    return (target.id, data)
                }
            }.value

            guard let self else { return }
            var icons: [ProjectID: ProjectArtwork] = [:]
            for (identifier, data) in payloads {
                // A file that claims to be an image and is not simply leaves the
                // project with its initials, which is a perfectly good tile.
                guard let image = NSImage(data: data), image.isValid else { continue }
                // Measured here rather than in the task above: the artwork is
                // an `NSImage` either way, and reading a quarter of a megabyte
                // of alpha once per project is not worth crossing an actor for.
                icons[identifier] = ProjectIconLoader.artwork(for: image)
            }
            self.projectIcons = icons
        }
    }

    /// Asks GitHub whether there is a newer release, on launch and rarely after.
    ///
    /// Off entirely when the user has said so: the setting stops the request
    /// being made, rather than hiding what it found.
    private func scheduleUpdateChecks() {
        updateTask?.cancel()
        guard checksForUpdates else { return }
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.updates.checkPeriodically()
                try? await Task.sleep(for: .seconds(UpdateDecision.checkInterval))
            }
        }
    }

    /// Installs the waiting release, having first written the workspace down.
    ///
    /// The install quits the app, and a quit is not a moment the debounced save
    /// can be trusted to have happened in — the split the user is looking at,
    /// and which session was in front, are what the relaunched app restores the
    /// surviving sessions into.
    func installUpdate() {
        persistImmediately()
        updates.install()
    }

    func setShowsStatusBar(_ visible: Bool) {
        showsStatusBar = visible
        persist()
        if visible { usage.start() } else { usage.stop() }
    }

    /// Whether the terminals on screen ended up on the GPU.
    ///
    /// Asked of the renderers rather than remembered: the setting is what the
    /// user wants, and a machine is free to refuse it. Nothing on screen yet
    /// means there is nothing to report either way.
    var isDrawingTerminalsOnGPU: Bool {
        surfaceCache.all.contains { $0.isDrawingOnGPU }
    }

    /// Steps the terminal text size, the way every other reader does it.
    ///
    /// One size for every terminal rather than per session: the size is how the
    /// user reads, not something about a particular conversation.
    func stepTerminalFontSize(by delta: Double) {
        setTerminalFontSize(Double(TerminalZoom.stepped(CGFloat(terminalFontSize), by: CGFloat(delta))))
    }

    func resetTerminalFontSize() {
        setTerminalFontSize(Double(TerminalZoom.defaultSize))
    }

    private func setTerminalFontSize(_ size: Double) {
        guard size != terminalFontSize else { return }
        terminalFontSize = size
        for surface in surfaceCache.all {
            surface.fontSize = CGFloat(size)
        }
        persist()
    }

    func setTerminalUsesGPURendering(_ enabled: Bool) {
        guard enabled != terminalUsesGPURendering else { return }
        terminalUsesGPURendering = enabled
        for surface in surfaceCache.all {
            surface.usesAcceleratedRendering = enabled
        }
        persist()
    }

    func setUsageBarDetail(_ detail: UsageDetail) {
        usageBarDetail = detail
        persist()
    }

    func setChecksForUpdates(_ enabled: Bool) {
        checksForUpdates = enabled
        persist()
        if enabled {
            scheduleUpdateChecks()
        } else {
            updateTask?.cancel()
            updateTask = nil
            updates.dismiss()
        }
    }

    /// Git state changes far more slowly than terminal output, so it is polled
    /// lazily instead of watched — one cheap call per visible project.
    private func scheduleGitRefresh() {
        gitRefreshTask?.cancel()
        gitRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                // Now, and then every so often. The branch is on screen the
                // moment the window is, and one that arrives twelve seconds
                // later has already been read as absent.
                if let self, let projectID = self.selectedProjectID {
                    self.refreshGit(for: projectID)
                }
                try? await Task.sleep(for: .seconds(12))
            }
        }
    }

    // MARK: - UI intents

    func beginRenamingSelectedSession() {
        renamingSessionID = selectedSessionID
    }

    func focusTerminal() {
        focusTerminalRequest += 1
    }


    // MARK: - Shortcuts

    func binding(for command: RelayCommand) -> KeyBinding? {
        ShortcutResolver.binding(for: command, settings: shortcutSettings)
    }

    func rebind(_ command: RelayCommand, to binding: KeyBinding?) {
        shortcutSettings = ShortcutResolver.rebind(command, to: binding, in: shortcutSettings)
        persist()
    }

    func resetShortcut(_ command: RelayCommand) {
        shortcutSettings = ShortcutResolver.reset(command, in: shortcutSettings)
        persist()
    }

    func resetAllShortcuts() {
        shortcutSettings = ShortcutSettings(indexShortcutsEnabled: shortcutSettings.indexShortcutsEnabled)
        persist()
    }

    func setIndexShortcutsEnabled(_ enabled: Bool) {
        shortcutSettings.indexShortcutsEnabled = enabled
        persist()
    }

    /// Jumps to the nth session of the current project, if it exists.
    func selectSession(atIndex index: Int) {
        guard let projectID = selectedProjectID else { return }
        let list = interactiveSessions(in: projectID)
        guard list.indices.contains(index) else { return }
        selectSession(list[index].id)
    }

    func selectProject(atIndex index: Int) {
        guard projects.indices.contains(index) else { return }
        selectProject(projects[index].id)
    }

    // MARK: - Toasts

    func present(_ toast: ToastContent) {
        toasts = ToastCenter.appending(toast, to: toasts)
        guard let duration = toast.duration else { return }
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            self?.dismissToast(toast.id)
        }
    }

    func dismissToast(_ id: UUID) {
        toasts = ToastCenter.removing(id, from: toasts)
    }

    private func dismissToasts(key: String) {
        toasts = ToastCenter.removing(key: key, from: toasts)
    }

    // MARK: - History

    private func recordHistory(for snapshot: SessionSnapshot) {
        // Services come and go on their own schedule and would drown the list,
        // and a plain terminal that was opened and closed is not a record of
        // anything — the history is about work an agent did.
        guard !snapshot.role.isService, snapshot.kind.isAgent else { return }
        sessionHistory = SessionHistory.appending(SessionHistoryEntry(from: snapshot), to: sessionHistory)
        persist()
    }

    func history(for projectID: ProjectID) -> [SessionHistoryEntry] {
        SessionHistory.entries(in: sessionHistory, for: projectID)
    }

    func clearHistory(for projectID: ProjectID) {
        sessionHistory.removeAll { $0.projectID == projectID }
        persist()
    }

    /// Runs a past session again with the same command.
    func rerun(_ entry: SessionHistoryEntry) {
        guard let project = project(entry.projectID) else { return }
        launch(SessionSpec(
            projectID: entry.projectID,
            kind: entry.kind,
            name: SessionNaming.nextName(
                base: entry.name,
                existing: sessions(in: entry.projectID).map(\.name)
            ),
            workingDirectory: project.rootPath,
            command: entry.command
        ))
    }

    // MARK: - Right sidebar

    /// Whether a tab has anything to show for this project.
    ///
    /// Docker is the case that matters: a project with no containers and no
    /// compose file has nothing behind that tab, and an empty panel is a worse
    /// answer than a disabled tab that says why.
    func isTabAvailable(_ tab: RightSidebarTab, for project: Project) -> Bool {
        switch tab {
        case .services, .history:
            true
        case .docker:
            projectFacts[project.id]?.hasDocker == true
                || dockerSnapshots[project.id]?.containers.isEmpty == false
        case .git:
            gitRepositories.contains(project.id) || gitStatuses[project.id] != nil
        case .todo:
            true
        case .files:
            false
        }
    }

    func tabTooltip(_ tab: RightSidebarTab, for project: Project) -> String {
        guard !isTabAvailable(tab, for: project) else { return tab.title }
        switch tab {
        case .git:
            return "\(tab.title) — " + relayLocalized("not a git repository")
        case .docker:
            return projectsCheckingDocker.contains(project.id)
                ? relayLocalized("Docker — checking…")
                : relayLocalized("Docker — nothing found. Click to check again.")
        default:
            return "\(tab.title) — " + relayLocalized("coming soon")
        }
    }

    func isCheckingDocker(_ projectID: ProjectID) -> Bool {
        projectsCheckingDocker.contains(projectID)
    }

    /// Asks Docker again for a project whose tab came up empty.
    ///
    /// A stack that was not running when the project was opened is the normal
    /// case, and leaving the tab off with no way to ask again means restarting
    /// the app to see containers that are already up.
    func recheckDocker(for projectID: ProjectID) {
        guard let project = project(projectID),
              !projectsCheckingDocker.contains(projectID)
        else { return }

        projectsCheckingDocker.insert(projectID)
        refreshAllProjectFacts()

        Task { [weak self] in
            guard let self else { return }
            let reply = try? await self.client.send(.dockerStatus(projectDirectory: project.rootPath))
            if case let .docker(snapshot)? = reply {
                self.dockerSnapshots[projectID] = snapshot
            }
            self.projectsCheckingDocker.remove(projectID)
            if self.isTabAvailable(.docker, for: project) {
                self.rightSidebarTab = .docker
                self.isRightSidebarVisible = true
                self.persist()
            }
        }
    }

    /// Switching language takes effect immediately: `relayLocalized` reads the
    /// shared setting during body evaluation, so every view re-renders.
    func setLanguage(_ language: AppLanguage) {
        self.language = language
        Localization.shared.language = language
        persist()
    }

    /// Shows a top-level panel, or puts it away if it is the one already up.
    ///
    /// These are peers: opening ports while the hosts are showing swaps them
    /// rather than burying one under the other.
    func toggleModal(_ modal: RelayModal) {
        modalStack = modalStack.last == modal ? [] : [modal]
    }

    /// Opens a panel over whatever is already there, for one reached from
    /// inside another.
    func presentModal(_ modal: RelayModal) {
        guard modalStack.last != modal else { return }
        modalStack.append(modal)
    }

    /// Closes the innermost panel only.
    func dismissModal() {
        guard !modalStack.isEmpty else { return }
        modalStack.removeLast()
    }

    /// The settings of whichever project is in front, which is the only one the
    /// command and the shortcut could mean.
    func openProjectSettings() {
        guard let projectID = selectedProjectID else { return }
        toggleModal(.projectSettings(projectID))
    }


    func toggleLeftSidebar() {
        isLeftSidebarVisible.toggle()
        persist()
    }

    func toggleRightSidebar() {
        isRightSidebarVisible.toggle()
        persist()
    }

    func selectRightSidebarTab(_ tab: RightSidebarTab) {
        guard let project = selectedProject, isTabAvailable(tab, for: project) else { return }
        if rightSidebarTab == tab, isRightSidebarVisible {
            isRightSidebarVisible = false
        } else {
            rightSidebarTab = tab
            isRightSidebarVisible = true
        }
        persist()
    }

    // MARK: - Notifications

    private func notifyIfNeeded(previous: RuntimeStatus, snapshot: SessionSnapshot) {
        let isVisible = selectedSessionID == snapshot.id
            && selectedProjectID == snapshot.projectID
            && NSApplication.shared.isActive

        let context = NotificationPolicy.Context(
            previous: previous,
            current: snapshot.status,
            session: snapshot,
            projectName: project(snapshot.projectID)?.name ?? "Relay",
            isVisibleToUser: isVisible,
            settings: notificationSettings
        )
        // The inbox records everything worth knowing about; only what the user
        // is not already looking at earns a banner.
        if let event = NotificationPolicy.attentionEvent(for: context, localized: relayLocalized) {
            inbox = Inbox.appending(InboxItem(event: event, projectID: snapshot.projectID), to: inbox)
        }
        guard let event = NotificationPolicy.event(for: context, localized: relayLocalized) else { return }
        notifier.present(event)
    }

    var unreadNotificationCount: Int {
        Inbox.unreadCount(inbox)
    }

    func openNotification(_ item: InboxItem) {
        inbox = Inbox.marking(item.id, readIn: inbox)
        if let session = sessions[item.event.sessionID] {
            selectProject(session.projectID)
            selectSession(session.id)
        }
    }

    func markAllNotificationsRead() {
        inbox = Inbox.markingAllRead(inbox)
    }

    func clearNotifications() {
        inbox.removeAll()
    }

    func updateNotificationSettings(_ settings: NotificationSettings) {
        notificationSettings = settings
        persist()
    }

    func toggleNotificationMute(for projectID: ProjectID) {
        var settings = notificationSettings
        settings.toggleMute(projectID)
        updateNotificationSettings(settings)
    }

    // MARK: - Services

    /// The session backing a service, preferring a live one over a finished one
    /// left behind by an earlier run.
    func session(for service: ServiceDefinition, in projectID: ProjectID) -> SessionSnapshot? {
        let candidates = sessions(in: projectID).filter { $0.role.serviceID == service.id }
        return candidates.last { $0.exitCode == nil } ?? candidates.last
    }

    func state(of service: ServiceDefinition, in projectID: ProjectID) -> ServiceState {
        ServiceState.derive(from: session(for: service, in: projectID))
    }

    func startService(_ service: ServiceDefinition, in projectID: ProjectID) {
        guard let project = project(projectID) else { return }
        guard !state(of: service, in: projectID).isActive else { return }

        // Clear out a previous run so the sidebar does not accumulate corpses.
        if let previous = session(for: service, in: projectID), previous.exitCode != nil {
            client.post(.forget(previous.id))
        }

        launch(SessionSpec(
            projectID: projectID,
            kind: .custom,
            name: service.name,
            workingDirectory: project.rootPath,
            command: service.argv,
            role: .service(id: service.id)
        ), selecting: false)

        schedulePortRefresh()
    }

    func stopService(_ service: ServiceDefinition, in projectID: ProjectID) {
        guard let session = session(for: service, in: projectID), session.exitCode == nil else { return }
        client.post(.terminate(session.id))
    }

    func restartService(_ service: ServiceDefinition, in projectID: ProjectID) {
        Task { [weak self] in
            guard let self else { return }
            if let session = self.session(for: service, in: projectID), session.exitCode == nil {
                _ = try? await self.client.send(.terminate(session.id))
                // Wait for the port to be released before rebinding it.
                for _ in 0 ..< 40 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if self.sessions[session.id]?.exitCode != nil { break }
                }
                _ = try? await self.client.send(.forget(session.id))
            }
            self.startService(service, in: projectID)
        }
    }

    /// Opens the service's log view — which is simply its terminal.
    func showServiceLogs(_ service: ServiceDefinition, in projectID: ProjectID) {
        guard let session = session(for: service, in: projectID) else { return }
        selectSession(session.id)
    }

    /// Detected URL, unless the user pinned one.
    func url(of service: ServiceDefinition, in projectID: ProjectID) -> URL? {
        if let override = service.urlOverride, !override.isEmpty {
            return URL(string: override)
        }
        guard let session = session(for: service, in: projectID), session.exitCode == nil else { return nil }
        return ports.first { $0.ownerSessionID == session.id && $0.isLocallyReachable }?.url
    }

    func openService(_ service: ServiceDefinition, in projectID: ProjectID) {
        guard let url = url(of: service, in: projectID) else { return }
        NSWorkspace.shared.open(url)
    }

    func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    func copyServiceURL(_ service: ServiceDefinition, in projectID: ProjectID) {
        guard let url = url(of: service, in: projectID) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    /// One-click Default Dev Service, with no visible terminal to manage.
    func startDefaultService(in projectID: ProjectID) {
        guard let service = project(projectID)?.defaultService else { return }
        startService(service, in: projectID)
    }

    func addService(_ service: ServiceDefinition, to projectID: ProjectID) {
        guard var project = project(projectID) else { return }
        project.services.append(service)
        updateProject(project)
    }

    func removeService(_ service: ServiceDefinition, from projectID: ProjectID) {
        guard var project = project(projectID) else { return }
        stopService(service, in: projectID)
        project.services.removeAll { $0.id == service.id }
        updateProject(project)
    }

    func updateService(_ service: ServiceDefinition, in projectID: ProjectID) {
        guard var project = project(projectID) else { return }
        guard let index = project.services.firstIndex(where: { $0.id == service.id }) else { return }
        project.services[index] = service
        updateProject(project)
    }

    /// A freshly started server needs a moment to bind before it can be found.
    private func schedulePortRefresh() {
        portRefreshTask?.cancel()
        portRefreshTask = Task { [weak self] in
            for delay in [1.0, 2.0, 4.0] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.refreshPorts()
            }
        }
    }

    // MARK: - Docker

    func dockerSnapshot(for projectID: ProjectID) -> DockerSnapshot? {
        dockerSnapshots[projectID]
    }

    func refreshDocker(for projectID: ProjectID) {
        // Deliberately not gated on finding a compose file: a project's stack is
        // often defined in a subdirectory, and the containers are discovered by
        // their labels rather than by that file.
        guard connectionState.isConnected, let project = project(projectID) else { return }

        Task { [weak self] in
            guard let self else { return }
            guard case let .docker(snapshot)? = try? await self.client.send(
                .dockerStatus(projectDirectory: project.rootPath)
            ) else { return }
            // Asked for repeatedly now, so an answer identical to the last one
            // must not be written: observation does not compare, it notifies,
            // and the panel would redraw every few seconds for nothing.
            guard self.dockerSnapshots[projectID] != snapshot else { return }
            self.dockerSnapshots[projectID] = snapshot
        }
    }

    /// Compose actions run as ordinary sessions so their output is visible and
    /// interruptible, instead of disappearing into a background process.
    func runCompose(_ action: ComposeAction, in projectID: ProjectID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        let stack = composeStack(for: projectID, rootPath: projects[index].rootPath)
        launch(SessionSpec(
            projectID: projectID,
            kind: .custom,
            name: action.sessionName,
            workingDirectory: stack.directory,
            command: ["docker", "compose"] + stack.arguments + action.arguments
        ))
        // Give compose a moment to change state before asking about it.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.dockerSnapshots.removeValue(forKey: projectID)
            self?.refreshDocker(for: projectID)
        }
    }

    /// Starts the engine, when Relay found one to start.
    ///
    /// Docker Desktop is opened rather than run: it is an application with a
    /// window and a menu bar item, and launching its executable by hand is not
    /// how it expects to arrive. Colima has neither, so it runs as a session —
    /// it takes the better part of a minute and says what it is doing, which is
    /// worth watching rather than hiding behind a spinner.
    ///
    /// Nothing is polled afterwards on purpose: the panel is already asking
    /// every few seconds while it is open, and will notice on its own.
    func startDockerEngine(_ engine: DockerEngine, in projectID: ProjectID) {
        switch engine {
        case .dockerDesktop:
            NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications/Docker.app"))
        case .colima:
            guard let project = project(projectID) else { return }
            launch(SessionSpec(
                projectID: projectID,
                kind: .custom,
                name: "colima start",
                workingDirectory: project.rootPath,
                command: ["colima", "start"]
            ))
        }
    }

    /// Which stack a Compose action should act on.
    ///
    /// What Docker recorded when it created the containers, in preference to
    /// anything Relay could work out for itself: the panel is already showing
    /// those containers, so a button beside them that starts a different stack
    /// is worse than a button that does nothing.
    ///
    /// The file is always named rather than left to the working directory.
    /// Compose looks for its own four names there, and a project that keeps
    /// `docker-compose.local.yml` beside `.stage.yml` and `.prod.yml` has none
    /// of them — which is exactly how "no configuration file provided" happens
    /// in a project whose containers are visibly running.
    private func composeStack(
        for projectID: ProjectID,
        rootPath: String
    ) -> (directory: String, arguments: [String]) {
        let running = dockerSnapshots[projectID]?.containers ?? []
        if let container = running.first(where: { $0.composeConfigFile != nil }),
           let file = container.composeConfigFile {
            var arguments = ["--file", file]
            // The name the running stack already answers to. Compose derives it
            // from the file's directory otherwise, which for a stack kept in
            // `docker/` is "docker" — a second stack beside the one on screen
            // rather than the one it is showing.
            if let name = container.composeProject, !name.isEmpty {
                arguments += ["--project-name", name]
            }
            let directory = container.composeWorkingDirectory
                ?? URL(fileURLWithPath: file).deletingLastPathComponent().path
            return (directory, arguments)
        }

        guard let file = ComposeLocator.file(forProjectAt: rootPath) else {
            // Nothing found and nothing running. The root is where a person
            // would have tried it, so the error they get is the one they would
            // have got themselves.
            return (rootPath, [])
        }
        return (URL(fileURLWithPath: file).deletingLastPathComponent().path, ["--file", file])
    }

    func containerAction(_ action: ContainerAction, container: DockerContainer, in projectID: ProjectID) {
        guard let project = project(projectID) else { return }

        guard !action.needsTerminal else {
            // A prompt inside the container, or its log as it is written. Both
            // are things you sit and read, which is what a session is for.
            launch(SessionSpec(
                projectID: projectID,
                kind: .custom,
                name: "\(action.sessionPrefix) \(container.service ?? container.name)",
                workingDirectory: project.rootPath,
                command: ["docker"] + action.arguments(for: container)
            ))
            return
        }

        // Starting and stopping finishes in a second and leaves nothing to
        // read, so it runs as a one-shot in the daemon instead of cluttering
        // the session list.
        Task { [weak self] in
            guard let self else { return }
            let reply = try? await self.client.send(.dockerCommand(
                projectDirectory: project.rootPath,
                arguments: action.arguments(for: container)
            ))
            if case let .commandOutput(status, output)? = reply, status != 0, !output.isEmpty {
                self.present(ToastContent(
                    kind: .error,
                    title: "docker \(action.rawValue) failed",
                    message: output,
                    duration: .seconds(8)
                ))
            }
            self.dockerSnapshots.removeValue(forKey: projectID)
            self.refreshDocker(for: projectID)
            // Compose can take a moment to settle; look again.
            try? await Task.sleep(for: .seconds(2))
            self.dockerSnapshots.removeValue(forKey: projectID)
            self.refreshDocker(for: projectID)
        }
    }

    func openContainerPort(_ port: DockerPort) {
        guard let url = port.url else { return }
        NSWorkspace.shared.open(url)
    }

    func copyContainerIdentifier(_ container: DockerContainer) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(container.name, forType: .string)
    }

    // MARK: - Ports

    /// Pulled on demand — when the popover opens — rather than polled, because
    /// the daemon has to spawn `ps` and `lsof` to answer.
    func refreshPorts() {
        guard connectionState.isConnected else { return }
        // The scan covers the whole machine, so it is useful even with no
        // project selected; the identifier only keys the daemon's cache and
        // scopes nothing.
        let projectID = selectedProjectID ?? projects.first?.id ?? ProjectID(rawValue: "all")
        isRefreshingPorts = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isRefreshingPorts = false }
            guard case let .ports(found)? = try? await self.client.send(.listPorts(projectID)) else {
                self.ports = []
                return
            }
            self.ports = found
        }
    }

    func openPort(_ port: ListeningPort) {
        guard let url = port.url else { return }
        NSWorkspace.shared.open(url)
    }

    func copyPortURL(_ port: ListeningPort) {
        guard let url = port.url else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.absoluteString, forType: .string)
    }

    /// Ports this project started, and everything else on the machine.
    func groupedPorts(for projectID: ProjectID?, matching query: String = "") -> (
        project: [ListeningPort],
        other: [ListeningPort]
    ) {
        let filtered = ports
            .filter { showsAllPorts || PortClassification.isDevelopment($0) }
            .filter { PortFiltering.matches($0, query: query) }
        guard let projectID else { return ([], filtered) }
        return (
            filtered.filter { $0.ownerProjectID == projectID },
            filtered.filter { $0.ownerProjectID != projectID }
        )
    }

    /// What to call a port's owner.
    ///
    /// A list of rows all saying "node" is no use. In order of usefulness: the
    /// session Relay started it from, the project its working directory sits
    /// in, the folder it was started from, and only then the process name.
    func ownerLabel(for port: ListeningPort) -> String {
        if let owner = port.ownerName {
            guard let projectID = port.ownerProjectID, projectID != selectedProjectID,
                  let projectName = project(projectID)?.name
            else { return owner }
            return "\(projectName) · \(owner)"
        }
        if let directory = port.workingDirectory,
           let match = projects.first(where: { DirectoryContainment.contains(directory, in: $0.rootPath) }) {
            return match.name
        }
        return port.directoryName ?? port.processName
    }

    /// The line under the name: what it is and where it came from.
    func detailLabel(for port: ListeningPort) -> String {
        var parts = [port.processName, "pid \(String(port.pid))", port.address]
        if let directory = port.displayDirectory {
            parts.append(directory)
        }
        return parts.joined(separator: " · ")
    }

    /// Asks a process to stop, escalating only when told to.
    func terminatePort(_ port: ListeningPort, force: Bool = false) {
        Task { [weak self] in
            guard let self else { return }
            let reply = try? await self.client.send(.terminateProcess(pid: port.pid, force: force))
            if case let .commandOutput(status, output)? = reply, status != 0 {
                self.present(ToastContent(
                    kind: .error,
                    title: relayLocalized("Could not stop the process"),
                    message: output.isEmpty ? nil : output
                ))
            } else {
                self.present(ToastContent(
                    kind: .success,
                    title: relayLocalized("Stopped") + " \(port.processName) (\(port.port))",
                    duration: .seconds(4)
                ))
            }
            try? await Task.sleep(for: .milliseconds(600))
            self.refreshPorts()
        }
    }

    func revealPortOwner(_ port: ListeningPort) {
        guard let sessionID = port.ownerSessionID, sessions[sessionID] != nil else { return }
        selectSession(sessionID)
    }

    // MARK: - SSH

    /// Reads the user's own OpenSSH configuration. Relay never copies keys or
    /// passphrases — it only surfaces which hosts exist.
    func loadSSHHosts() {
        let configURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config", isDirectory: false)
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) {
                let hosts = SSHConfigParser.parse(rootConfig: configURL)
                return (hosts, SSHConfigStore.hasKeychainDefaults(rootConfig: configURL))
            }.value
            self?.sshHosts = loaded.0
            self?.sshUsesKeychain = loaded.1
        }
    }

    /// Asks the agent what it is already holding.
    ///
    /// Relay never sees a passphrase: knowing which keys are unlocked is enough
    /// to say whether connecting will stop to ask for one.
    func refreshSSHAgent() {
        Task { [weak self] in
            let keys = await Task.detached(priority: .utility) { SSHAgent.loadedFingerprints() }.value
            self?.sshAgentKeys = keys
        }
    }

    /// Unlocks the key with a passphrase the user just typed, off the main
    /// thread because it runs `ssh-add` and waits for it.
    ///
    /// The passphrase is passed along and dropped; what remembers it is the
    /// login keychain, and what reads it back on the next connection is `ssh`.
    func unlockSSHKey(
        at path: String,
        passphrase: String,
        completion: @escaping (SSHAgent.UnlockResult) -> Void
    ) {
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                SSHAgent.add(keyAt: path, passphrase: passphrase)
            }.value
            if case .added = result {
                self?.refreshSSHAgent()
                self?.present(ToastContent(
                    kind: .success,
                    title: relayLocalized("Key unlocked"),
                    message: relayLocalized("It is in the agent and the keychain; ssh will not ask again.")
                ))
            }
            completion(result)
        }
    }

    /// Opens the configuration in a session, at the block if one is named.
    ///
    /// The form covers the fields most hosts need; the file covers everything
    /// else, and there is no reason to make somebody leave the app to reach it.
    func openSSHConfig(atLine line: Int? = nil) {
        guard let projectID = selectedProjectID, let project = project(projectID) else { return }
        let spec = SessionSpec(
            projectID: projectID,
            kind: .shell,
            name: SessionNaming.nextName(base: "ssh config", existing: sessions(in: projectID).map(\.name)),
            workingDirectory: project.rootPath,
            command: [
                "/bin/sh", "-c",
                TerminalEditorCommand.opening(SSHConfigStore.rootConfig.path, atLine: line),
            ]
        )
        launch(spec)
        // The editor it opens is behind every panel that led here.
        modalStack = []
    }

    func enableSSHKeychain() {
        do {
            try SSHConfigStore.enableKeychainDefaults()
            loadSSHHosts()
        } catch {
            presentSSHFailure(error)
        }
    }

    /// Pinned hosts first, in the order the user pinned them.
    func sshHosts(for projectID: ProjectID?) -> (pinned: [SSHHost], others: [SSHHost]) {
        guard let projectID, let project = project(projectID) else { return ([], sshHosts) }
        return SSHHostOrdering.split(hosts: sshHosts, pinnedAliases: project.pinnedSSHHosts)
    }

    func isPinned(_ host: SSHHost, in projectID: ProjectID) -> Bool {
        project(projectID)?.pinnedSSHHosts.contains(host.alias) ?? false
    }

    func togglePin(_ host: SSHHost, in projectID: ProjectID) {
        guard var project = project(projectID) else { return }
        project.togglePin(sshHost: host.alias)
        updateProject(project)
    }

    /// Opens the host as an ordinary session, so it shares the same PTY, daemon
    /// and reconnect behaviour as every other terminal in the app.
    func connectSSH(_ host: SSHHost, in projectID: ProjectID) {
        guard let project = project(projectID) else { return }
        let rootPath = project.rootPath
        let name = SessionNaming.nextName(
            base: host.alias,
            existing: sessions(in: projectID).map(\.name)
        )

        let spec = SessionSpec(
            projectID: projectID,
            kind: .ssh,
            name: name,
            workingDirectory: rootPath,
            command: ["ssh", host.alias]
        )
        launch(spec)
    }

    /// Every alias already spoken for, so the editor can say which one.
    func sshAliases(excluding host: SSHHost?) -> Set<String> {
        Set(sshHosts.map(\.alias)).subtracting(host.map { [$0.alias] } ?? [])
    }

    /// Writes the host into the user's own configuration, adding a block when
    /// `host` is nil and patching the one it came from otherwise.
    func saveSSHHost(_ draft: SSHHostDraft, replacing host: SSHHost?) {
        do {
            if let host, let definition = host.definitions.first {
                try SSHConfigStore.update(draft, at: definition, previousAlias: host.alias)
                renameSSHPins(from: host.alias, to: draft.alias.trimmingCharacters(in: .whitespaces))
            } else {
                try SSHConfigStore.add(draft)
            }
            loadSSHHosts()
            dismissModal()
        } catch {
            presentSSHFailure(error)
        }
    }

    func deleteSSHHost(_ host: SSHHost) {
        do {
            try SSHConfigStore.remove(alias: host.alias, from: host.definitions)
            renameSSHPins(from: host.alias, to: nil)
            loadSSHHosts()
        } catch {
            presentSSHFailure(error)
        }
    }

    /// A pin is a reference to an alias, so an alias that moves takes its pins
    /// with it and an alias that goes takes them away.
    private func renameSSHPins(from previous: String, to alias: String?) {
        guard previous != alias else { return }
        for project in projects where project.pinnedSSHHosts.contains(previous) {
            var updated = project
            updated.pinnedSSHHosts = updated.pinnedSSHHosts.compactMap { $0 == previous ? alias : $0 }
            updateProject(updated)
        }
    }

    private func presentSSHFailure(_ error: Error) {
        let failure = error as? SSHConfigStore.Failure
        present(ToastContent(
            kind: .error,
            title: relayLocalized("Could not write the SSH config"),
            message: [failure?.path, failure?.reason ?? error.localizedDescription]
                .compactMap { $0 }
                .joined(separator: " — "),
            duration: nil,
            key: "ssh-config-write"
        ))
    }

    // MARK: - Sections

    func isSectionCollapsed(_ key: String) -> Bool {
        collapsedSections.contains(key)
    }

    func toggleSection(_ key: String) {
        if collapsedSections.contains(key) {
            collapsedSections.remove(key)
        } else {
            collapsedSections.insert(key)
        }
        persist()
    }

    // MARK: - Persistence

    /// Everything worth remembering, in one place.
    ///
    /// One reader rather than one per caller: a field added to the state and
    /// forgotten in the second copy is a setting that survives a debounced save
    /// and vanishes on quit, which is the sort of bug nobody thinks to look for.
    private func snapshotState() -> WorkspaceState {
        WorkspaceState(
            projects: projects,
            lastActiveProjectID: selectedProjectID?.rawValue,
            lastActiveSessionByProject: lastActiveSessionByProject,
            sidebarWidth: sidebarWidth,
            rightSidebarWidth: rightSidebarWidth,
            collapsedSections: Array(collapsedSections),
            notifications: notificationSettings,
            shortcuts: shortcutSettings,
            presets: presets,
            sessionHistory: sessionHistory,
            sessionOrder: sessionOrder.map(\.rawValue),
            isRightSidebarVisible: isRightSidebarVisible,
            isLeftSidebarVisible: isLeftSidebarVisible,
            rightSidebarTab: rightSidebarTab.rawValue,
            language: language,
            checksForUpdates: checksForUpdates,
            showsStatusBar: showsStatusBar,
            usageBarDetail: usageBarDetail,
            terminalFontSize: terminalFontSize,
            terminalUsesGPURendering: terminalUsesGPURendering,
            reviewComments: reviewComments,
            paneLayouts: Dictionary(uniqueKeysWithValues: paneLayouts.map { ($0.key.rawValue, $0.value) })
        )
    }

    func persist() {
        store.scheduleSave(snapshotState())
    }

    func persistImmediately() {
        store.saveNow(snapshotState())
    }
}
