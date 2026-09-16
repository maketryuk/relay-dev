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
                if model.rightSidebarTab != .git {
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
        // The panel scrolls its own list and keeps the commit box in view;
        // wrapped in the shared scroll view, the box would be somewhere below
        // fifty files.
        case .git:
            GitPane(project: project)
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
                IconButton(systemImage: "plus", help: "", size: 24) { model.toggleModal(.serviceEditor(projectID: project.id, serviceID: nil)) }
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
                    IconButton(systemImage: "arrow.up.forward.app", help: "", size: 24) {
                        model.openService(service, in: project.id)
                    }
                    .relayTooltip(String(format: relayLocalized("Open %@"), url?.absoluteString ?? ""))
                }

                if state.isActive {
                    IconButton(systemImage: "arrow.clockwise", help: "", size: 24) {
                        model.restartService(service, in: project.id)
                    }
                    .relayTooltip(
                        relayLocalized("Restart"),
                        shortcut: service.isDefault ? model.binding(for: .restartDefaultService) : nil
                    )
                    IconButton(systemImage: "stop.fill", help: "", size: 24) {
                        model.stopService(service, in: project.id)
                    }
                    .relayTooltip(relayLocalized("Stop"))
                } else {
                    IconButton(systemImage: "play.fill", help: "", size: 24) {
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
                IconButton(systemImage: "arrow.clockwise", help: "", size: 24) {
                    model.refreshDocker(for: project.id)
                }
                .relayTooltip(relayLocalized("Refresh containers"))
            })

            if let snapshot, !snapshot.isAvailable {
                hint(snapshot.message ?? relayLocalized("Docker is unavailable."))
            } else {
                composeActions
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
        .task(id: project.id) { model.refreshDocker(for: project.id) }
    }

    private var composeActions: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            ForEach(ComposeAction.allCases) { action in
                IconButton(systemImage: action.symbolName, help: "", size: 28) {
                    model.runCompose(action, in: project.id)
                }
                .relayTooltip(action.localizedTitle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.xsmall)
    }

    private func row(_ container: DockerContainer) -> some View {
        let isRunning = container.state.lowercased() == "running"

        return SidebarRow(
            title: container.service ?? container.name,
            subtitle: subtitle(container),
            systemImage: "cube",
            status: container.runtimeStatus,
            isSelected: false,
            action: { model.containerAction(.logs, container: container, in: project.id) },
            accessoryVisibility: .always
        ) {
            HStack(spacing: 1) {
                if let port = container.publishedPorts.first, port.url != nil {
                    IconButton(systemImage: "arrow.up.forward.app", help: "", size: 24) {
                        model.openContainerPort(port)
                    }
                    .relayTooltip(String(format: relayLocalized("Open localhost:%d"), port.published))
                }

                if isRunning {
                    IconButton(systemImage: "arrow.clockwise", help: "", size: 24) {
                        model.containerAction(.restart, container: container, in: project.id)
                    }
                    .relayTooltip(relayLocalized("Restart container"))
                    IconButton(systemImage: "stop.fill", help: "", size: 24) {
                        model.containerAction(.stop, container: container, in: project.id)
                    }
                    .relayTooltip(relayLocalized("Stop container"))
                } else {
                    IconButton(systemImage: "play.fill", help: "", size: 24) {
                        model.containerAction(.start, container: container, in: project.id)
                    }
                    .relayTooltip(relayLocalized("Start container"))
                }
            }
        }
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
                    size: 24,
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
        .onAppear { model.loadConversations(for: project.id) }
        .onChange(of: project.id) { _, _ in model.loadConversations(for: project.id) }
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
            IconButton(systemImage: "arrow.uturn.left", help: "", size: 24) {
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
