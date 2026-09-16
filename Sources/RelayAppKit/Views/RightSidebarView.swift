import RelayProtocol
import RelayUI
import SwiftUI

/// The right-hand panel: everything about the project that is not a session.
struct RightSidebarView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        HStack(spacing: 0) {
            RightSidebarResizeHandle()

            VStack(spacing: 0) {
                tabStrip
                RelayDivider()
                content
                if !model.rightSidebarTab.fillsPanel {
                    Spacer(minLength: 0)
                }
            }
            .frame(width: model.rightSidebarWidth)
            .background(Theme.Palette.sidebar)
        }
    }

    private var tabStrip: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            ForEach(RightSidebarTab.allCases) { tab in
                tabButton(tab)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.small)
    }

    private func tabButton(_ tab: RightSidebarTab) -> some View {
        let isAvailable = model.isTabAvailable(tab, for: project)
        let isSelected = model.rightSidebarTab == tab && model.isRightSidebarVisible
        // A Docker tab that found nothing is off, not finished: containers get
        // started after the project is opened, and clicking is how you ask.
        let isRetryable = tab == .docker && !isAvailable

        return IconButton(
            systemImage: tab.symbolName,
            size: 28,
            prominence: .selectable,
            isSelected: isSelected,
            isEnabled: isAvailable,
            respondsWhenDisabled: isRetryable,
            isBusy: tab == .docker && model.isCheckingDocker(project.id)
        ) {
            if isAvailable {
                model.selectRightSidebarTab(tab)
            } else if isRetryable {
                model.recheckDocker(for: project.id)
            }
        }
        .relayTooltip(model.tabTooltip(tab, for: project))
    }

    @ViewBuilder
    private var content: some View {
        switch model.rightSidebarTab {
        // These scroll their own list and keep the box at the bottom in view;
        // wrapped in the shared scroll view, the box would be somewhere below
        // fifty rows.
        case .git:
            GitPane(project: project)
        case .todo:
            TodoPane(project: project)
        default:
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    switch model.rightSidebarTab {
                    case .services: ServicesPane(project: project)
                    case .docker: DockerPane(project: project)
                    case .history: HistoryPane(project: project)
                    default: comingSoon(model.rightSidebarTab)
                    }
                }
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, Theme.Spacing.small)
            }
        }
    }

    private func comingSoon(_ tab: RightSidebarTab) -> some View {
        EmptyStateView(
            systemImage: tab.symbolName,
            title: relayLocalized("Coming soon"),
            message: tab.localizedComingSoon
        )
        .frame(minHeight: 220)
    }
}

// MARK: - Services

struct ServicesPane: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionHeader(relayLocalized("Services"), trailing: {
                IconButton(systemImage: "plus", help: "", size: Theme.Metrics.action) { model.toggleModal(.serviceEditor(projectID: project.id, serviceID: nil)) }
                    .relayTooltip(relayLocalized("Add service"))
            })

            if project.services.isEmpty {
                hint("No services yet. Add one, or let Relay detect a dev command.")
            } else {
                ForEach(project.services) { service in
                    row(service)
                }
            }
        }
    }

    private func row(_ service: ServiceDefinition) -> some View {
        let state = model.state(of: service, in: project.id)
        let url = model.url(of: service, in: project.id)

        return SidebarRow(
            title: service.name,
            subtitle: subtitle(state: state, url: url, command: service.command),
            systemImage: service.isDefault ? "bolt.fill" : "gearshape.2",
            status: state.runtimeStatus,
            isSelected: false,
            action: { model.showServiceLogs(service, in: project.id) },
            accessoryVisibility: .always
        ) {
            HStack(spacing: 1) {
                if url != nil {
                    IconButton(systemImage: "arrow.up.forward.app", help: "", size: Theme.Metrics.action) {
                        model.openService(service, in: project.id)
                    }
                    .relayTooltip(String(format: relayLocalized("Open %@"), url?.absoluteString ?? ""))
                }

                if state.isActive {
                    IconButton(systemImage: "arrow.clockwise", help: "", size: Theme.Metrics.action) {
                        model.restartService(service, in: project.id)
                    }
                    .relayTooltip(
                        relayLocalized("Restart"),
                        shortcut: service.isDefault ? model.binding(for: .restartDefaultService) : nil
                    )
                    IconButton(systemImage: "stop.fill", help: "", size: Theme.Metrics.action) {
                        model.stopService(service, in: project.id)
                    }
                    .relayTooltip(relayLocalized("Stop"))
                } else {
                    IconButton(systemImage: "play.fill", help: "", size: Theme.Metrics.action) {
                        model.startService(service, in: project.id)
                    }
                    .relayTooltip(
                        relayLocalized("Start"),
                        shortcut: service.isDefault ? model.binding(for: .startDefaultService) : nil
                    )
                }
            }
        }
        .contextMenu {
            if state.isActive {
                Button(relayLocalized("Stop")) { model.stopService(service, in: project.id) }
                Button(relayLocalized("Restart")) { model.restartService(service, in: project.id) }
            } else {
                Button(relayLocalized("Start")) { model.startService(service, in: project.id) }
            }
            Button(relayLocalized("Logs")) { model.showServiceLogs(service, in: project.id) }
            if url != nil {
                Divider()
                Button(relayLocalized("Open URL")) { model.openService(service, in: project.id) }
                Button(relayLocalized("Copy URL")) { model.copyServiceURL(service, in: project.id) }
            }
            Divider()
            Button(relayLocalized("Edit…")) { model.toggleModal(.serviceEditor(projectID: project.id, serviceID: service.id)) }
            Button(relayLocalized("Remove")) { model.removeService(service, from: project.id) }
        }
    }

    private func subtitle(state: ServiceState, url: URL?, command: String) -> String {
        if let url, state.isActive {
            return "\(state.localizedName) · \(url.host ?? "localhost"):\(url.port ?? 80)"
        }
        return state == .stopped ? command : state.localizedName
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.rowSecondary)
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.xsmall)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Docker

