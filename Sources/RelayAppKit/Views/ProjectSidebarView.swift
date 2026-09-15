import RelayProtocol
import RelayUI
import SwiftUI

struct ProjectSidebarView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var renameText = ""
    @State private var isShowingAllSSHHosts = false
    @State private var isShowingNewSessionMenu = false
    @State private var isAddingService = false
    @State private var editingService: ServiceDefinition?

    var body: some View {
        @Bindable var model = model

        return VStack(alignment: .leading, spacing: 0) {
            header
            RelayDivider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    sessionsSection
                    servicesSection
                    dockerSection
                }
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.small)
            }
        }
        .frame(width: model.sidebarWidth)
        .background(Theme.Palette.sidebar)
        .overlay(alignment: .trailing) { RelayDivider(axis: .vertical) }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                Text(project.displayPath)
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                repositoryLine
            }
            WindowDragArea()
                .frame(minWidth: Theme.Spacing.small, maxWidth: .infinity, maxHeight: .infinity)
            IconButton(systemImage: "gearshape", help: "") {
                model.isProjectSettingsOpen = true
            }
            .relayTooltip("Project settings", shortcut: model.binding(for: .projectSettings))
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.top, Theme.Spacing.large + Theme.Spacing.small)
        .padding(.bottom, Theme.Spacing.medium)
        .background(Theme.Palette.sidebar)
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        let sessions = model.interactiveSessions(in: project.id)
        return VStack(alignment: .leading, spacing: 1) {
            SectionHeader(
                "Sessions",
                isCollapsed: model.isSectionCollapsed("sessions"),
                onToggle: { model.toggleSection("sessions") }
            ) {
                IconButton(systemImage: "plus", help: "", size: 16) {
                    isShowingNewSessionMenu.toggle()
                }
                .relayTooltip("New session", shortcut: model.binding(for: .newShell))
                .popover(isPresented: $isShowingNewSessionMenu, arrowEdge: .bottom) {
                    NewSessionMenu(projectID: project.id) {
                        isShowingNewSessionMenu = false
                    }
                }
            }

            if !model.isSectionCollapsed("sessions") {
                if sessions.isEmpty {
                    emptyHint("No sessions yet. Press + to start one.")
                } else {
                    ForEach(sessions) { session in
                        sessionRow(session)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: SessionSnapshot) -> some View {
        if model.renamingSessionID == session.id {
            RelayTextField("Session name", text: $renameText) {
                model.renameSession(session.id, to: renameText)
                model.renamingSessionID = nil
            }
            .padding(.horizontal, 2)
            .onExitCommand { model.renamingSessionID = nil }
            .onAppear { renameText = session.displayName }
        } else {
            SidebarRow(
                title: session.displayName,
                subtitle: subtitle(for: session),
                systemImage: session.kind.symbolName,
                iconTint: Color(hex: session.kind.accentHex),
                sessionKind: session.kind,
                status: session.status,
                isSelected: model.selectedSessionID == session.id,
                action: { model.selectSession(session.id) },
                doubleTapAction: {
                    renameText = session.displayName
                    model.renamingSessionID = session.id
                }
            ) {
                IconButton(systemImage: "xmark", help: "Close session", size: 16) {
                    model.closeSession(session.id)
                }
            }
            .contextMenu {
                Button("Rename…") {
                    renameText = session.displayName
                    model.renamingSessionID = session.id
                }
                if session.exitCode == nil {
                    Button("Terminate") { model.terminateSession(session.id) }
                }
                Button("Close") { model.closeSession(session.id) }
            }
        }
    }

    private func subtitle(for session: SessionSnapshot) -> String {
        if let exitCode = session.exitCode {
            return exitCode == 0 ? "exited" : "exited \(exitCode)"
        }
        return session.status.displayName
    }

    // MARK: - Placeholder sections for the next milestone

    private var servicesSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionHeader(
                "Services",
                isCollapsed: model.isSectionCollapsed("services"),
                onToggle: { model.toggleSection("services") }
            ) {
                IconButton(systemImage: "plus", help: "Add service", size: 16) {
                    isAddingService = true
                }
            }

            if !model.isSectionCollapsed("services") {
                if project.services.isEmpty {
                    emptyHint("No services yet. Add one, or let Relay detect a dev command.")
                } else {
                    ForEach(project.services) { service in
                        serviceRow(service)
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingService) {
            ServiceEditorView(project: project, service: nil)
        }
        .sheet(item: $editingService) { service in
            ServiceEditorView(project: project, service: service)
        }
    }

    private func serviceRow(_ service: ServiceDefinition) -> some View {
        let state = model.state(of: service, in: project.id)
        let url = model.url(of: service, in: project.id)

        return SidebarRow(
            title: service.name,
            subtitle: serviceSubtitle(state: state, url: url, command: service.command),
            systemImage: service.isDefault ? "bolt.fill" : "gearshape.2",
            status: state.runtimeStatus,
            isSelected: false,
            action: { model.showServiceLogs(service, in: project.id) },
            accessoryVisibility: .always
        ) {
            HStack(spacing: 0) {
                if url != nil {
                    IconButton(systemImage: "arrow.up.forward.app", help: "", size: 18) {
                        model.openService(service, in: project.id)
                    }
                    .relayTooltip("Open \(url?.absoluteString ?? "")")
                }

                if state.isActive {
                    IconButton(systemImage: "arrow.clockwise", help: "", size: 18) {
                        model.restartService(service, in: project.id)
                    }
                    .relayTooltip("Restart", shortcut: service.isDefault
                        ? model.binding(for: .restartDefaultService)
                        : nil)

                    IconButton(systemImage: "stop.fill", help: "", size: 18) {
                        model.stopService(service, in: project.id)
                    }
                    .relayTooltip("Stop")
                } else {
                    IconButton(systemImage: "play.fill", help: "", size: 18) {
                        model.startService(service, in: project.id)
                    }
                    .relayTooltip("Start", shortcut: service.isDefault
                        ? model.binding(for: .startDefaultService)
                        : nil)
                }
            }
        }
        .contextMenu {
            if state.isActive {
                Button("Stop") { model.stopService(service, in: project.id) }
                Button("Restart") { model.restartService(service, in: project.id) }
            } else {
                Button("Start") { model.startService(service, in: project.id) }
            }
            Button("Logs") { model.showServiceLogs(service, in: project.id) }
            if url != nil {
                Divider()
                Button("Open URL") { model.openService(service, in: project.id) }
                Button("Copy URL") { model.copyServiceURL(service, in: project.id) }
            }
            Divider()
            Button("Edit…") { editingService = service }
            Button("Remove") { model.removeService(service, from: project.id) }
        }
    }

    private func serviceSubtitle(state: ServiceState, url: URL?, command: String) -> String {
        if let url, state.isActive {
            return "\(state.displayName) · \(url.host ?? "localhost"):\(url.port ?? 80)"
        }
        return state == .stopped ? command : state.displayName
    }

    @ViewBuilder
    private var dockerSection: some View {
        let snapshot = model.dockerSnapshot(for: project.id)
        let facts = model.projectFacts[project.id]
        let hasContainers = !(snapshot?.containers.isEmpty ?? true)

        // Shown when the project either declares Docker or actually has
        // containers: a stack is often defined in a subdirectory, so the
        // presence of a compose file in the root proves nothing either way.
        if facts?.hasDocker == true || hasContainers || snapshot?.isAvailable == false {
            VStack(alignment: .leading, spacing: 1) {
                SectionHeader(
                    "Docker",
                    isCollapsed: model.isSectionCollapsed("docker"),
                    onToggle: { model.toggleSection("docker") }
                ) {
                    IconButton(systemImage: "arrow.clockwise", help: "", size: 16) {
                        model.refreshDocker(for: project.id)
                    }
                    .relayTooltip("Refresh containers")
                }

                if !model.isSectionCollapsed("docker") {
                    if let snapshot, !snapshot.isAvailable {
                        emptyHint(snapshot.message ?? "Docker is unavailable.")
                    } else {
                        composeHeaderRow(facts: facts, snapshot: snapshot)
                        composeActions
                        ForEach(snapshot?.containers ?? []) { container in
                            containerRow(container)
                        }
                        if snapshot == nil {
                            emptyHint("Looking for containers…")
                        } else if !hasContainers {
                            emptyHint("No containers for this project. Press Up to start the stack.")
                        }
                    }
                }
            }
            .task(id: project.id) { model.refreshDocker(for: project.id) }
        }
    }

    @ViewBuilder
    private func composeHeaderRow(facts: ProjectFacts?, snapshot: DockerSnapshot?) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 10))
                .frame(width: 14)
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(snapshot?.composeProjectName ?? facts?.composeFile ?? "Docker")
                .font(Theme.Typography.rowSecondary)
                .foregroundStyle(Theme.Palette.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let snapshot, !snapshot.containers.isEmpty {
                StatusDot(status: snapshot.aggregatedStatus)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 4)
    }

    private var composeActions: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            ForEach(ComposeAction.allCases) { action in
                Button {
                    model.runCompose(action, in: project.id)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: action.symbolName).font(.system(size: 8, weight: .semibold))
                        Text(action.title).font(Theme.Typography.caption)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                    .background(Theme.Palette.surfaceRaised)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.xsmall)
    }

    private func containerRow(_ container: DockerContainer) -> some View {
        let isRunning = container.state.lowercased() == "running"

        return SidebarRow(
            title: container.service ?? container.name,
            subtitle: containerSubtitle(container),
            systemImage: "cube",
            status: container.runtimeStatus,
            isSelected: false,
            action: { model.containerAction(.logs, container: container, in: project.id) },
            accessoryVisibility: .always
        ) {
            HStack(spacing: 0) {
                if let port = container.publishedPorts.first, port.url != nil {
                    IconButton(systemImage: "arrow.up.forward.app", help: "", size: 18) {
                        model.openContainerPort(port)
                    }
                    .relayTooltip("Open localhost:\(port.published)")
                }

                if isRunning {
                    IconButton(systemImage: "arrow.clockwise", help: "", size: 18) {
                        model.containerAction(.restart, container: container, in: project.id)
                    }
                    .relayTooltip("Restart container")

                    IconButton(systemImage: "stop.fill", help: "", size: 18) {
                        model.containerAction(.stop, container: container, in: project.id)
                    }
                    .relayTooltip("Stop container")
                } else {
                    IconButton(systemImage: "play.fill", help: "", size: 18) {
                        model.containerAction(.start, container: container, in: project.id)
                    }
                    .relayTooltip("Start container")
                }
            }
        }
        .contextMenu {
            ForEach(ContainerAction.allCases) { action in
                Button(action.title) {
                    model.containerAction(action, container: container, in: project.id)
                }
            }
            Divider()
            ForEach(container.publishedPorts, id: \.published) { port in
                if port.url != nil {
                    Button("Open localhost:\(port.published)") { model.openContainerPort(port) }
                }
            }
            Button("Copy Container Name") { model.copyContainerIdentifier(container) }
        }
    }

    private func containerSubtitle(_ container: DockerContainer) -> String {
        var parts: [String] = []
        if !container.status.isEmpty { parts.append(container.status) }
        let ports = container.publishedPorts.map(\.displayText).joined(separator: " ")
        if !ports.isEmpty { parts.append(ports) }
        return parts.joined(separator: " · ")
    }

    /// Branch and working-tree state, directly under the path.
    ///
    /// This replaced a whole "Project" section that held one useful fact. A
    /// section header, a disclosure arrow and a row was a lot of structure for
    /// a branch name.
    @ViewBuilder
    private var repositoryLine: some View {
        if let git = model.gitStatuses[project.id] {
            HStack(spacing: Theme.Spacing.xsmall) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(git.branch)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .lineLimit(1)

                if git.isDirty {
                    Text("\(git.changedFiles)∆")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.statusWaiting)
                }
                if git.ahead > 0 {
                    Text("↑\(git.ahead)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.statusFinished)
                }
                if git.behind > 0 {
                    Text("↓\(git.behind)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.statusWorking)
                }
                if let manager = model.projectFacts[project.id]?.packageManager {
                    Text("· \(manager)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .padding(.top, 1)
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.rowSecondary)
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.xsmall)
            .fixedSize(horizontal: false, vertical: true)
    }
}
