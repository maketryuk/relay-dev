import AppKit
import Foundation
import Observation
import RelayProtocol
import RelayTracker
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
    /// Every checkout of each project's repository, as git lists them.
    ///
    /// Read, never remembered: git is where a worktree exists or does not, and
    /// one made in a terminal belongs in the sidebar as much as one made here.
    private(set) var worktrees: [ProjectID: [GitWorktree]] = [:]
    /// Projects git has answered for at least once since launch, with a list
    /// or without one.
    private(set) var worktreeListsRead: Set<ProjectID> = []
    /// Branch and diff of every worktree, by path, for the headers the sidebar
    /// groups sessions under.
    private(set) var worktreeStatuses: [String: GitStatus] = [:]
    /// The status and comment each worktree has been given, by a person from
    /// its heading or by an agent through `relay`. Remembered, unlike the rest:
    /// git has nowhere to keep it. Not `private(set)`, because what changes it
    /// is in `AppModel+WorktreeNotes.swift`.
    var worktreeNotes = WorktreeNotes()
    /// Which checkout of each project is being looked at, by path: the one the
    /// right-hand panel describes and a new session starts in. It follows the
    /// selected session, which is remembered, so it need not be.
    private(set) var activeWorktreePaths: [ProjectID: String] = [:]
    /// The worktree a confirmation is asking about removing, with what that
    /// would do to its branch.
    var worktreePendingRemoval: WorktreeRemovalRequest?
    /// Worktrees whose branch is being judged before the question is put, by
    /// path, for the heading to say it is looking.
    private(set) var worktreeRemovalsBeingChecked: Set<String> = []
    private(set) var isCreatingWorktree = false
    /// What git said when it last refused to create one, for the panel.
    private(set) var worktreeCreationFailure: String?
    /// What each project's Clean Up Worktrees window has read and been told.
    var worktreeCleanups: [ProjectID: WorktreeCleanupState] = [:]
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
    @ObservationIgnored private var queuedInput: [SessionID: PendingInput] = [:]
    /// Kept on the model rather than in the panel, so switching tabs to look at
    /// something does not throw away a half-written message.
    var commitMessage = ""
    private(set) var isCommitting = false
    /// A remote command in flight, named so the panel can say which.
    private(set) var runningRemoteCommand: GitActions.Remote?
    /// What each project's repository is in the middle of, read alongside the
    /// working copy.
    private(set) var mergeStates: [ProjectID: GitMergeState] = [:]
    /// Conflicted files as they are on disk, parsed into the sides a person
    /// has to choose between. Keyed by project and path.
    private(set) var conflicts: [String: GitConflictFile] = [:]
    /// The pull or push the transfer panel is running, if any.
    private(set) var runningTransfer: GitTransfer?
    /// The remotes each project has, read when the transfer panel opens.
    private(set) var remotes: [ProjectID: [String]] = [:]
    /// What `HEAD` has that the chosen remote branch does not, and the ref that
    /// was asked about — so the panel can tell "nothing to push" from an answer
    /// about some other branch.
    private(set) var outgoing: [String: [GitCommitSummary]] = [:]
    private(set) var refsWithNoRemoteBranch: Set<String> = []
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
    /// What ⌘⇧T brings back, newest first.
    private(set) var closedSessions: [SessionSpec] = []
    private(set) var inbox: [InboxItem] = []
    private(set) var toasts: [ToastContent] = []
    var isRightSidebarVisible = true
    var isLeftSidebarVisible = true
    private(set) var language: AppLanguage = .system
    private(set) var checksForUpdates = true
    private(set) var showsStatusBar = true
    private(set) var usageBarDetail: UsageDetail = .compact
    /// Which window Claude sessions are taken to run with.
    /// How large the terminals are drawn, in points.
    private(set) var terminalFontSize = Double(TerminalZoom.defaultSize)
    /// How large a file is drawn. Apart from the terminal's: code is read
    /// closer than a log is.
    private(set) var editorFontSize = Double(TerminalZoom.defaultSize)
    /// Markdown as the page it makes rather than as its source. On until it is
    /// turned off: a Markdown file opened beside an agent is almost always a
    /// plan or a README it wrote, and those are opened to be read.
    private(set) var showsMarkdownPreview = true
    /// Whether terminals are drawn on the GPU. On by default, because scrolling
    /// a full window of text is what the CPU path is worst at; a machine where
    /// it cannot be had falls back on its own, and the switch is here for one
    /// where it can be had but should not.
    private(set) var terminalUsesGPURendering = true
    var isUsagePopoverOpen = false
    var isResourcesPopoverOpen = false
    /// Projects folded away in the resources popover. Kept for as long as the
    /// app runs, so a project folded to get it out of the way stays folded
    /// the next time the popover opens.
    var collapsedResourceProjects: Set<ProjectID> = []
    private(set) var paneLayouts: [ProjectID: PaneNode] = [:]
    /// Every open browser tab.
    private(set) var browserPages: [BrowserID: BrowserPage] = [:]
    /// The order tabs are listed in, as dragged.
    private(set) var browserOrder: [BrowserID] = []
    /// The tab that has the keyboard, when one does. Beside `editors.focused`
    /// and the selected session, it is the third answer to "which pane is
    /// being worked in".
    private(set) var focusedBrowser: BrowserID?
    /// The tab each project was last in, for the Browser menu to act on while
    /// the keyboard is somewhere else.
    @ObservationIgnored private var lastBrowserByProject: [ProjectID: BrowserID] = [:]
    var rightSidebarTab: RightSidebarTab = .services

    // MARK: - Selection and UI

    var selectedProjectID: ProjectID?
    var selectedSessionID: SessionID?
    /// Files open in panes, and the rules about when they are written out.
    let editors = FileEditors()
    /// What each project declares, for going to where a name comes from.
    let symbols = SymbolIndex()
    /// Every file in each project, for finding one by name and searching what
    /// is in them.
    let files = FileIndex()
    /// ESLint kept warm, so that checking a file costs milliseconds rather
    /// than the two thirds of a second a node process takes to start.
    let lint = LintService()
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
    private let store: WorkspaceStore
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
    /// What each session, and Relay itself, costs the Mac in CPU and memory.
    let resources = ResourceMonitor()
    /// The issue tracker, when one is connected: its boards, what has been
    /// read of them, and the timer.
    let tracker = TrackerController()
    /// What the New Worktree panel is to be filled in with when it opens, for
    /// a piece of work that already has a name and a brief — an issue.
    var worktreeDraft: WorktreeDraft?
    /// The section Settings opens on, for a route into it that means one.
    var requestedSettingsTab: SettingsView.Tab?
    /// A timer asked for while another issue's time was still unlogged. It is
    /// started once that time has been logged or let go.
    var pendingTimerStart: PendingTimerStart?
    /// How full each visible agent session's context window is.
    /// Past conversations for the selected project, from the agents' own
    /// transcripts rather than from what Relay happens to have run.
    private(set) var conversations: [Conversation] = []
    private(set) var isLoadingConversations = false
    private var conversationsTask: Task<Void, Never>?
    private var updateTask: Task<Void, Never>?

    /// Cap on cached terminal renderers. Beyond this the least recently viewed
    /// surface is released; its session keeps running in the daemon and is
    /// re-attached with full scrollback when the user comes back.
    private static let maxCachedSurfaces = 8

    // MARK: - Lifecycle

    /// The workspace file is a parameter so that a test can be given one of
    /// its own. Everything else about the model is either runtime state or
    /// read from the daemon, which a test starts for itself; this was the one
    /// thing that reached out and wrote to the developer's own app.
    init(store: WorkspaceStore = WorkspaceStore()) {
        self.store = store
        // A file is written out on ⌘S, on losing focus and on closing, and a
        // function added a minute ago has to be findable after any of the
        // three. Re-reading the one file that changed costs a parse; walking
        // the project again costs a second.
        editors.onSave = { [weak self] file in self?.reindex(file) }
        tracker.onChange = { [weak self] in self?.persist() }
        tracker.onFailure = { [weak self] title, error in
            self?.present(ToastContent(kind: .error, title: title, message: TrackerText.describe(error)))
        }
    }

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
        closedSessions = state.closedSessions ?? []
        sessionOrder = state.sessionOrder.map { SessionID(rawValue: $0) }
        isRightSidebarVisible = state.isRightSidebarVisible
        isLeftSidebarVisible = state.isLeftSidebarVisible
        language = state.language
        checksForUpdates = state.checksForUpdates
        showsStatusBar = state.showsStatusBar
        usageBarDetail = state.usageBarDetail
        terminalFontSize = state.terminalFontSize
        editorFontSize = state.editorFontSize
        showsMarkdownPreview = state.showsMarkdownPreview
        terminalUsesGPURendering = state.terminalUsesGPURendering
        reviewComments = state.reviewComments
        worktreeNotes = WorktreeNotes(persisted: state.worktreeNotes)
        tracker.restore(state.tracker)
        paneLayouts = Dictionary(uniqueKeysWithValues: state.paneLayouts.map {
            (ProjectID(rawValue: $0.key), $0.value)
        })
        // A saved layout can name files as well as sessions, and a file pane
        // whose buffer was never reopened is a pane that says the file is
        // unavailable. One of them is reopened, because one is the rule now;
        // a layout written before that rule can name several, and the rest of
        // those panes are dropped rather than left behind broken.
        if let first = paneLayouts.values.flatMap({ PaneLayout.files(in: $0) }).sorted().first {
            editors.open(first)
        }
        for (projectID, layout) in paneLayouts {
            var pruned: PaneNode? = layout
            for path in PaneLayout.files(in: layout) where !editors.openPaths.contains(path) {
                pruned = pruned.flatMap { PaneLayout.removing(.file(path), from: $0) }
            }
            paneLayouts[projectID] = pruned
        }
        // Tabs come back with the pages they were showing. Chromium itself
        // waits until a tab is on screen, so a dozen of them cost nothing
        // until they are looked at.
        let knownProjects = Set(projects.map(\.id)).union([ProjectID.chat])
        for tab in state.browserTabs where knownProjects.contains(tab.projectID) {
            addBrowserPage(BrowserPage(id: tab.id, projectID: tab.projectID, address: tab.address, title: tab.title))
        }
        Localization.shared.language = state.language
        rightSidebarTab = state.rightSidebarTab.flatMap(RightSidebarTab.init(rawValue:)) ?? .services
        lastActiveSessionByProject = state.lastActiveSessionByProject
        selectedProjectID = state.lastActiveProjectID.map { ProjectID(rawValue: $0) }
            ?? projects.first?.id

        // What a terminal's PATH is takes a login shell to answer — three
        // quarters of a second on this machine — and the first thing that
        // needs it is a linter somebody is waiting on. Asked for now, while
        // nobody is.
        Task.detached(priority: .utility) { _ = LoginPath.value }

        // Where Claude Code and Codex tell a terminal what they are doing.
        // Checked every launch, written only when Relay's entry is missing
        // or out of date.
        Task.detached(priority: .utility) { AgentHookInstaller.installAll() }

        // Before the daemon, because git has nothing to do with it: waiting for
        // a session host to start is what left the Git tab dead for the first
        // seconds of a launch.
        gitRepositories = Set(
            projects.filter { GitProbe.isRepository(at: $0.rootPath) }.map(\.id)
        )
        scheduleGitRefresh()

        // Where the `relay` command in a terminal reaches this model. Before
        // the daemon too: a worktree is git's, and needs no session host.
        startControlServer()

        client.onDisconnect = { [weak self] in
            Task { @MainActor in self?.handleDisconnect() }
        }

        await connect()
        refreshAllProjectFacts()
        loadSSHHosts()
        scheduleUpdateChecks()
        resources.roots = { [weak self] in self?.resourceRoots() ?? ResourceRoots() }
        if showsStatusBar {
            usage.start()
            resources.start()
        }
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
        if id == .chat { return .chat }
        return projects.first { $0.id == id }
    }

    var selectedProject: Project? {
        selectedProjectID.flatMap(project)
    }

    /// What the rail shows, in the order it shows it: the chat, then the
    /// projects the user adopted.
    ///
    /// The chat is first and stays first. It is the one entry that is always
    /// there, so anything that walks the rail — the palette, ⌘⇧] — walks this
    /// rather than `projects`.
    var railProjects: [Project] {
        [.chat] + projects
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
        // The chat is not in the workspace to be forgotten from it.
        guard id != .chat else { return }
        // Sessions are the daemon's, not the project's: closing them is an
        // explicit action, so removing a project only forgets configuration.
        for root in Set([project(id)?.rootPath, workingRoot(of: id)].compactMap { $0 }) {
            lint.stop(root: root)
        }
        worktrees.removeValue(forKey: id)
        activeWorktreePaths.removeValue(forKey: id)
        worktreeNotes.forget(id)
        for tab in browsers(in: id) {
            closeBrowser(tab.id)
        }
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
        // The chat offers one tab, and a panel left on a tab it no longer
        // shows would draw the previous project's services beside it.
        if id == .chat { rightSidebarTab = .history }
        persist()
        // Nothing to ask about a directory Relay made for itself: it is not a
        // repository and holds no stack.
        guard id != .chat else { return }
        refreshGit(for: id)
        refreshDocker(for: id)
    }

    func selectNextProject(offset: Int) {
        let rail = railProjects
        let currentIndex = rail.firstIndex { $0.id == selectedProjectID } ?? 0
        let nextIndex = (currentIndex + offset + rail.count) % rail.count
        selectProject(rail[nextIndex].id)
    }

    /// Puts a project beside another one in the rail.
    ///
    /// The rail is the one list in the window with no sort order of its own —
    /// it is whatever the user arranged, which is why the arrangement is worth
    /// remembering.
    func moveProject(_ moved: ProjectID, beside target: ProjectID, side: RowDropSide) {
        guard moved != .chat, target != .chat else { return }
        guard let movedProject = project(moved), let targetProject = project(target) else { return }
        let reordered = ListReordering.moving(movedProject, beside: targetProject, side: side, in: projects)
        guard reordered.map(\.id) != projects.map(\.id) else { return }
        projects = reordered
        persist()
    }

    func revealInFinder(_ project: Project) {
        // Asking Finder for a directory that is not there yet opens nothing and
        // says nothing; the chat's is made the first time anyone looks.
        if project.isChat { _ = try? RelayPaths.ensureChatDirectory() }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.rootPath)
    }

    /// Opens one file the way the project opens files: the editor it names, or
    /// whatever macOS would open it with.
    func openFileInEditor(_ path: String, in project: Project) {
        let url = URL(fileURLWithPath: workingRoot(of: project.id) ?? project.rootPath).appendingPathComponent(path)
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
        let url = URL(fileURLWithPath: workingRoot(of: project.id) ?? project.rootPath).appendingPathComponent(path)
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
        let root = workingRoot(of: project.id) ?? project.rootPath
        if let editor = project.preferredEditor, !editor.isEmpty {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [editor, root]
            try? process.run()
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: root))
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
    /// What the project's agents and services are doing. A plain terminal is
    /// left out: its prompt, its build and its editor are not news on a tile.
    func aggregatedStatus(for projectID: ProjectID) -> RuntimeStatus {
        let statuses = sessions(in: projectID).filter { $0.reportsStatus || $0.role.isService }.map(\.status)
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
        thenType pendingInput: PendingInput? = nil
    ) {
        guard let root = workingRoot(of: projectID) else { return }
        let name = SessionNaming.nextName(
            base: preset.localizedName,
            existing: sessions(in: projectID).map(\.name)
        )
        launch(SessionSpec(
            projectID: projectID,
            kind: preset.kind,
            name: name,
            workingDirectory: root,
            command: preset.command
        ), pendingInput: pendingInput)
    }

    func createSession(kind: SessionKind, in projectID: ProjectID, command: [String] = []) {
        guard let root = workingRoot(of: projectID) else { return }
        let name = SessionNaming.nextName(
            base: relayLocalized(kind.displayName),
            existing: sessions(in: projectID).map(\.name)
        )

        let spec = SessionSpec(
            projectID: projectID,
            kind: kind,
            name: name,
            workingDirectory: root,
            command: command
        )

        launch(spec)
    }

    private func launch(_ spec: SessionSpec, selecting: Bool = true, pendingInput: PendingInput? = nil) {
        // The chat's directory is made here rather than at launch, so an
        // install where nobody ever asks a question outside a project has
        // nothing on disk to explain. Every route to a session goes through
        // this one function, reopening a closed one included.
        if spec.projectID == .chat { _ = try? RelayPaths.ensureChatDirectory() }
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
                // The session may already have reached the prompt while this
                // reply was in flight — in which case no further update is
                // coming, and waiting for one waits for ever.
                self.flushQueuedInput(for: snapshot)
            } catch {
                self.present(ToastContent(
                    kind: .error,
                    title: String(format: relayLocalized("Could not start %@"), spec.name),
                    message: error.localizedDescription
                ))
            }
        }
    }

    func selectSession(_ id: SessionID) {
        selectedSessionID = id
        // Leaving a file is one of the three moments it is written out, and
        // clicking into a terminal is leaving it.
        editors.focused = nil
        focusedBrowser = nil
        surfaceCache.touch(id)
        if let session = sessions[id] {
            let projectID = session.projectID
            // The panel beside a terminal is about the checkout that terminal
            // is working in.
            if let owner = worktree(of: session) {
                activateWorktree(owner.path, in: projectID)
            }
            showInFocusedPane(id, projectID: projectID)
            lastActiveSessionByProject[projectID.rawValue] = id.rawValue
            persist()
        }
        _ = surface(for: id)
    }

    func selectAdjacentSession(offset: Int) {
        guard let projectID = selectedProjectID else { return }
        let list = showsWorktrees(in: projectID)
            ? listedSessions(in: projectID) + sessions(in: projectID).filter(\.role.isService)
            : sessions(in: projectID)
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

    /// What the resource monitor measures. A finished session's pid is left
    /// out: the process is gone, and the number may already be somebody
    /// else's.
    func resourceRoots() -> ResourceRoots {
        var live: [SessionID: Int32] = [:]
        for session in sessions.values where session.exitCode == nil {
            if let pid = session.pid { live[session.id] = pid }
        }
        return ResourceRoots(sessions: live, daemon: client.daemonProcessID)
    }

    /// Starts the session again the way it was started the first time.
    ///
    /// Read from the snapshot, which carries the command and the directory the
    /// daemon was given, rather than rebuilt from the kind — the kind alone
    /// does not know which host an SSH session was connected to.
    func restartSession(_ id: SessionID) {
        guard let session = sessions[id] else { return }
        close(id, remembering: false)
        launch(SessionRestart.spec(for: session))
    }

    /// What the cross on a pane and ⌘W do.
    ///
    /// A service is taken off the screen and left running; anything else is
    /// closed. Everywhere else on macOS a cross in a corner closes a window,
    /// and here it ended the process behind it — so the gesture that means "I
    /// am done looking at this" killed the dev server being looked at, which
    /// is a mistake nobody makes once. Stopping a service is the stop button
    /// beside it in the sidebar: deliberate, and named after what it does.
    func dismissSession(_ id: SessionID) {
        guard sessions[id]?.role.isService == true else { return closeSession(id) }
        hideSession(id)
    }

    /// Takes a session off the screen without touching what is running in it.
    func hideSession(_ id: SessionID) {
        guard let snapshot = sessions[id] else { return }
        if let layout = paneLayouts[snapshot.projectID] {
            paneLayouts[snapshot.projectID] = PaneLayout.removing(id, from: layout)
        }
        persist()
        // Selected last, since selecting puts a session into the focused pane
        // and would undo the removal if it happened the other way round.
        guard selectedSessionID == id else { return }
        selectedSessionID = interactiveSessions(in: snapshot.projectID).first?.id
        if let next = selectedSessionID { selectSession(next) }
    }

    /// Stops the process if needed and drops the session from the workspace.
    ///
    /// The row disappears immediately rather than after the daemon has finished
    /// signalling the process. Closing a tab should feel instant; a shell that
    /// takes a moment to die is the daemon's problem, not the user's. Should the
    /// daemon disagree, the next reconcile puts the session back.
    func closeSession(_ id: SessionID) {
        close(id, remembering: true)
    }

    /// Reopens the session closed most recently in this project, the way a
    /// browser reopens a tab.
    ///
    /// Started again rather than resurrected: the process it was is gone, and
    /// what comes back is its command in its directory under its name — the
    /// same definition of "again" that the restart button uses, so the two
    /// cannot drift apart.
    func reopenLastClosedSession() {
        guard let projectID = selectedProjectID else { return }
        guard let popped = ClosedSessions.popping(closedSessions, where: { $0.projectID == projectID })
        else { return }

        closedSessions = popped.rest
        var spec = popped.spec
        // The name it had, unless something else has taken it since.
        spec.name = SessionNaming.nextName(
            base: spec.name,
            existing: sessions(in: projectID).map(\.name)
        )
        launch(spec)
        persist()
    }

    private func close(_ id: SessionID, remembering: Bool) {
        guard let snapshot = sessions[id] else { return }
        if remembering {
            closedSessions = ClosedSessions.pushing(
                SessionRestart.spec(for: snapshot),
                onto: closedSessions
            )
        }
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
        guard let projectID = selectedProjectID, let root = workingRoot(of: projectID) else { return }
        let preset = SessionPresets.preferred(for: .shell, in: presets)
        let name = SessionNaming.nextName(base: preset.localizedName, existing: sessions(in: projectID).map(\.name))

        let spec = SessionSpec(
            projectID: projectID,
            kind: preset.kind,
            name: name,
            workingDirectory: root,
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
                    title: String(format: relayLocalized("Could not start %@"), name),
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
        paneLayouts[projectID] = PaneLayout.showing(
            .session(sessionID),
            in: paneLayouts[projectID],
            focused: focusedPaneItem(in: projectID)
        )
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

    // MARK: - Files

    /// Opens a file in a pane of the project, beside whatever is focused.
    ///
    /// Beside rather than in place: a file is almost always opened to be read
    /// against something — the agent that wrote it, the file it breaks — and
    /// replacing the terminal you were looking at is the one arrangement
    /// nobody asked for. Already open means focused rather than opened twice.
    ///
    /// One file at a time, though, so the file already open gives up its
    /// pane to this one: the arrangement then stays where it was put instead
    /// of splitting again for every file somebody glances at.
    @discardableResult
    func openFile(at path: String, in projectID: ProjectID) -> Bool {
        let previous = editors.openPath.flatMap { $0 == path ? nil : $0 }
        guard editors.open(path) else {
            present(ToastContent(
                kind: .error,
                title: relayLocalized("Could not open file"),
                message: (path as NSString).lastPathComponent
            ))
            return false
        }

        if let layout = paneLayouts[projectID] {
            if !PaneLayout.contains(.file(path), in: layout) {
                if let previous, PaneLayout.contains(.file(previous), in: layout) {
                    paneLayouts[projectID] = PaneLayout.replacing(
                        .file(previous),
                        with: .file(path),
                        in: layout
                    )
                } else if let target = focusedPaneItem(in: projectID) {
                    paneLayouts[projectID] = PaneLayout.split(
                        layout,
                        target: target,
                        with: .file(path),
                        axis: .horizontal
                    )
                } else {
                    paneLayouts[projectID] = .file(path)
                }
            }
        } else {
            paneLayouts[projectID] = .file(path)
        }

        // A file left open in a project switched away from is closed now too,
        // and its pane goes with it rather than staying behind saying the
        // file is unavailable.
        if let previous {
            for (owner, layout) in paneLayouts where owner != projectID {
                guard PaneLayout.contains(.file(previous), in: layout) else { continue }
                paneLayouts[owner] = PaneLayout.removing(.file(previous), from: layout)
            }
        }

        selectedProjectID = projectID
        editors.focused = path
        focusedBrowser = nil
        persist()
        // Reading the project for what it declares takes a moment, and the
        // moment to spend it is now rather than when somebody is waiting on a
        // ⌘-click. Idempotent: a reading already done or under way is joined
        // rather than started again.
        if let root = workingRoot(of: projectID) {
            Task {
                await symbols.prepare(root: root)
                // And then the dependencies, which are slower, wanted less
                // often and never worth making the project's own names wait
                // behind. By the time anybody ⌘-clicks a framework's macro it
                // is usually already read; if it is not, the click waits.
                await symbols.prepare(root: root, scope: .dependencies)
            }
        }
        return true
    }

    /// Where a link clicked in a Markdown preview goes: another file into the
    /// pane, the way the tree would open it, and the web to the browser.
    func follow(_ link: MarkdownLink, in projectID: ProjectID) {
        switch link {
        case .withinPage: break
        case let .file(path): openFile(at: path, in: projectID)
        case let .external(url): NSWorkspace.shared.open(url)
        }
    }

    func setShowsMarkdownPreview(_ shows: Bool) {
        guard shows != showsMarkdownPreview else { return }
        showsMarkdownPreview = shows
        persist()
    }

    /// Whether the file the keyboard is in is one a preview can be shown for.
    var isMarkdownFocused: Bool {
        guard let path = editors.focused, editors[path] != nil else { return false }
        return MarkdownHTML.isMarkdown(path: path)
    }

    /// ⇧⌘V, as in the editors that have it.
    func toggleMarkdownPreview() {
        guard isMarkdownFocused else { return }
        setShowsMarkdownPreview(!showsMarkdownPreview)
    }

    /// Writes the file out and takes its pane down.
    func closeFile(at path: String, in projectID: ProjectID) {
        editors.close(path)
        if let layout = paneLayouts[projectID] {
            paneLayouts[projectID] = PaneLayout.removing(.file(path), from: layout)
        }
        persist()
    }

    // MARK: - Changing the files themselves

    /// Renames a file, and takes the buffer and the pane with it.
    ///
    /// The buffer is written out before the move rather than after: a save
    /// that lands after the rename writes the old path back into existence,
    /// and the tree then shows both.
    func renameFile(at path: String, to name: String, in projectID: ProjectID) {
        guard name.trimmingCharacters(in: .whitespacesAndNewlines) != (path as NSString).lastPathComponent
        else { return }

        editors.save(path)
        do {
            let moved = try FileActions.rename(path, to: name)
            let wasOpen = editors.openPaths.contains(path)
            editors.close(path)
            if let layout = paneLayouts[projectID] {
                paneLayouts[projectID] = PaneLayout.replacing(.file(path), with: .file(moved), in: layout)
            }
            if wasOpen {
                editors.open(moved)
                editors.focused = moved
            }
            forgetFiles(of: projectID)
            persist()
        } catch {
            report(error, title: relayLocalized("Could not rename"))
        }
    }

    /// Puts a file in the Trash, and closes what was showing it.
    func deleteFile(at path: String, in projectID: ProjectID) {
        do {
            try FileActions.delete(path)
        } catch {
            return report(error, title: relayLocalized("Could not delete"))
        }

        // A folder takes everything open inside it with it.
        for open in editors.openPaths where open == path || open.hasPrefix(path + "/") {
            editors.close(open)
            if let layout = paneLayouts[projectID] {
                paneLayouts[projectID] = PaneLayout.removing(.file(open), from: layout)
            }
        }
        forgetFiles(of: projectID)
        persist()
    }

    /// Makes an empty file or a folder, and opens the file.
    func createFile(named name: String, in directory: String, isDirectory: Bool, in projectID: ProjectID) {
        do {
            let path = try FileActions.create(name, in: directory, isDirectory: isDirectory)
            forgetFiles(of: projectID)
            if !isDirectory { openFile(at: path, in: projectID) }
        } catch {
            report(error, title: relayLocalized("Could not create"))
        }
    }

    /// The path, as the project reads it or as the disk does.
    func copyPath(of path: String, native: Bool, in projectID: ProjectID) {
        let root = workingRoot(of: projectID) ?? ""
        let copied = native ? path : FileMatching.relative(path, to: root)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(copied, forType: .string)
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Everything read off the disk for this project is now a guess.
    private func forgetFiles(of projectID: ProjectID) {
        guard let root = workingRoot(of: projectID) else { return }
        files.invalidate(root: root)
        symbols.invalidate(root: root)
    }

    private func report(_ error: any Error, title: String) {
        let message = (error as? FileActions.Failure)?.localizedMessage ?? error.localizedDescription
        present(ToastContent(kind: .error, title: title, message: message))
    }

    /// ⌘W, which closes whichever pane the keyboard is in.
    ///
    /// It closed the selected session whatever was in front of it, so a file
    /// opened beside a terminal could not be closed with the key every window
    /// on the machine closes things with — and pressing it took down the
    /// agent in the pane next door instead.
    func closeFocusedPane() {
        guard let path = editors.focused else {
            if let browser = focusedBrowser {
                closeBrowser(browser)
            } else if let id = selectedSessionID {
                dismissSession(id)
            }
            return
        }
        // The project whose arrangement holds it, which is not always the one
        // selected: a file can be left open in a project switched away from.
        let owner = paneLayouts.first { PaneLayout.contains(.file(path), in: $0.value) }?.key
        guard let projectID = owner ?? selectedProjectID else { return }
        closeFile(at: path, in: projectID)
    }

    func focusFile(at path: String, caret: Int? = nil) {
        editors.focused = path
        focusedBrowser = nil
        guard let caret, let file = editors[path] else { return }
        file.caret = caret
        // The marks belong to the name the caret is in. Moved off it, they
        // are a highlight on a word nobody is looking at any more.
        if !file.occurrences.contains(where: { NSLocationInRange(caret, $0) }) {
            file.occurrences = []
        }
    }

    /// ⌘S. Saving also happens on its own — on leaving the pane and on closing
    /// it — so this is for the habit rather than for the file's safety.
    ///
    /// It is also where the project's own formatter runs, which is why the
    /// two are not the same thing: a deliberate save is a moment to rewrite
    /// the file in, and leaving a pane or closing it is not.
    ///
    /// The file is written first and corrected after. Waiting for the
    /// formatter before writing made ⌘S take as long as the formatter does —
    /// two thirds of a second of ESLint on a real project — which is two
    /// thirds of a second in which the file on disk is not what is on screen
    /// and the agent in the pane next door may read it. The correction is a
    /// second write when there is one to make, and none when there is not.
    func saveFocusedFile() {
        guard let path = editors.focused, let file = editors[path], !file.isVendored else {
            editors.focused.map { editors.save($0) }
            return
        }
        guard let projectID = selectedProjectID, let root = workingRoot(of: projectID) else {
            editors.save(path)
            return
        }

        // On disk now, exactly as it is on screen.
        editors.save(path)

        let text = file.text
        Task { [weak self] in
            guard let self else { return }
            var fixed = await lint.answer(for: text, path: path, root: root, fix: true)
            if fixed == nil {
                fixed = await Task.detached(priority: .userInitiated) { () -> FileCheck.Fixed? in
                    guard let fixer = FileCheckers.fixer(for: path, in: root) else { return nil }
                    return FileCheck.fix(fixer, on: text, path: path, root: root)
                }.value
            }

            guard let file = editors[path] else { return }
            // Only if nothing was typed while it ran: overwriting a keystroke
            // with a correction made before it is the one way a formatter can
            // lose somebody's work.
            guard file.text == text else { return }

            if let corrected = fixed?.text {
                file.text = corrected
                editors.save(path)
            }

            // ESLint answered both questions in the one run it was given, so
            // there is nothing left to ask it.
            if let found = fixed?.diagnostics {
                diagnostics = found
                checkedText = file.text
                checkerName = checkerName ?? "ESLint"
            } else {
                checkOpenFile(in: projectID, immediately: true)
            }
        }
    }

    // MARK: - What is wrong with the file

    /// What the project's own checker said about the open file.
    private(set) var diagnostics: [Diagnostic] = []
    /// The name of whatever said it, for the pane to attribute it to.
    private(set) var checkerName: String?
    private var checkTask: Task<Void, Never>?
    /// The text the diagnostics on screen were made from.
    ///
    /// A checker is a whole node process on a large project — most of a
    /// second — and asking it again about text it has just answered about is
    /// that second spent on nothing. Saving asks once and records what it
    /// asked about, so the redraw that follows does not ask again.
    private var checkedText: String?

    /// How long after the last keystroke the checker is run.
    ///
    /// Short, because the wait is added to the checker's own — and with the
    /// service kept warm the checker's own is about thirty milliseconds, so
    /// this pause is now most of what there is to feel. A run whose answer
    /// stops being wanted is killed rather than left to finish, so a shorter
    /// pause costs nothing but the processes it starts.
    private static let checkDelay = Duration.milliseconds(250)

    /// Runs the project's own checker over the buffer.
    ///
    /// The project's own, never one of ours: a checkout is linted by the
    /// rules it carries, and a linter installed beside Relay would be a
    /// second opinion nobody asked for. No checker in the project means no
    /// marks and nothing said about it.
    func checkOpenFile(in projectID: ProjectID, immediately: Bool = false) {
        checkTask?.cancel()

        guard let path = editors.openPath,
              let file = editors[path],
              !file.isVendored,
              let root = workingRoot(of: projectID)
        else {
            diagnostics = []
            checkerName = nil
            checkedText = nil
            return
        }

        let text = file.text
        guard text != checkedText else { return }

        checkTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: Self.checkDelay) }
            guard !Task.isCancelled else { return }

            // The warm service first: the same ESLint, already started, with
            // the project's config already read.
            if let self, let served = await self.lint.answer(for: text, path: path, root: root, fix: false) {
                guard !Task.isCancelled, self.editors.openPath == path else { return }
                checkerName = "ESLint"
                diagnostics = served.diagnostics ?? []
                checkedText = text
                return
            }

            // Everything about running it happens off the main actor,
            // including asking where the tool is: that is a process of its
            // own, and the window must not wait for either.
            let running = RunningProcess()
            let found = await withTaskCancellationHandler {
                await Task.detached(priority: .utility) { () -> (String, [Diagnostic])? in
                    guard let checker = FileCheckers.checker(for: path, in: root) else { return nil }
                    return (
                        checker.name,
                        FileCheck.run(checker, on: text, path: path, root: root, running: running)
                    )
                }.value
            } onCancel: {
                running.cancel()
            }

            guard !Task.isCancelled, let self, editors.openPath == path else { return }
            checkerName = found?.0
            diagnostics = found?.1 ?? []
            checkedText = text
        }
    }

    // MARK: - Searching the files

    /// Bumped to ask the pane being worked in to open its find bar.
    ///
    /// A counter rather than a flag, because the same request can be made
    /// twice — ⌘F while the bar is already open means "put the caret back in
    /// it" — and a flag that is already true says nothing the second time.
    private(set) var findRequest = 0

    /// ⌘F: the file in front of you, or the project when no file is.
    ///
    /// Not nothing in the second case: somebody pressing find in a terminal
    /// is looking for something, and the panel that searches everything is
    /// the only honest thing to offer them.
    func findInFocusedFile() {
        // A picture or a recording has no text to look through, which makes
        // it the terminal's case rather than the file's.
        guard let path = editors.focused, editors[path] != nil else {
            if let projectID = selectedProjectID { presentModal(.search(projectID)) }
            return
        }
        findRequest += 1
    }

    /// What is being looked for, as typed.
    var searchQuery = ""
    /// How it is read: case, whole words, pattern.
    var searchOptions = TextSearch.Options()
    private(set) var searchHits: [TextHit] = []
    private(set) var isSearching = false
    /// True when there were more matches than are being shown.
    private(set) var searchWasTruncated = false
    private var searchTask: Task<Void, Never>?

    /// Runs the search a moment after the typing stops.
    ///
    /// Every keystroke reading the project would be a project read twenty
    /// times a second; a pause of a quarter of a second is below noticing and
    /// above typing.
    func search(in projectID: ProjectID) {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)

        // One letter matches most of a codebase, which is not an answer.
        guard query.count >= 2, let root = workingRoot(of: projectID) else {
            searchHits = []
            searchWasTruncated = false
            isSearching = false
            return
        }

        isSearching = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }

            await files.prepare(root: root)
            let found = await TextSearch.find(query, in: files.files(in: root), options: searchOptions)
            guard !Task.isCancelled else { return }

            searchHits = found
            searchWasTruncated = found.count >= TextSearch.limit
            isSearching = false
        }
    }

    /// Opens the file a match is in, at the match.
    func open(_ hit: TextHit, in projectID: ProjectID) {
        dismissModal()
        guard openFile(at: hit.path, in: projectID) else { return }
        editors[hit.path]?.jump(to: hit.range)
    }

    // MARK: - Going to where a name comes from

    /// Where a jump started, so it can be gone back to.
    private struct SymbolOrigin {
        let projectID: ProjectID
        let path: String
        let range: NSRange
    }

    /// The candidates of the last lookup that found more than one, and the
    /// name they are candidates for. Read by the panel that asks which was
    /// meant; kept here rather than in the panel so that the panel can be
    /// drawn from the model alone, like every other one.
    private(set) var definitionMatches: [SymbolDefinition] = []
    private var symbolOrigins: [SymbolOrigin] = []
    private var pendingOrigin: SymbolOrigin?

    /// Far more than anybody walks back through, and small enough that the
    /// paths in it are never worth thinking about.
    private static let symbolHistoryLimit = 50

    var canGoBackToOrigin: Bool { !symbolOrigins.isEmpty }

    /// ⌘-click in a file, at the character it landed on.
    func goToDefinition(at offset: Int, in path: String, projectID: ProjectID) {
        guard let file = editors[path],
              let word = SymbolWord.identifier(in: file.text, at: offset)
        else { return }

        let origin = SymbolOrigin(projectID: projectID, path: path, range: word.range)

        // A parameter or a `const` means the one written here. An index of
        // names has nothing to say about it — and said it anyway, sending a
        // click on a function's own argument to a file across the project
        // that happened to use the same word.
        if let language = file.language,
           let local = LocalScopes.binding(at: offset, in: file.text, language: language) {
            if local.definition != word.range { remember(origin) }
            file.show(local)
            return
        }

        // A word inside a string is a value rather than a name: a cookie's
        // key, a class in a template, a word in a sentence. Nothing declares
        // it, and saying so every time somebody ⌘-clicks one is a complaint
        // about the question rather than an answer to it.
        let literal = SymbolWord.literal(in: file.text, at: offset)
        if let literal, literal.text.contains(".") {
            Task { await resolveKey(literal.text, from: origin, fallback: word.text) }
            return
        }
        // And a plain one is not asked about at all. Saying nothing was half
        // the answer: the other half is not going anywhere either, since a
        // `const max` in another file has nothing to do with the word `max`
        // inside `value === 'max'`.
        guard literal == nil || literal?.text.contains("/") == true else { return }

        Task { await resolveDefinition(named: word.text, from: origin) }
    }

    /// A translation key, which lives in a locale file rather than in code.
    private func resolveKey(_ key: String, from origin: SymbolOrigin, fallback name: String) async {
        guard let root = workingRoot(of: origin.projectID) else { return }
        await files.prepare(root: root)

        let paths = files.files(in: root)
        let found = await Task.detached(priority: .userInitiated) {
            TranslationKeys.find(key, in: paths)
        }.value

        guard !found.isEmpty else {
            // Not a key after all, or not one this project defines: the name
            // under the caret is still worth asking about — quietly, since
            // what was clicked was a string either way.
            await resolveDefinition(named: name, from: origin, quietly: true)
            return
        }

        let ranked = found.sorted { $0.path < $1.path }
        go(to: ranked[0], from: origin)
        guard ranked.count > 1 else { return }

        definitionMatches = ranked
        pendingOrigin = nil
        present(ToastContent(
            kind: .info,
            title: String(format: relayLocalized("Other declarations: %d"), ranked.count - 1),
            message: key,
            duration: .seconds(5),
            key: "definition",
            action: ToastAction(title: relayLocalized("Show")) { [weak self] in
                self?.presentModal(.definitions(projectID: origin.projectID, name: key))
            }
        ))
    }

    /// The same from the keyboard, which means the file being typed in at the
    /// caret it was left at.
    func goToDefinitionFromCaret() {
        guard let projectID = selectedProjectID,
              let path = editors.focused,
              let file = editors[path]
        else { return }
        goToDefinition(at: file.caret, in: path, projectID: projectID)
    }

    /// The file first, then the project.
    ///
    /// A name declared in the file being read is almost always the one meant —
    /// a private helper, a method of the class the call is in — and answering
    /// from there is instant and needs no index at all. The project is asked
    /// only when the file has no answer or more than one.
    /// - Parameter quietly: say nothing when there is no answer, which is
    ///   the right silence for a click on something that was never a name.
    private func resolveDefinition(named name: String, from origin: SymbolOrigin, quietly: Bool = false) async {
        var candidates = declarations(of: name, in: origin.path)

        if candidates.count != 1, let root = workingRoot(of: origin.projectID) {
            // The first jump into a project can wait for it to be read, and a
            // click that appears to do nothing for a few seconds reads as a
            // click that missed. The key is shared with the answer below, so
            // this is replaced rather than stacked on.
            if !symbols.isReady(root), !quietly {
                present(ToastContent(
                    kind: .info,
                    title: relayLocalized("Reading the project…"),
                    duration: .seconds(2),
                    key: "definition"
                ))
            }
            await symbols.prepare(root: root)
            for found in symbols.definitions(named: name, in: root) where !candidates.contains(found) {
                candidates.append(found)
            }
            // Only when nothing declares it: a file named after it is the
            // answer to a component, and the worse answer to everything else.
            if candidates.isEmpty {
                candidates = symbols.files(named: name, in: root)
            }
            // And last, other people's code. Read only when the project has
            // failed to answer, because reading it costs seconds and most
            // jumps never get this far: a framework's macro is declared in
            // its own type declarations and nowhere in the checkout at all.
            if candidates.isEmpty {
                if !symbols.isReady(root, scope: .dependencies), !quietly {
                    present(ToastContent(
                        kind: .info,
                        title: relayLocalized("Reading dependencies…"),
                        duration: .seconds(4),
                        key: "definition"
                    ))
                }
                await symbols.prepare(root: root, scope: .dependencies)
                candidates = symbols.definitions(named: name, in: root, scope: .dependencies)
                // A class in PHP is a file named after it, which is how a
                // framework's `Model` is found without its source having been
                // read at all.
                if candidates.isEmpty {
                    candidates = symbols.files(named: name, in: root, scope: .dependencies)
                }
            }
        }

        // Standing on a declaration and asking for it is how "where else is
        // this" gets asked, so the thing under the caret is dropped — unless
        // it is all there is, in which case going nowhere is the honest
        // answer and the caret is already there.
        let elsewhere = candidates.filter { $0.path != origin.path || $0.range != origin.range }
        let found = elsewhere.isEmpty ? candidates : elsewhere

        let ranked = DefinitionRanking.ranked(
            found,
            from: origin.path,
            hints: DefinitionRanking.hints(in: editors[origin.path]?.text ?? "")
        )

        guard let best = ranked.first else {
            guard !quietly else { return }
            present(ToastContent(
                kind: .info,
                title: relayLocalized("No definition found"),
                message: name,
                duration: .seconds(6),
                key: "definition",
                action: ToastAction(title: relayLocalized("Find in Files")) { [weak self] in
                    guard let self else { return }
                    searchQuery = name
                    presentModal(.search(origin.projectID))
                    search(in: origin.projectID)
                }
            ))
            return
        }

        // Straight there, the way every editor a person has used before this
        // one behaves. The others are not hidden — they are one press away —
        // but they are not a question asked before the jump either.
        go(to: best, from: origin)
        guard ranked.count > 1 else { return }

        definitionMatches = ranked
        pendingOrigin = nil
        present(ToastContent(
            kind: .info,
            title: String(format: relayLocalized("Other declarations: %d"), ranked.count - 1),
            message: name,
            duration: .seconds(5),
            key: "definition",
            action: ToastAction(title: relayLocalized("Show")) { [weak self] in
                self?.presentModal(.definitions(projectID: origin.projectID, name: name))
            }
        ))
    }

    /// What this file itself declares under that name.
    private func declarations(of name: String, in path: String) -> [SymbolDefinition] {
        guard let file = editors[path], let language = file.language else { return [] }
        return SymbolTags
            .definitions(in: file.text, language: language, path: path)
            .filter { $0.name == name }
    }

    /// Picked from the panel that offered several.
    func openDefinition(_ definition: SymbolDefinition) {
        let origin = pendingOrigin
        pendingOrigin = nil
        dismissModal()
        go(to: definition, from: origin)
    }

    private func go(to definition: SymbolDefinition, from origin: SymbolOrigin?) {
        let projectID = origin?.projectID ?? selectedProjectID
        guard let projectID, openFile(at: definition.path, in: projectID) else { return }
        if let origin { remember(origin) }
        editors[definition.path]?.jump(to: currentRange(of: definition))
    }

    private func remember(_ origin: SymbolOrigin) {
        symbolOrigins.append(origin)
        if symbolOrigins.count > Self.symbolHistoryLimit { symbolOrigins.removeFirst() }
    }

    /// Back to where the last jump started.
    func goBackToOrigin() {
        guard let origin = symbolOrigins.popLast() else { return }
        guard openFile(at: origin.path, in: origin.projectID) else { return }
        editors[origin.path]?.jump(to: origin.range)
    }

    /// Where that name is now, rather than where it was when the project was
    /// read.
    ///
    /// The file is asked again whenever what the index remembers is no longer
    /// the name it promised — which is what an edit above the declaration does
    /// to every offset under it. One parse at the moment of the jump, against
    /// keeping a whole project's offsets in step with every keystroke.
    private func currentRange(of definition: SymbolDefinition) -> NSRange {
        // A file is its own declaration and has no name in it to look for.
        guard definition.kind != .file else { return definition.range }
        guard let text = editors[definition.path]?.text
            ?? (try? String(contentsOfFile: definition.path, encoding: .utf8))
        else { return definition.range }

        let source = text as NSString
        if NSMaxRange(definition.range) <= source.length,
           source.substring(with: definition.range) == definition.name {
            return definition.range
        }
        guard let language = SourceLanguage.detect(path: definition.path, contents: text)
        else { return definition.range }

        let again = SymbolTags.definitions(in: text, language: language, path: definition.path)
        let match = again.first { $0.name == definition.name && $0.kind == definition.kind }
            ?? again.first { $0.name == definition.name }
        return match?.range ?? definition.range
    }

    /// Replaces what one saved file declares, when its project has been read.
    private func reindex(_ file: OpenFile) {
        // The deepest root, because Claude Code keeps its worktrees inside the
        // checkout they came from.
        let roots = projects.map(\.rootPath) + worktrees.values.flatMap { $0.map(\.path) }
        guard let language = file.language,
              let root = roots
                  .filter({ DirectoryContainment.contains(file.path, in: $0) })
                  .max(by: { $0.count < $1.count }),
              symbols.isReady(root)
        else { return }
        symbols.replace(
            SymbolTags.definitions(in: file.text, language: language, path: file.path),
            for: file.path,
            in: root
        )
    }

    /// Which pane the keyboard is in, as the layout sees it.
    private func focusedPaneItem(in projectID: ProjectID) -> PaneItem? {
        guard let layout = paneLayouts[projectID] else { return nil }
        if let path = editors.focused, PaneLayout.contains(.file(path), in: layout) {
            return .file(path)
        }
        if let browser = focusedBrowser, PaneLayout.contains(.browser(browser), in: layout) {
            return .browser(browser)
        }
        if let session = selectedSessionID, PaneLayout.contains(.session(session), in: layout) {
            return .session(session)
        }
        return PaneLayout.items(in: layout).first
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
        // The agents file conversations by the directory they ran in, so each
        // worktree has a history of its own.
        guard let path = workingRoot(of: projectID) else { return }
        conversationsTask?.cancel()
        isLoadingConversations = true

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
        guard let root = workingRoot(of: projectID) else { return }
        launch(SessionSpec(
            projectID: projectID,
            kind: conversation.kind,
            name: SessionNaming.nextName(
                base: conversation.sessionName,
                existing: sessions(in: projectID).map(\.name)
            ),
            workingDirectory: root,
            command: conversation.resumeCommand
        ))
    }

    /// Drops panes whose session has gone.
    private func prunePaneLayouts() {
        let known = Set(sessions.keys)
        let open = editors.openPaths
        for (projectID, layout) in paneLayouts {
            paneLayouts[projectID] = PaneLayout.pruning(
                layout,
                keeping: known,
                openFiles: open,
                openBrowsers: Set(browserPages.keys)
            )
        }
    }

    // MARK: - Browser

    /// The project's tabs, in the order the sidebar lists them.
    func browsers(in projectID: ProjectID) -> [BrowserPage] {
        browserOrder.compactMap { browserPages[$0] }.filter { $0.projectID == projectID }
    }

    /// Opens a new tab and shows it, at `url` or else at the project's own dev
    /// server, since that is what a tab is usually opened for.
    func newBrowserTab(in projectID: ProjectID, at url: URL? = nil) {
        let page = BrowserPage(projectID: projectID, address: url?.absoluteString ?? startingAddress(for: projectID))
        addBrowserPage(page)
        selectBrowser(page.id)
    }

    /// Shows a tab in the pane being worked in, the way choosing a session
    /// does: a tab takes the place of the tab on screen, and arrives beside
    /// the terminals when there is none.
    func selectBrowser(_ id: BrowserID) {
        guard let page = browserPages[id] else { return }
        let projectID = page.projectID
        // Read before the tab takes the keyboard, or the pane being worked in
        // would be the one that is not on screen yet.
        let focused = focusedPaneItem(in: projectID)
        let layout = paneLayouts[projectID]
        let hasTabOnScreen = layout.map { PaneLayout.items(in: $0).contains { $0.isSameKind(as: .browser(id)) } } ?? false
        if let layout, let focused, !hasTabOnScreen {
            // The first tab on screen goes to the right of what is being
            // worked in: the page beside the code that makes it.
            paneLayouts[projectID] = PaneLayout.split(layout, target: focused, with: .browser(id), axis: .horizontal)
        } else {
            paneLayouts[projectID] = PaneLayout.showing(.browser(id), in: layout, focused: focused)
        }
        selectedProjectID = projectID
        focusBrowser(id)
        page.focus()
        persist()
    }

    /// The tab took the keyboard: a click in it, or its page asking for focus.
    func focusBrowser(_ id: BrowserID) {
        guard let page = browserPages[id] else { return }
        lastBrowserByProject[page.projectID] = id
        guard focusedBrowser != id || editors.focused != nil else { return }
        focusedBrowser = id
        // Leaving a file writes it out, whichever pane is left for.
        editors.focused = nil
    }

    /// Whether one of the project's tabs has the keyboard, which is when its
    /// selected session must neither look nor act like the pane being typed in.
    func browserHasKeyboard(in projectID: ProjectID) -> Bool {
        focusedBrowser.flatMap { browserPages[$0] }?.projectID == projectID
    }

    /// The tab the Browser menu acts on: the one with the keyboard, or else
    /// the one the selected project was last in.
    var activeBrowserPage: BrowserPage? {
        if let id = focusedBrowser, let page = browserPages[id] { return page }
        guard let projectID = selectedProjectID else { return nil }
        if let id = lastBrowserByProject[projectID], let page = browserPages[id] { return page }
        let layout = paneLayouts[projectID]
        return browsers(in: projectID).first { page in
            layout.map { PaneLayout.contains(.browser(page.id), in: $0) } == true
        }
    }

    /// Closes a tab. The next of the project's tabs that is not on screen
    /// takes its pane, the way closing a terminal shows the next session.
    func closeBrowser(_ id: BrowserID) {
        guard let page = browserPages.removeValue(forKey: id) else { return }
        page.close()
        browserOrder.removeAll { $0 == id }
        let projectID = page.projectID
        if lastBrowserByProject[projectID] == id { lastBrowserByProject.removeValue(forKey: projectID) }
        let hadKeyboard = focusedBrowser == id
        if hadKeyboard { focusedBrowser = nil }

        if let layout = paneLayouts[projectID], PaneLayout.contains(.browser(id), in: layout) {
            let next = browsers(in: projectID).first { !PaneLayout.contains(.browser($0.id), in: layout) }
            if let next {
                paneLayouts[projectID] = PaneLayout.replacing(.browser(id), with: .browser(next.id), in: layout)
                if hadKeyboard { focusBrowser(next.id) }
            } else {
                paneLayouts[projectID] = PaneLayout.removing(.browser(id), from: layout)
            }
        }
        persist()
    }

    func moveBrowser(_ moved: BrowserID, beside target: BrowserID, side: RowDropSide) {
        let reordered = ListReordering.moving(moved, beside: target, side: side, in: browserOrder)
        guard reordered != browserOrder else { return }
        browserOrder = reordered
        persist()
    }

    /// Opens an address from somewhere in Relay: in the project's tab already
    /// on that server, or in a new one.
    func openInBrowser(_ url: URL, in projectID: ProjectID) {
        let sameServer = browsers(in: projectID).first { page in
            guard let current = URL(string: page.address) else { return false }
            return current.scheme == url.scheme && current.host == url.host && current.port == url.port
        }
        guard let page = sameServer else {
            newBrowserTab(in: projectID, at: url)
            return
        }
        if page.address != url.absoluteString { page.open(url) }
        selectBrowser(page.id)
    }

    /// Design mode, from the menu: turned on in a tab opened for it when the
    /// project has none yet.
    func toggleDesignMode() {
        if let page = activeBrowserPage {
            if !page.isDesignModeOn { selectBrowser(page.id) }
            page.toggleDesignMode()
            return
        }
        guard let projectID = selectedProjectID else { return }
        newBrowserTab(in: projectID)
        activeBrowserPage?.startDesignMode()
    }

    func openServiceInBrowser(_ service: ServiceDefinition, in projectID: ProjectID) {
        guard let url = url(of: service, in: projectID) else { return }
        openInBrowser(url, in: projectID)
    }

    func openPortInBrowser(_ port: ListeningPort) {
        guard let url = port.url, let projectID = selectedProjectID ?? projects.first?.id else { return }
        openInBrowser(url, in: projectID)
    }

    /// Hands a picked element to an agent: its description typed into the
    /// prompt, not sent, and the overlay back up for the next pick.
    func send(_ selection: DesignSelection, from page: BrowserPage, to sessionID: SessionID) {
        deliver(PendingInput(text: transcript(of: selection, from: page)), to: sessionID)
        page.resumePicking()
    }

    func send(_ selection: DesignSelection, from page: BrowserPage, toNewSessionFrom preset: SessionPreset) {
        createSession(from: preset, in: page.projectID, thenType: PendingInput(text: transcript(of: selection, from: page)))
        page.resumePicking()
    }

    func copy(_ selection: DesignSelection, from page: BrowserPage) {
        copyToClipboard(transcript(of: selection, from: page))
    }

    private func transcript(of selection: DesignSelection, from page: BrowserPage) -> String {
        DesignNoteTranscript.compose(selection.pick, note: page.note, screenshot: selection.screenshot)
    }

    private func addBrowserPage(_ page: BrowserPage) {
        let id = page.id
        page.onFocus = { [weak self] in self?.focusBrowser(id) }
        page.onRecordChange = { [weak self] in self?.persist() }
        // The page has tabs to open things in now, so a link that wants one
        // gets one, beside the tab it came from.
        page.onNewTab = { [weak self] url in
            guard let self, let projectID = self.browserPages[id]?.projectID else { return }
            self.newBrowserTab(in: projectID, at: url)
        }
        browserPages[id] = page
        browserOrder.append(id)
    }

    /// Where a new tab starts: the project's own dev server when it is up, and
    /// a blank page otherwise.
    private func startingAddress(for projectID: ProjectID) -> String {
        guard let service = project(projectID)?.defaultService,
              let url = url(of: service, in: projectID)
        else { return "" }
        return url.absoluteString
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

        // Asked on the next turn of the run loop: this is called from a view
        // body, and handing text over from inside one is a write to state
        // while SwiftUI is reading it.
        if queuedInput[sessionID] != nil {
            Task { [weak self] in self?.flushQueuedInput(for: sessionID) }
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
        guard let home = project(projectID)?.rootPath, let path = workingRoot(of: projectID) else { return }
        // Re-read each time rather than only at launch: a repository cloned
        // into a project that is already open must not need a relaunch to be
        // noticed, and asking is one look at the filesystem.
        let isRepository = GitProbe.isRepository(at: home)
        if isRepository {
            gitRepositories.insert(projectID)
        } else {
            gitRepositories.remove(projectID)
        }
        Task { [weak self] in
            // Only Sendable values cross into the detached task; the model stays
            // firmly on the main actor.
            let (status, found, own) = await Task.detached(priority: .utility) {
                () -> (GitStatus?, [GitWorktree]?, String?) in
                let status = GitProbe.status(at: path)
                guard isRepository, let found = GitWorktreeActions.list(at: home) else {
                    return (status, nil, nil)
                }
                // Git's spelling of the checkout just read, which is what the
                // sidebar looks its status up by.
                return (status, found, WorktreeMembership.worktree(containing: path, among: found)?.path)
            }.value
            guard let self else { return }
            // A list that could not be read is not an empty one: keeping the
            // last answer is what stops a slow `git` sending the panel back to
            // the project's own checkout.
            if let found { self.adopt(found, in: projectID) }
            self.worktreeListsRead.insert(projectID)
            // The answer is about the checkout that was open when it was asked.
            if self.workingRoot(of: projectID) == path {
                if let status {
                    self.gitStatuses[projectID] = status
                    if let own { self.worktreeStatuses[own] = status }
                } else {
                    self.gitStatuses.removeValue(forKey: projectID)
                }
            }

            // The other checkouts only once there are others, and only after
            // the sidebar has been given the list: each is a `git status` of
            // its own, and a project with a dozen worktrees would otherwise
            // show its sessions ungrouped for as long as all of them take.
            guard let found, found.count > 1 else { return }
            let others = await Task.detached(priority: .utility) { () -> [String: GitStatus] in
                var others: [String: GitStatus] = [:]
                for worktree in found where worktree.path != own && !worktree.isPrunable {
                    others[worktree.path] = GitProbe.status(at: worktree.path)
                }
                return others
            }.value
            self.worktreeStatuses.merge(others) { $1 }
        }
    }

    /// Whether the sidebar is still waiting for the project's first list of
    /// worktrees. Until it arrives there is no telling whether its sessions
    /// are one list or several groups, and drawing one then the other moves
    /// every row under the pointer. The chat has no repository to ask.
    func isReadingWorktrees(in projectID: ProjectID) -> Bool {
        projectID != .chat && !worktreeListsRead.contains(projectID)
    }

    // MARK: - Worktrees

    /// The folder a project's working copy is read from, and a new session
    /// starts in: the worktree being looked at, or the project's own.
    ///
    /// The project's own folder is given as the project spells it rather than
    /// as git does: they differ when it was added through a symlink, and
    /// everything already read about it is filed under the former.
    func workingRoot(of projectID: ProjectID) -> String? {
        guard let project = project(projectID) else { return nil }
        guard let active = activeWorktree(of: projectID), active != homeWorktree(of: projectID) else {
            return project.rootPath
        }
        return active.path
    }

    /// The worktree the project's own folder is.
    func homeWorktree(of projectID: ProjectID) -> GitWorktree? {
        guard let root = project(projectID)?.rootPath else { return nil }
        return WorktreeMembership.worktree(containing: root, among: visibleWorktrees(in: projectID))
    }

    /// The worktree being looked at: the one chosen, or the project's own.
    func activeWorktree(of projectID: ProjectID) -> GitWorktree? {
        let visible = visibleWorktrees(in: projectID)
        if let active = activeWorktreePaths[projectID], let chosen = visible.first(where: { $0.path == active }) {
            return chosen
        }
        return homeWorktree(of: projectID)
    }

    /// A worktree whose directory is gone has nothing to show.
    func visibleWorktrees(in projectID: ProjectID) -> [GitWorktree] {
        (worktrees[projectID] ?? []).filter { !$0.isPrunable }
    }

    /// Only once there is a second one: a project with a single checkout looks
    /// exactly as it did before worktrees existed.
    func showsWorktrees(in projectID: ProjectID) -> Bool {
        visibleWorktrees(in: projectID).count > 1
    }

    /// The terminals in the order the sidebar shows them, which is the order
    /// `⌘1`…`⌘9` count in: grouped by worktree once there are several.
    func listedSessions(in projectID: ProjectID) -> [SessionSnapshot] {
        guard showsWorktrees(in: projectID) else { return interactiveSessions(in: projectID) }
        return worktreeGroups(in: projectID).flatMap(\.sessions)
    }

    func worktreeGroups(in projectID: ProjectID) -> [WorktreeGroup] {
        guard let project = project(projectID) else { return [] }
        return WorktreeMembership.groups(
            of: interactiveSessions(in: projectID),
            among: worktrees[projectID] ?? [],
            home: project.rootPath
        )
    }

    func worktree(of session: SessionSnapshot) -> GitWorktree? {
        WorktreeMembership.worktree(
            containing: session.workingDirectory,
            among: visibleWorktrees(in: session.projectID)
        )
    }

    /// The branch under a session is its own worktree's.
    func gitStatus(of session: SessionSnapshot) -> GitStatus? {
        if let path = worktree(of: session)?.path, let status = worktreeStatuses[path] {
            return status
        }
        return gitStatuses[session.projectID]
    }

    func isActiveWorktree(_ worktree: GitWorktree, in projectID: ProjectID) -> Bool {
        activeWorktree(of: projectID) == worktree
    }

    /// The project's own folder, which is removed by removing the project, and
    /// the main worktree, which git will not remove at all.
    func canRemoveWorktree(_ worktree: GitWorktree, in projectID: ProjectID) -> Bool {
        !worktree.isMain && worktree != homeWorktree(of: projectID)
    }

    /// Where a branch is checked out, when that is somewhere other than the
    /// worktree being looked at. Git will not check one branch out twice, so
    /// going to that branch means going to where it already is.
    func worktree(checkingOut branch: String, in projectID: ProjectID) -> GitWorktree? {
        let active = activeWorktree(of: projectID)
        return visibleWorktrees(in: projectID).first { $0.branch == branch && $0 != active }
    }

    func sessions(in worktree: GitWorktree, of projectID: ProjectID) -> [SessionSnapshot] {
        sessions(in: projectID).filter { self.worktree(of: $0) == worktree }
    }

    /// Subagents a session elsewhere started that are working in this
    /// worktree — Claude Code's isolated ones, most often.
    func visitingSubagents(in worktree: GitWorktree, of projectID: ProjectID) -> [SubagentSnapshot] {
        worktreeGroups(in: projectID).first { $0.worktree == worktree }?.visitors.map(\.subagent) ?? []
    }

    /// Makes a worktree the one the panel describes and new sessions start in.
    func activateWorktree(_ path: String, in projectID: ProjectID) {
        let previous = workingRoot(of: projectID)
        // Recorded even when it changes nothing, so that the selected session
        // is not followed later over a choice that was made by hand.
        activeWorktreePaths[projectID] = path
        guard workingRoot(of: projectID) != previous else { return }
        forgetWorkingCopy(of: projectID)
        gitStatuses[projectID] = worktreeStatuses[path]
        refreshGit(for: projectID)
    }

    /// Goes to a worktree: the panel turns to it, and so does the terminal
    /// when there is a session in it to show.
    func openWorktree(_ worktree: GitWorktree, in projectID: ProjectID) {
        activateWorktree(worktree.path, in: projectID)
        let inside = sessions(in: worktree, of: projectID).filter { !$0.role.isService }
        guard let first = inside.first, !inside.contains(where: { $0.id == selectedSessionID }) else { return }
        selectSession(first.id)
    }

    /// Takes a fresh list of a project's worktrees and lets go of what was
    /// known about the ones that are gone.
    func adopt(_ found: [GitWorktree], in projectID: ProjectID) {
        let gone = Set((worktrees[projectID] ?? []).map(\.path)).subtracting(found.map(\.path))
        for path in gone {
            worktreeStatuses.removeValue(forKey: path)
            // Kept per folder and let go of nowhere else: a warm ESLint is a
            // `node` process of its own, and the file list and the symbol
            // index grow with the checkout they were read from.
            lint.stop(root: path)
            files.invalidate(root: path)
            symbols.invalidate(root: path)
        }
        worktrees[projectID] = found
        keepWorktreeNotes(listedIn: found, in: projectID)

        if let active = activeWorktreePaths[projectID],
           !found.contains(where: { $0.path == active && !$0.isPrunable }) {
            // Removed somewhere else while it was being looked at.
            activeWorktreePaths.removeValue(forKey: projectID)
            forgetWorkingCopy(of: projectID)
            refreshGit(for: projectID)
        } else if activeWorktreePaths[projectID] == nil,
                  let selected = selectedSessionID.flatMap({ sessions[$0] }),
                  selected.projectID == projectID,
                  let owner = worktree(of: selected) {
            // The session restored at launch was selected before git had said
            // which worktree it is in.
            activateWorktree(owner.path, in: projectID)
        }
    }

    /// Drops what was read from the previous worktree, so the panel does not
    /// spend a refresh showing one checkout's changes under another's name.
    private func forgetWorkingCopy(of projectID: ProjectID) {
        gitChanges.removeValue(forKey: projectID)
        mergeStates.removeValue(forKey: projectID)
        todoScans.removeValue(forKey: projectID)
        pickedTodoIDs.removeValue(forKey: projectID)
        branches.removeValue(forKey: projectID)
        expandedChanges.removeAll()
        fileDiffs.removeAll()
        diffContext.removeAll()
        let prefix = key(projectID, "")
        conflicts = conflicts.filter { !$0.key.hasPrefix(prefix) }
        outgoing = outgoing.filter { !$0.key.hasPrefix(prefix) }
        refsWithNoRemoteBranch = refsWithNoRemoteBranch.filter { !$0.hasPrefix(prefix) }
    }

    /// Opens the panel that starts a worktree, reading the branches it can
    /// start from while it appears.
    func beginNewWorktree(in projectID: ProjectID) {
        worktreeCreationFailure = nil
        presentModal(.newWorktree(projectID))
        refreshBranches(for: projectID)
    }

    /// Makes a worktree for `name` and opens it, starting `preset` in it with
    /// `prompt` handed over once the agent is ready for it.
    func createWorktree(
        named name: String,
        from base: String?,
        starting preset: SessionPreset?,
        prompt: String,
        in projectID: ProjectID
    ) {
        guard let project = project(projectID), !isCreatingWorktree else { return }
        let branch = WorktreeNaming.branchName(from: name)
        guard !branch.isEmpty else { return }
        if let holder = worktree(holding: branch, in: projectID) {
            worktreeCreationFailure = Self.alreadyOpenMessage(branch, in: holder)
            return
        }

        isCreatingWorktree = true
        worktreeCreationFailure = nil
        Task { [weak self] in
            guard let self else { return }
            let creation = await self.addWorktree(named: name, from: base, in: project)
            self.isCreatingWorktree = false
            switch creation {
            case let .created(created):
                self.dismissModal()
                self.openCreatedWorktree(created, starting: preset, prompt: prompt, in: projectID)
            case let .refused(failure):
                self.worktreeCreationFailure = Self.summarised(failure)
            case let .alreadyOpen(branch, holder):
                self.worktreeCreationFailure = Self.alreadyOpenMessage(branch, in: holder)
            case .unusableName, .unlisted:
                return
            }
        }
    }

    /// What asking git for a worktree came to.
    enum WorktreeCreation: Equatable, Sendable {
        case created(GitWorktree)
        /// Nothing git would accept as a branch is left of the name.
        case unusableName
        /// Git will not check a branch out twice, and this one already is.
        case alreadyOpen(branch: String, in: GitWorktree)
        /// What git said when it refused.
        case refused(String)
        /// Git made it, but its list does not show it, so there is nothing to open.
        case unlisted(branch: String)
    }

    /// Makes a worktree for `name` in Relay's folder for the repository, with
    /// the same branch, folder and marker whoever asks, and takes git's list
    /// again. Opens nothing and says nothing: that is the caller's.
    func addWorktree(named name: String, from base: String?, in project: Project) async -> WorktreeCreation {
        let projectID = project.id
        let home = project.rootPath
        let branch = WorktreeNaming.branchName(from: name)
        guard !branch.isEmpty else { return .unusableName }
        if let holder = worktree(holding: branch, in: projectID) { return .alreadyOpen(branch: branch, in: holder) }
        let main = visibleWorktrees(in: projectID).first(where: \.isMain)?.path ?? home
        let repository = WorktreeNaming.repositoryName(mainWorktree: main)
        let parent = RelayPaths.worktreesDirectory

        let (failure, found) = await Task.detached(priority: .userInitiated) {
            () -> (String?, [GitWorktree]?) in
            let directory = WorktreeNaming.directory(for: branch, repository: repository, in: parent) {
                FileManager.default.fileExists(atPath: $0)
            }
            let failure = GitWorktreeActions.add(branch: branch, from: base, at: directory, in: home)
            return (failure, GitWorktreeActions.list(at: home))
        }.value
        if let found { adopt(found, in: projectID) }
        if let failure { return .refused(failure) }
        guard let created = found?.first(where: { $0.branch == branch }) else { return .unlisted(branch: branch) }
        return .created(created)
    }

    /// Turns the panel to a worktree just made and starts `preset` in it, with
    /// `prompt` typed once the agent is ready for it.
    func openCreatedWorktree(
        _ created: GitWorktree,
        starting preset: SessionPreset?,
        prompt: String,
        in projectID: ProjectID
    ) {
        activateWorktree(created.path, in: projectID)
        guard let preset else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        createSession(from: preset, in: projectID, thenType: text.isEmpty ? nil : PendingInput(text: text))
    }

    /// The worktree that has `branch` checked out already, if one has.
    func worktree(holding branch: String, in projectID: ProjectID) -> GitWorktree? {
        visibleWorktrees(in: projectID).first { $0.branch == branch }
    }

    private static func alreadyOpenMessage(_ branch: String, in holder: GitWorktree) -> String {
        String(
            format: relayLocalized("%@ is already open in %@."),
            branch,
            HomeRelativePath.abbreviating(holder.path)
        )
    }

    /// Removes the folder, closes what ran in it and settles its branch, and
    /// says how it went without showing anything: the caller decides what to
    /// say.
    ///
    /// The directory goes first and the sessions after, so a refusal leaves
    /// everything as it was. The branch goes too when Relay made it and git
    /// agrees nothing on it would be lost; it is settled last, once the
    /// sessions are closed and the sidebar has let go of the folder, so that
    /// judging it never holds either of them up.
    ///
    /// Given a `forecast`, the branch is settled the way the person was told
    /// it would be rather than judged again.
    func performWorktreeRemoval(
        _ worktree: GitWorktree,
        discardingChanges: Bool,
        in projectID: ProjectID,
        following forecast: GitWorktreeActions.BranchForecast? = nil
    ) async -> WorktreeRemoval {
        guard let home = project(projectID)?.rootPath else {
            return WorktreeRemoval(failure: relayLocalized("There is no such project."), branch: .untouched)
        }
        guard canRemoveWorktree(worktree, in: projectID) else {
            let reason = worktree.isMain
                ? relayLocalized("Git does not remove the main worktree: the repository lives in it.")
                : relayLocalized("The project's own folder goes only with the project.")
            return WorktreeRemoval(failure: reason, branch: .untouched)
        }
        let running = sessions(in: worktree, of: projectID).map(\.id)
        let (failure, found) = await Task.detached(priority: .userInitiated) {
            () -> (String?, [GitWorktree]?) in
            if let failure = GitWorktreeActions.remove(worktree, force: discardingChanges, in: home) {
                return (failure, nil)
            }
            return (nil, GitWorktreeActions.list(at: home))
        }.value
        if let failure { return WorktreeRemoval(failure: failure, branch: .untouched) }
        // Not remembered for ⌘⇧T: what they would reopen into is gone.
        for id in running { close(id, remembering: false) }
        if let found { adopt(found, in: projectID) }
        let settled = await Task.detached(priority: .userInitiated) { () -> GitWorktreeActions.BranchSettlement in
            if let forecast { return GitWorktreeActions.settleBranch(following: forecast, in: home) }
            return GitWorktreeActions.settleBranch(of: worktree, in: home)
        }.value
        let kept = settled.outcome == .keptUnmerged ? settled.head : nil
        return WorktreeRemoval(failure: nil, branch: settled.outcome, branchHead: kept)
    }

    /// Asks to remove a worktree once its branch has been judged, so that the
    /// question can say whether the branch goes with it — and, when it
    /// stays, how much on it is not merged — before anything is removed.
    ///
    /// Judging can mean fetching the base, which takes a moment on a slow
    /// network; the heading says it is looking meanwhile.
    func requestWorktreeRemoval(_ worktree: GitWorktree, in projectID: ProjectID) {
        guard let home = project(projectID)?.rootPath, canRemoveWorktree(worktree, in: projectID),
              !worktreeRemovalsBeingChecked.contains(worktree.path) else { return }
        worktreeRemovalsBeingChecked.insert(worktree.path)
        Task { [weak self] in
            let forecast = await Task.detached(priority: .userInitiated) {
                GitWorktreeActions.forecastBranch(of: worktree, in: home)
            }.value
            guard let self else { return }
            self.worktreeRemovalsBeingChecked.remove(worktree.path)
            self.worktreePendingRemoval = WorktreeRemovalRequest(worktree: worktree, forecast: forecast)
        }
    }

    /// The sidebar's way in: removes the worktree and says what did not go,
    /// the folder or its branch.
    func removeWorktree(
        _ worktree: GitWorktree,
        discardingChanges: Bool,
        in projectID: ProjectID,
        following forecast: GitWorktreeActions.BranchForecast? = nil
    ) {
        worktreePendingRemoval = nil
        Task { [weak self] in
            guard let self else { return }
            let removal = await self.performWorktreeRemoval(
                worktree,
                discardingChanges: discardingChanges,
                in: projectID,
                following: forecast
            )
            if let failure = removal.failure {
                self.present(ToastContent(
                    kind: .error,
                    title: String(format: relayLocalized("Could not remove %@"), worktree.name),
                    message: Self.summarised(failure)
                ))
                return
            }
            if removal.branch == .keptUnmerged, let branch = worktree.branch, let head = removal.branchHead {
                self.presentKeptBranch(branch, at: head, in: projectID)
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
        guard let path = workingRoot(of: projectID) else { return }
        Task { [weak self] in
            let copy = await Task.detached(priority: .utility) {
                GitWorkingCopyReader.changes(at: path)
            }.value
            let merge = await Task.detached(priority: .utility) {
                GitMergeStateReader.read(at: path)
            }.value
            guard let self, self.workingRoot(of: projectID) == path else { return }
            self.mergeStates[projectID] = merge
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
        guard let root = workingRoot(of: projectID) else { return }
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

    /// Opens the panel that asks where a pull or a push is going.
    ///
    /// Asked rather than done, because the answer is not always the last one:
    /// a branch can be pushed somewhere other than its upstream, and a force
    /// push is a thing to see spelled out before it happens.
    func planTransfer(_ direction: GitTransfer.Direction, in projectID: ProjectID) {
        presentModal(.gitTransfer(projectID: projectID, direction: direction))
        refreshRemotes(for: projectID)
        refreshBranches(for: projectID)
    }

    func refreshRemotes(for projectID: ProjectID) {
        guard let path = workingRoot(of: projectID) else { return }
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                GitTransferReader.remotes(at: path)
            }.value
            self?.remotes[projectID] = found
        }
    }

    func remotes(in projectID: ProjectID) -> [String] {
        remotes[projectID] ?? []
    }

    /// Whether the answer is known, as against known to be empty: a repository
    /// with no remote and one that has not been asked yet need different
    /// things said about them.
    func hasReadRemotes(_ projectID: ProjectID) -> Bool {
        remotes[projectID] != nil
    }

    /// The commits a push would send, for the ref it would send them to.
    func outgoingCommits(in projectID: ProjectID, against ref: String) -> [GitCommitSummary]? {
        outgoing[key(projectID, ref)]
    }

    /// True when the remote has no such branch yet, so a push would create it.
    func remoteBranchIsNew(in projectID: ProjectID, ref: String) -> Bool {
        refsWithNoRemoteBranch.contains(key(projectID, ref))
    }

    func loadOutgoingCommits(in projectID: ProjectID, against ref: String) {
        guard let path = workingRoot(of: projectID) else { return }
        let identifier = key(projectID, ref)
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) {
                GitTransferReader.outgoing(at: path, against: ref)
            }.value
            guard let self else { return }
            if let found {
                self.outgoing[identifier] = found
                self.refsWithNoRemoteBranch.remove(identifier)
            } else {
                // git refused the range, which for a well-formed ref means it
                // does not know that branch.
                self.outgoing.removeValue(forKey: identifier)
                self.refsWithNoRemoteBranch.insert(identifier)
            }
        }
    }

    private func key(_ projectID: ProjectID, _ ref: String) -> String {
        "\(projectID.rawValue)\t\(ref)"
    }

    /// Runs what the panel was holding.
    func run(_ transfer: GitTransfer, in projectID: ProjectID) {
        runningTransfer = transfer
        let arguments = transfer.arguments
        perform(
            in: projectID,
            title: relayLocalized(transfer.direction == .pull ? "Pull failed" : "Push failed"),
            action: { root in
                GitActions.run(arguments, at: root)
            },
            onFailure: { [weak self] in
                // A pull that stops on a conflict has not failed so much as
                // asked a question, and the panel that answers it is more use
                // than the message saying it was asked.
                self?.presentConflictsIfAny(in: projectID)
            }
        ) { [weak self] in
            self?.present(ToastContent(
                kind: .success,
                title: transfer.commandLine,
                message: relayLocalized("Done")
            ))
            self?.dismissModal()
        }
        // Both ends of it moved: what is outgoing, and which branches exist.
        refreshBranches(for: projectID)
    }

    // MARK: - Conflicts

    func mergeState(in projectID: ProjectID) -> GitMergeState {
        mergeStates[projectID] ?? GitMergeState(operation: nil)
    }

    func conflict(_ path: String, in projectID: ProjectID) -> GitConflictFile? {
        conflicts[key(projectID, path)]
    }

    /// Opens the merge panes for one file, having read it first.
    ///
    /// Read here rather than by the panel: a view that fetches its own subject
    /// draws once with nothing in it, and a panel that opens empty and fills
    /// in a moment later is indistinguishable from one that is broken.
    func openMerge(_ path: String, in projectID: ProjectID) {
        loadConflict(path, in: projectID)
        presentModal(.merge(projectID: projectID, path: path))
    }

    /// Opens the panel that resolves what is conflicted.
    func resolveConflicts(in projectID: ProjectID) {
        presentModal(.conflicts(projectID))
        refreshChanges(for: projectID)
    }

    /// Reads one conflicted file as the three versions of itself.
    func loadConflict(_ path: String, in projectID: ProjectID) {
        guard let root = workingRoot(of: projectID) else { return }
        let identifier = key(projectID, path)
        Task { [weak self] in
            let parsed = await Task.detached(priority: .userInitiated) { () -> GitConflictFile? in
                GitConflictReader.read(path, at: root)
            }.value
            guard let self else { return }
            if let parsed {
                self.conflicts[identifier] = parsed
            } else {
                self.conflicts.removeValue(forKey: identifier)
            }
        }
    }

    /// Takes one side of a conflicted file whole.
    ///
    /// `git checkout --ours` rather than a rewrite: for a file deleted on one
    /// side there is no text to choose between, and for one both sides merely
    /// edited it is the same answer said in git's own words.
    func acceptSide(_ side: GitConflictChoice, of path: String, in projectID: ProjectID) {
        guard side != .both else { return }
        perform(
            in: projectID,
            title: String(format: relayLocalized("Could not resolve %@"), path)
        ) { root in
            GitActions.acceptSide(side == .ours ? "--ours" : "--theirs", of: path, at: root)
        }
    }

    /// Writes what the merge panes ended up with, and stages it.
    func applyMerge(_ contents: String, to path: String, in projectID: ProjectID) {
        perform(
            in: projectID,
            title: String(format: relayLocalized("Could not resolve %@"), path)
        ) { root in
            GitActions.resolve(path, contents: contents, at: root)
        } onSuccess: { [weak self] in
            guard let self else { return }
            let identifier = self.key(projectID, path)
            self.conflicts.removeValue(forKey: identifier)
            self.dismissModal()
        }
    }

    /// Finishes the rebase, merge or cherry-pick once nothing is conflicted.
    func finishMergeOperation(in projectID: ProjectID) {
        guard let operation = mergeState(in: projectID).operation else { return }
        perform(
            in: projectID,
            title: relayLocalized("Could not continue")
        ) { root in
            GitActions.finish(operation, at: root)
        } onSuccess: { [weak self] in
            self?.conflicts.removeAll()
            self?.refreshChanges(for: projectID)
            // Gone, if it went: the panel has nothing left to show and a
            // dialog that stays open over a finished rebase invites a second
            // one.
            if self?.mergeState(in: projectID).isInProgress != true {
                self?.dismissModal()
            }
        }
    }

    func abortMergeOperation(in projectID: ProjectID) {
        guard let operation = mergeState(in: projectID).operation else { return }
        perform(
            in: projectID,
            title: relayLocalized("Could not abort")
        ) { root in
            GitActions.abort(operation, at: root)
        } onSuccess: { [weak self] in
            self?.conflicts.removeAll()
            self?.dismissModal()
        }
    }

    /// Hands over what was waiting, once there is a prompt to hand it to.
    ///
    /// The status is the signal: Relay already works out when an agent has
    /// stopped printing and is waiting for a person, which is exactly the
    /// moment its prompt will keep what is typed into it.
    private func flushQueuedInput(for snapshot: SessionSnapshot) {
        guard let pending = queuedInput[snapshot.id] else { return }
        guard PendingInputPolicy.isReady(
            status: snapshot.status,
            hasTerminal: surfaceCache.existing(snapshot.id) != nil
        ) else { return }

        queuedInput.removeValue(forKey: snapshot.id)
        type(pending.text, into: snapshot.id)
        // Only now: until the text is in the prompt, the notes are the only
        // copy of it there is.
        forgetComments(pending.commentIDs)
    }

    /// Tries again for a session whose terminal has just appeared.
    ///
    /// The other half of the wait. A session can reach its prompt before
    /// anything is drawn for it, and the daemon then has no reason to send
    /// another update — so the arrival of the terminal has to ask as well.
    func flushQueuedInput(for sessionID: SessionID) {
        guard let snapshot = sessions[sessionID] else { return }
        flushQueuedInput(for: snapshot)
    }

    /// What is still waiting to be typed into a session, if anything.
    var sessionsWithQueuedInput: Set<SessionID> { Set(queuedInput.keys) }

    // MARK: - Branches

    func isLoadingBranches(_ projectID: ProjectID) -> Bool {
        projectsReadingBranches.contains(projectID)
    }

    func refreshBranches(for projectID: ProjectID) {
        guard let path = workingRoot(of: projectID) else { return }
        projectsReadingBranches.insert(projectID)
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                GitWorkingCopyReader.branches(at: path)
            }.value
            guard let self else { return }
            self.projectsReadingBranches.remove(projectID)
            // Which branch is current is an answer about one checkout.
            guard self.workingRoot(of: projectID) == path else { return }
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
        deliver(
            PendingInput(text: ReviewCommentTranscript.compose(comments), commentIDs: comments.map(\.id)),
            to: sessionID
        )
    }

    /// Types into a session that is already running, once it is listening.
    func deliver(_ pending: PendingInput, to sessionID: SessionID) {
        // Selected first, so the terminal exists to be asked how it wants its
        // text before anything is typed into it.
        selectSession(sessionID)
        queuedInput[sessionID] = pending
        if let snapshot = sessions[sessionID] {
            flushQueuedInput(for: snapshot)
        }
        focusTerminal()
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
            thenType: PendingInput(
                text: ReviewCommentTranscript.compose(comments),
                commentIDs: comments.map(\.id)
            )
        )
    }

    private func forgetComments(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let sent = Set(ids)
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
              let root = workingRoot(of: projectID),
              !projectsScanningTodos.contains(projectID)
        else { return }
        let markers = TodoScanner.markers(from: project.todoMarkers)

        projectsScanningTodos.insert(projectID)
        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) {
                TodoScanner.scan(at: root, markers: markers)
            }.value
            guard let self else { return }
            self.projectsScanningTodos.remove(projectID)
            // Another worktree was opened while this one was being read.
            guard self.workingRoot(of: projectID) == root else { return }
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
            thenType: PendingInput(text: TodoTranscript.compose(todos, instruction: instruction))
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
        onFailure: (@MainActor () -> Void)? = nil,
        onSuccess: (@MainActor () -> Void)? = nil
    ) {
        guard let root = workingRoot(of: projectID) else { return }
        Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) {
                action(root)
            }.value
            guard let self else { return }
            self.isCommitting = false
            self.runningRemoteCommand = nil
            self.runningTransfer = nil
            if let failure {
                self.present(ToastContent(kind: .error, title: title, message: Self.summarised(failure)))
                onFailure?()
            } else {
                onSuccess?()
            }
            self.refreshChanges(for: projectID)
            self.refreshGit(for: projectID)
        }
    }

    /// Opens the conflict panel when the repository has been left mid-operation.
    ///
    /// Read rather than inferred from the command that failed: a pull can fail
    /// for a dozen reasons that leave nothing to resolve, and the repository
    /// itself is the only thing that knows which happened.
    private func presentConflictsIfAny(in projectID: ProjectID) {
        guard let root = workingRoot(of: projectID) else { return }
        Task { [weak self] in
            let state = await Task.detached(priority: .userInitiated) {
                GitMergeStateReader.read(at: root)
            }.value
            let copy = await Task.detached(priority: .userInitiated) {
                GitWorkingCopyReader.changes(at: root)
            }.value
            guard let self else { return }
            self.mergeStates[projectID] = state
            if let copy { self.gitChanges[projectID] = copy }
            guard state.isInProgress || !(copy?.conflicted.isEmpty ?? true) else { return }
            self.presentModal(.conflicts(projectID))
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
        if visible {
            usage.start()
            resources.start()
        } else {
            usage.stop()
            resources.stop()
        }
    }

    /// Whether the terminals on screen ended up on the GPU.
    ///
    /// Asked of the renderers rather than remembered: the setting is what the
    /// user wants, and a machine is free to refuse it. Nothing on screen yet
    /// means there is nothing to report either way.
    var isDrawingTerminalsOnGPU: Bool {
        surfaceCache.all.contains { $0.isDrawingOnGPU }
    }

    /// ⌘+ and ⌘−, on whatever the keyboard is in.
    ///
    /// The same rule as ⌘W: a file open in front of you is what the shortcut
    /// is about, and the terminal behind it is not. One size for every
    /// terminal and one for every file rather than per pane — it is how the
    /// user reads, not something about a particular file.
    ///
    /// A picture or a PDF in front of you has no text size to change, so
    /// there the same keys zoom it — which is what they do in every viewer
    /// on the machine.
    func stepFontSize(by delta: Double) {
        guard let path = editors.focused else { return stepTerminalFontSize(by: delta) }
        if let preview = editors.previews[path] { return preview.zoom(delta > 0 ? .zoomIn : .zoomOut) }
        setEditorFontSize(Double(TerminalZoom.stepped(CGFloat(editorFontSize), by: CGFloat(delta))))
    }

    func resetFontSize() {
        guard let path = editors.focused else { return resetTerminalFontSize() }
        if let preview = editors.previews[path] { return preview.zoom(.fit) }
        setEditorFontSize(Double(TerminalZoom.defaultSize))
    }

    private func setEditorFontSize(_ size: Double) {
        guard size != editorFontSize else { return }
        editorFontSize = size
        persist()
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

    /// Typed into rather than stepped to: every other reader lets the size be
    /// said outright, and reaching 20 from 13 is seven presses of a button.
    func setTerminalFontSize(typed text: String) {
        guard let size = TerminalZoom.parsed(text) else { return }
        setTerminalFontSize(Double(size))
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
        let list = listedSessions(in: projectID)
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
        guard let root = workingRoot(of: entry.projectID) else { return }
        launch(SessionSpec(
            projectID: entry.projectID,
            kind: entry.kind,
            name: SessionNaming.nextName(
                base: entry.name,
                existing: sessions(in: entry.projectID).map(\.name)
            ),
            workingDirectory: root,
            command: entry.command
        ))
    }

    // MARK: - Right sidebar

    /// Whether a tab has anything to show for this project.
    ///
    /// Docker is the case that matters: a project with no containers and no
    /// compose file has nothing behind that tab, and an empty panel is a worse
    /// answer than a disabled tab that says why.
    /// Which tabs the panel offers for a project.
    ///
    /// The chat has no repository, no services, no containers and no codebase
    /// to scan for TODOs, and four tabs that are permanently empty say less
    /// than none. Its conversations are the whole of what there is to show.
    func tabs(for project: Project) -> [RightSidebarTab] {
        project.isChat ? [.history] : RightSidebarTab.allCases
    }

    func isTabAvailable(_ tab: RightSidebarTab, for project: Project) -> Bool {
        switch tab {
        case .services, .history:
            true
        case .docker:
            projectFacts[project.id]?.hasDocker == true
                || dockerSnapshots[project.id]?.containers.isEmpty == false
        case .git:
            gitRepositories.contains(project.id) || gitStatuses[project.id] != nil
        case .todo, .files:
            true
        }
    }

    func tabTooltip(_ tab: RightSidebarTab, for project: Project) -> String {
        guard !isTabAvailable(tab, for: project) else { return tab.localizedTitle }
        switch tab {
        case .git:
            return "\(tab.localizedTitle) — " + relayLocalized("not a git repository. Click to look again.")
        case .docker:
            return projectsCheckingDocker.contains(project.id)
                ? relayLocalized("Docker — checking…")
                : relayLocalized("Docker — nothing found. Click to check again.")
        default:
            return "\(tab.localizedTitle) — " + relayLocalized("coming soon")
        }
    }

    func isCheckingDocker(_ projectID: ProjectID) -> Bool {
        projectsCheckingDocker.contains(projectID)
    }

    /// Looks for a repository again in a project whose Git tab is off.
    ///
    /// The same reason the Docker tab can be asked again: a project is often
    /// adopted before `git init` or a clone has happened in it, and an
    /// answer from that moment is not worth keeping for the life of the app.
    func recheckGit(for projectID: ProjectID) {
        refreshGit(for: projectID)
        refreshChanges(for: projectID)
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

    /// Closes a panel that finished its work, if it is still the one in front.
    /// The work may have taken a while, and in that while the person may have
    /// closed it themselves — in which case the panel now in front is one they
    /// are looking at, and closing it would be closing the wrong thing.
    func dismissModal(_ modal: RelayModal) {
        guard modalStack.last == modal else { return }
        modalStack.removeLast()
    }

    /// Closes every panel, for an action whose result is in the window
    /// behind them: an issue handed to an agent is read in its terminal.
    func dismissAllModals() {
        modalStack.removeAll()
    }

    /// The settings of whichever project is in front, which is the only one the
    /// command and the shortcut could mean.
    func openProjectSettings() {
        // The chat has no settings — the keyboard shortcut reaches this too,
        // and a panel of controls that write nowhere is worse than none.
        guard let projectID = selectedProjectID, projectID != .chat else { return }
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

    /// Picks a tab, and never un-picks one.
    ///
    /// Clicking the tab that is already open used to close the panel, which is
    /// a second meaning for one target: the click that means "show me the
    /// changes" and the click that means "take the panel away" were the same
    /// gesture, and the one nobody intended happened whenever the panel was
    /// already showing what was asked for. Closing it is the toggle in the
    /// title bar, and its shortcut.
    func selectRightSidebarTab(_ tab: RightSidebarTab) {
        guard let project = selectedProject,
              tabs(for: project).contains(tab),
              isTabAvailable(tab, for: project)
        else { return }
        rightSidebarTab = tab
        isRightSidebarVisible = true
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
                    title: String(format: relayLocalized("%@ failed"), "docker \(action.rawValue)"),
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
           let match = projects.first(where: { project in
               ([project.rootPath] + (worktrees[project.id] ?? []).map(\.path))
                   .contains { DirectoryContainment.contains(directory, in: $0) }
           }) {
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
                    title: String(format: relayLocalized("Stopped %@ (%@)"), port.processName, String(port.port)),
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
            closedSessions: closedSessions,
            sessionOrder: sessionOrder.map(\.rawValue),
            isRightSidebarVisible: isRightSidebarVisible,
            isLeftSidebarVisible: isLeftSidebarVisible,
            rightSidebarTab: rightSidebarTab.rawValue,
            language: language,
            checksForUpdates: checksForUpdates,
            showsStatusBar: showsStatusBar,
            usageBarDetail: usageBarDetail,
            terminalFontSize: terminalFontSize,
            editorFontSize: editorFontSize,
            showsMarkdownPreview: showsMarkdownPreview,
            terminalUsesGPURendering: terminalUsesGPURendering,
            reviewComments: reviewComments,
            paneLayouts: Dictionary(uniqueKeysWithValues: paneLayouts.map { ($0.key.rawValue, $0.value) }),
            browserTabs: browserOrder.compactMap { browserPages[$0]?.record },
            worktreeNotes: worktreeNotes.persisted,
            tracker: tracker.settings
        )
    }

    func persist() {
        store.scheduleSave(snapshotState())
    }

    func persistImmediately() {
        store.saveNow(snapshotState())
    }
}

/// A worktree someone asked to remove, with what removing it would do to its
/// branch, judged before the question was put.
struct WorktreeRemovalRequest: Equatable, Identifiable {
    var worktree: GitWorktree
    var forecast: GitWorktreeActions.BranchForecast

    var id: String { worktree.path }
}

/// What became of removing a worktree.
struct WorktreeRemoval: Equatable, Sendable {
    /// Why it was not removed; nil when it was.
    var failure: String?
    var branch: GitWorktreeActions.BranchOutcome
    /// Where a kept branch pointed when it was judged, which is what deleting
    /// it anyway is held to; nil unless the branch was kept.
    var branchHead: String? = nil
}