struct DockerPane: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        let snapshot = model.dockerSnapshot(for: project.id)

        VStack(alignment: .leading, spacing: 1) {
            SectionHeader(snapshot?.composeProjectName.map { "Docker · \($0)" } ?? relayLocalized("Docker"), trailing: {
                // On the header's own line rather than a strip below it: what
                // these do is to the stack the header names, and a second row
                // of buttons under a title is a toolbar for a section that has
                // one already.
                HStack(spacing: Theme.Spacing.xxsmall) {
                    if snapshot?.isAvailable != false {
                        ForEach(ComposeAction.allCases) { action in
                            IconButton(
                                systemImage: action.symbolName,
                                help: action.localizedTitle,
                                size: Theme.Metrics.action
                            ) {
                                model.runCompose(action, in: project.id)
                            }
                        }
                    }
                    IconButton(systemImage: "arrow.clockwise", help: "", size: Theme.Metrics.action) {
                        model.refreshDocker(for: project.id)
                    }
                    .relayTooltip(relayLocalized("Refresh containers"))
                }
            })

            if let snapshot, !snapshot.isAvailable {
                unavailable(snapshot)
            } else {
                ForEach(snapshot?.containers ?? []) { container in
                    row(container)
                }
                if snapshot == nil {
                    hint(relayLocalized("Looking for containers…"))
                } else if snapshot?.containers.isEmpty == true {
                    hint(relayLocalized("No containers for this project. Press Up to start the stack."))
                }
            }
        }
        // Containers are started and stopped from Docker Desktop, from a
        // terminal, and by whatever the project's own tooling does — none of
        // which Relay is told about.
        .refreshingWhileVisible(id: project.id, every: .seconds(5)) {
            model.refreshDocker(for: project.id)
        }
    }

    /// Three different kinds of nothing, which have nothing in common but the
    /// empty panel they produce.
    @ViewBuilder
    private func unavailable(_ snapshot: DockerSnapshot) -> some View {
        switch snapshot.absence {
        case .notInstalled:
            // The one Relay cannot help with, and says so rather than offering
            // something that would not work: it shows containers, it does not
            // carry an engine.
            hint(relayLocalized("Docker is not installed. Relay shows the containers an engine is running — Docker Desktop and Colima are both engines it can read."))

        case let .engineStopped(engine):
            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
                hint(engine.map { String(format: relayLocalized("%@ is not running."), $0.displayName) }
                    ?? relayLocalized("The Docker engine is not running."))
                if let engine {
                    PillButton(
                        String(format: relayLocalized("Start %@"), engine.displayName),
                        systemImage: "play.fill"
                    ) {
                        model.startDockerEngine(engine, in: project.id)
                    }
                    .padding(.horizontal, Theme.Spacing.small)
                }
            }

        case .failed, .none:
            // Whatever Docker said, verbatim: an error Relay has not been
            // taught to read is an error it must not paraphrase.
            hint(snapshot.message ?? relayLocalized("Docker is unavailable."))
        }
    }

    private func row(_ container: DockerContainer) -> some View {
        let isRunning = container.state.lowercased() == "running"

        return SidebarRow(
            title: container.service ?? container.name,
            subtitle: subtitle(container),
            systemImage: "cube",
            status: container.runtimeStatus,
            isSelected: false,
            // A container is opened to get inside it. Its log is a thing you
            // ask for; a prompt is the thing you came for — except on one that
            // is not running, where there is nothing to exec into and the log
            // is the only account of why.
            action: {
                model.containerAction(isRunning ? .shell : .logs, container: container, in: project.id)
            },
            accessoryVisibility: .always
        ) {
            HStack(spacing: 1) {
                if let port = container.publishedPorts.first, port.url != nil {
                    IconButton(systemImage: "arrow.up.forward.app", help: "", size: Theme.Metrics.action) {
                        model.openContainerPort(port)
                    }
                    .relayTooltip(String(format: relayLocalized("Open localhost:%d"), port.published))
                }

                if isRunning {
                    IconButton(systemImage: "arrow.clockwise", help: "", size: Theme.Metrics.action) {
                        model.containerAction(.restart, container: container, in: project.id)
                    }
                    .relayTooltip(relayLocalized("Restart container"))
                    IconButton(systemImage: "stop.fill", help: "", size: Theme.Metrics.action) {
                        model.containerAction(.stop, container: container, in: project.id)
                    }
                    .relayTooltip(relayLocalized("Stop container"))
                } else {
                    IconButton(systemImage: "play.fill", help: "", size: Theme.Metrics.action) {
                        model.containerAction(.start, container: container, in: project.id)
                    }
                    .relayTooltip(relayLocalized("Start container"))
                }
            }
        }
        .relayTooltip(
            isRunning
                ? relayLocalized("Open a terminal inside this container")
                : relayLocalized("Show this container's log"),
            shortcut: container.name,
            edge: .leading
        )
        .contextMenu {
            ForEach(ContainerAction.allCases) { action in
                Button(action.localizedTitle) {
                    model.containerAction(action, container: container, in: project.id)
                }
            }
            Divider()
            Button(relayLocalized("Copy Container Name")) { model.copyContainerIdentifier(container) }
        }
    }

    private func subtitle(_ container: DockerContainer) -> String {
        var parts: [String] = []
        if !container.status.isEmpty { parts.append(container.status) }
        let ports = container.publishedPorts.map(\.displayText).joined(separator: " ")
        if !ports.isEmpty { parts.append(ports) }
        return parts.joined(separator: " · ")
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.rowSecondary)
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.xsmall)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - History

