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
    private(set) var projectFacts: [ProjectID: ProjectFacts] = [:]
    /// The image each project is drawn with, once it has been read.
    ///
    /// Observed, because a tile has to redraw when its icon arrives, and written
    /// only from a task — never while a view is drawing.
    private(set) var projectIcons: [ProjectID: NSImage] = [:]
    private(set) var sshHosts: [SSHHost] = []
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
    private(set) var paneLayouts: [ProjectID: PaneNode] = [:]
    var rightSidebarTab: RightSidebarTab = .services

    // MARK: - Selection and UI

    var selectedProjectID: ProjectID?
    var selectedSessionID: SessionID?
    var isCommandPaletteOpen = false
    var isProjectSettingsOpen = false
    var isAddingProject = false
    var isInboxOpen = false
    /// The panel shown over the window, if any. One at a time by design: these
    /// are things you consult, and stacking them is how the separate windows
    /// became tiresome in the first place.
    var activeModal: RelayModal?
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
    /// Sessions the user has closed but the daemon has not finished forgetting.
    ///
    /// Everything in flight about them — the reply that created them, the exit
    /// their termination causes — arrives after the decision to close and would
    /// otherwise put them back.
    private var closingSessionIDs: Set<SessionID> = []
    private let notifier = AttentionNotifier()

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
        isRightSidebarVisible = state.isRightSidebarVisible
        isLeftSidebarVisible = state.isLeftSidebarVisible
        language = state.language
        paneLayouts = Dictionary(uniqueKeysWithValues: state.paneLayouts.map {
            (ProjectID(rawValue: $0.key), $0.value)
        })
        Localization.shared.language = state.language
        rightSidebarTab = state.rightSidebarTab.flatMap(RightSidebarTab.init(rawValue:)) ?? .services
        lastActiveSessionByProject = state.lastActiveSessionByProject
        selectedProjectID = state.lastActiveProjectID.map { ProjectID(rawValue: $0) }
            ?? projects.first?.id

        client.onDisconnect = { [weak self] in
            Task { @MainActor in self?.handleDisconnect() }
        }

        await connect()
        refreshAllProjectFacts()
        loadSSHHosts()
        scheduleGitRefresh()
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
        sessionOrder = snapshots.map(\.id)
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
        projects[index] = project
        persist()
        if iconChanged { refreshProjectIcons() }
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

    func revealInFinder(_ project: Project) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.rootPath)
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
    func createSession(from preset: SessionPreset, in projectID: ProjectID) {
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
        ))
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

    private func launch(_ spec: SessionSpec, selecting: Bool = true) {
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

    func renameSession(_ id: SessionID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        client.post(.rename(id, name: trimmed))
    }

    func terminateSession(_ id: SessionID) {
        client.post(.terminate(id))
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

        let surface = TerminalSurface(sessionID: sessionID, client: client)
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
            var icons: [ProjectID: NSImage] = [:]
            for (identifier, data) in payloads {
                // A file that claims to be an image and is not simply leaves the
                // project with its initials, which is a perfectly good tile.
                if let image = NSImage(data: data), image.isValid {
                    icons[identifier] = image
                }
            }
            self.projectIcons = icons
        }
    }

    /// Git state changes far more slowly than terminal output, so it is polled
    /// lazily instead of watched — one cheap call per visible project.
    private func scheduleGitRefresh() {
        gitRefreshTask?.cancel()
        gitRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(12))
                guard let self, let projectID = self.selectedProjectID else { continue }
                self.refreshGit(for: projectID)
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
        case .git, .files:
            false
        }
    }

    func tabTooltip(_ tab: RightSidebarTab, for project: Project) -> String {
        guard !isTabAvailable(tab, for: project) else { return tab.title }
        switch tab {
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

    /// Showing a panel that is already up puts it away, the way every toggle in
    /// the app behaves.
    func toggleModal(_ modal: RelayModal) {
        activeModal = activeModal == modal ? nil : modal
    }

    func dismissModal() {
        activeModal = nil
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
        if let event = NotificationPolicy.attentionEvent(for: context) {
            inbox = Inbox.appending(InboxItem(event: event, projectID: snapshot.projectID), to: inbox)
        }
        guard let event = NotificationPolicy.event(for: context) else { return }
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
            self.dockerSnapshots[projectID] = snapshot
        }
    }

    /// Compose actions run as ordinary sessions so their output is visible and
    /// interruptible, instead of disappearing into a background process.
    func runCompose(_ action: ComposeAction, in projectID: ProjectID) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        // Where the compose file is, not where the project starts: a stack kept
        // in `docker/` is common, and running from the root is exactly how
        // "no configuration file provided" happens.
        let directory = ComposeLocator.directory(forProjectAt: projects[index].rootPath)
        launch(SessionSpec(
            projectID: projectID,
            kind: .custom,
            name: action.sessionName,
            workingDirectory: directory,
            command: ["docker", "compose"] + action.arguments
        ))
        // Give compose a moment to change state before asking about it.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.dockerSnapshots.removeValue(forKey: projectID)
            self?.refreshDocker(for: projectID)
        }
    }

    func containerAction(_ action: ContainerAction, container: DockerContainer, in projectID: ProjectID) {
        guard let project = project(projectID) else { return }

        guard action != .logs else {
            // Logs are worth a terminal: they keep running and you read them.
            launch(SessionSpec(
                projectID: projectID,
                kind: .custom,
                name: "logs \(container.service ?? container.name)",
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
            let hosts = await Task.detached(priority: .utility) {
                SSHConfigParser.parse(rootConfig: configURL)
            }.value
            self?.sshHosts = hosts
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

    func persist() {
        let state = WorkspaceState(
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
            isRightSidebarVisible: isRightSidebarVisible,
            isLeftSidebarVisible: isLeftSidebarVisible,
            rightSidebarTab: rightSidebarTab.rawValue,
            language: language,
            paneLayouts: Dictionary(uniqueKeysWithValues: paneLayouts.map { ($0.key.rawValue, $0.value) })
        )
        store.scheduleSave(state)
    }

    func persistImmediately() {
        let state = WorkspaceState(
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
            isRightSidebarVisible: isRightSidebarVisible,
            isLeftSidebarVisible: isLeftSidebarVisible,
            rightSidebarTab: rightSidebarTab.rawValue,
            language: language,
            paneLayouts: Dictionary(uniqueKeysWithValues: paneLayouts.map { ($0.key.rawValue, $0.value) })
        )
        store.saveNow(state)
    }
}
