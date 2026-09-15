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
            // Fixed height: an expanding drag area stretches the strip to fill
            // the whole panel.
            WindowDragArea()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 24, maxHeight: 24)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.top, Theme.Spacing.large + Theme.Spacing.small)
        .padding(.bottom, Theme.Spacing.small)
    }

    private func tabButton(_ tab: RightSidebarTab) -> some View {
        let isSelected = model.rightSidebarTab == tab && model.isRightSidebarVisible

        return Button {
            model.selectRightSidebarTab(tab)
        } label: {
            Image(systemName: tab.symbolName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 24)
                .background(isSelected ? Theme.Palette.surfaceActive : .clear)
                .foregroundStyle(tabTint(tab, isSelected: isSelected))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!tab.isAvailable)
        .relayTooltip(tab.isAvailable ? tab.title : "\(tab.title) — coming soon")
    }

    private func tabTint(_ tab: RightSidebarTab, isSelected: Bool) -> Color {
        guard tab.isAvailable else { return Theme.Palette.textTertiary.opacity(0.4) }
        return isSelected ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
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
            title: "\(tab.title) — coming soon",
            message: tab.comingSoonDescription
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
            SectionHeader("Services") {
                IconButton(systemImage: "plus", help: "", size: 16) { isAddingService = true }
                    .relayTooltip("Add service")
            }

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
                    .relayTooltip(
                        "Restart",
                        shortcut: service.isDefault ? model.binding(for: .restartDefaultService) : nil
                    )
                    IconButton(systemImage: "stop.fill", help: "", size: 18) {
                        model.stopService(service, in: project.id)
                    }
                    .relayTooltip("Stop")
                } else {
                    IconButton(systemImage: "play.fill", help: "", size: 18) {
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

    private func subtitle(state: ServiceState, url: URL?, command: String) -> String {
        if let url, state.isActive {
            return "\(state.displayName) · \(url.host ?? "localhost"):\(url.port ?? 80)"
        }
        return state == .stopped ? command : state.displayName
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
            SectionHeader(snapshot?.composeProjectName.map { "Docker · \($0)" } ?? "Docker") {
                IconButton(systemImage: "arrow.clockwise", help: "", size: 16) {
                    model.refreshDocker(for: project.id)
                }
                .relayTooltip("Refresh containers")
            }

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
            Button("Copy Container Name") { model.copyContainerIdentifier(container) }
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
            SectionHeader("History") {
                if !entries.isEmpty {
                    IconButton(systemImage: "trash", help: "", size: 16) {
                        model.clearHistory(for: project.id)
                    }
                    .relayTooltip("Clear history")
                }
            }

            if entries.isEmpty {
                Text("Sessions you finish appear here, with what ran and how it ended.")
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
            IconButton(systemImage: "arrow.clockwise", help: "", size: 16) { model.rerun(entry) }
                .relayTooltip("Run again")
        }
        .contextMenu {
            Button("Run Again") { model.rerun(entry) }
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