struct HistoryPane: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionHeader(relayLocalized("Conversations"), trailing: {
                IconButton(
                    systemImage: "arrow.clockwise",
                    help: "",
                    size: Theme.Metrics.action,
                    isBusy: model.isLoadingConversations
                ) {
                    model.loadConversations(for: project.id)
                }
                .relayTooltip(relayLocalized("Look again"))
            })

            if model.conversations.isEmpty {
                // The list is the agents' own, so an empty one means there have
                // been none here rather than that Relay has forgotten.
                hint(relayLocalized(
                    "Past conversations with Claude and Codex in this project appear here, wherever they were started."
                ))
            } else {
                ForEach(model.conversations) { conversation in
                    row(conversation)
                }
            }
        }
        .refreshingWhileVisible(id: project.id, every: .seconds(10)) {
            model.loadConversations(for: project.id)
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        SidebarRow(
            title: conversation.title,
            subtitle: subtitle(conversation),
            systemImage: conversation.kind.symbolName,
            iconTint: Color(hex: conversation.kind.accentHex),
            sessionKind: conversation.kind,
            isSelected: false,
            action: { model.resume(conversation, in: project.id) },
            accessoryVisibility: .onHover
        ) {
            IconButton(systemImage: "arrow.uturn.left", help: "", size: Theme.Metrics.action) {
                model.resume(conversation, in: project.id)
            }
            .relayTooltip(relayLocalized("Resume"))
        }
        .contextMenu {
            Button(relayLocalized("Resume")) { model.resume(conversation, in: project.id) }
            Button(relayLocalized("Copy session ID")) { model.copyToClipboard(conversation.id) }
        }
    }

    private func subtitle(_ conversation: Conversation) -> String {
        var parts = [Self.formatter.localizedString(for: conversation.updatedAt, relativeTo: Date())]
        if let branch = conversation.branch { parts.append(branch) }
        if let prompt = conversation.lastPrompt, prompt != conversation.title { parts.append(prompt) }
        return parts.joined(separator: " · ")
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.rowSecondary)
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.xsmall)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
