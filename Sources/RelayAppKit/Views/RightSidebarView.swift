import RelayProtocol
import RelayUI
import SwiftUI

/// The right-hand panel: everything about the project that is not a session.
struct RightSidebarView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    var body: some View {
        HStack(spacing: 0) {
            RelayDivider(axis: .vertical)

            VStack(spacing: 0) {
                tabStrip
                RelayDivider()
                content
                Spacer(minLength: 0)
            }
            .frame(width: 300)
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

        return IconButton(
            systemImage: tab.symbolName,
            size: 28,
            prominence: .selectable,
            isSelected: isSelected,
            isEnabled: isAvailable
        ) {
            model.selectRightSidebarTab(tab)
        }
        .relayTooltip(model.tabTooltip(tab, for: project))
    }

    @ViewBuilder
    private var content: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                switch model.rightSidebarTab {
                case .services: ServicesPane(project: project)
                case .docker: DockerPane(project: project)
                case .history: HistoryPane(project: project)
                case .git, .files: comingSoon(model.rightSidebarTab)
                }
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.small)
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

    @State private var isAddingService = false
    @State private var editingService: ServiceDefinition?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SectionHeader(relayLocalized("Services"), trailing: {
                IconButton(systemImage: "plus", help: "", size: 24) { isAddingService = true }
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
        .sheet(isPresented: $isAddingService) {
            ServiceEditorView(project: project, service: nil)
        }
        .sheet(item: $editingService) { service in
            ServiceEditorView(project: project, service: service)
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
                    .relayTooltip("Open \(url?.absoluteString ?? "")")
                }

                if state.isActive {
                    IconButton(systemImage: "arrow.clockwise", help: "", size: 24) {
                        model.restartService(service, in: project.id)
                    }
                    .relayTooltip(
                        "Restart",
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
                        "Start",
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
            Button(relayLocalized("Edit…")) { editingService = service }
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
            SectionHeader(snapshot?.composeProjectName.map { "Docker · \($0)" } ?? "Docker", trailing: {
                IconButton(systemImage: "arrow.clockwise", help: "", size: 24) {
                    model.refreshDocker(for: project.id)
                }
                .relayTooltip(relayLocalized("Refresh containers"))
            })

            if let snapshot, !snapshot.isAvailable {
                hint(snapshot.message ?? "Docker is unavailable.")
            } else {
                composeActions
                ForEach(snapshot?.containers ?? []) { container in
                    row(container)
                }
                if snapshot == nil {
                    hint("Looking for containers…")
                } else if snapshot?.containers.isEmpty == true {
                    hint("No containers for this project. Press Up to start the stack.")
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
                    .relayTooltip("Open localhost:\(port.published)")
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
        let entries = model.history(for: project.id)

        VStack(alignment: .leading, spacing: 1) {
            SectionHeader(relayLocalized("History"), trailing: {
                if !entries.isEmpty {
                    IconButton(systemImage: "trash", help: "", size: 24) {
                        model.clearHistory(for: project.id)
                    }
                    .relayTooltip(relayLocalized("Clear history"))
                }
            })

            if entries.isEmpty {
                Text(relayLocalized("Sessions you finish appear here, with what ran and how it ended."))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, Theme.Spacing.xsmall)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(entries) { entry in
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: SessionHistoryEntry) -> some View {
        SidebarRow(
            title: entry.name,
            subtitle: subtitle(entry),
            systemImage: entry.kind.symbolName,
            iconTint: Color(hex: entry.kind.accentHex),
            sessionKind: entry.kind,
            status: entry.succeeded ? .finished : .error,
            isSelected: false,
            action: { model.rerun(entry) },
            accessoryVisibility: .onHover
        ) {
            IconButton(systemImage: "arrow.clockwise", help: "", size: 24) { model.rerun(entry) }
                .relayTooltip(relayLocalized("Run again"))
        }
        .contextMenu {
            Button(relayLocalized("Run Again")) { model.rerun(entry) }
            Text(entry.command.joined(separator: " "))
        }
    }

    private func subtitle(_ entry: SessionHistoryEntry) -> String {
        let outcome = entry.succeeded ? "finished" : "exited \(entry.exitCode.map(String.init) ?? "?")"
        return "\(Self.formatter.localizedString(for: entry.endedAt, relativeTo: Date())) · \(entry.durationText) · \(outcome)"
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}
