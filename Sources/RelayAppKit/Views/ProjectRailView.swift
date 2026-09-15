import AppKit
import RelayProtocol
import RelayUI
import SwiftUI

/// Narrow vertical strip of projects, Discord-style.
///
/// Names are deliberately absent: the rail's job is to answer "where is
/// something happening" at a glance, and a column of text would bury that.
struct ProjectRailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model

        return VStack(spacing: Theme.Spacing.small) {
            // Leaves room for the traffic lights, which float over the rail
            // once the title bar is hidden, and doubles as a title-bar region.
            WindowDragArea()
                .frame(height: 22)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Theme.Spacing.small) {
                    ForEach(model.projects) { project in
                        projectTile(project)
                    }
                }
                .padding(.vertical, Theme.Spacing.small)
            }

            Spacer(minLength: 0)

            addButton
            RelayDivider()
                .frame(width: 24)
                .padding(.vertical, 2)
            portsButton
            sshButton
            paletteButton
            settingsButton
        }
        .padding(.vertical, Theme.Spacing.small)
        .frame(width: Theme.Metrics.railWidth)
        .frame(maxHeight: .infinity)
        .background(Theme.Palette.rail)
        .overlay(alignment: .trailing) { RelayDivider(axis: .vertical) }
        .fileImporter(
            isPresented: $model.isAddingProject,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                model.addProject(at: url)
            }
        }
    }

    private func projectTile(_ project: Project) -> some View {
        let isSelected = model.selectedProjectID == project.id
        return ZStack(alignment: .leading) {
            // Selection pill, the one piece of chrome that earns its colour.
            Capsule()
                .fill(Theme.Palette.textPrimary)
                .frame(width: 3, height: isSelected ? 24 : 0)
                .offset(x: -8)
                .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isSelected)

            ProjectIcon(
                initials: ProjectAppearance.initials(for: project.name),
                tint: ProjectAppearance.tint(for: project.rootPath),
                status: model.aggregatedStatus(for: project.id),
                isSelected: isSelected
            )
            .onTapGesture { model.selectProject(project.id) }
            .help("\(project.name) — \(model.aggregatedStatus(for: project.id).displayName)")
            .contextMenu { projectMenu(project) }
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        Button("Open") { model.selectProject(project.id) }
        Button("Open in Finder") { model.revealInFinder(project) }
        Button("Open in Editor") { model.openInEditor(project) }
        Divider()
        Button("New Claude Session") { model.createSession(kind: .claude, in: project.id) }
        Button("New Codex Session") { model.createSession(kind: .codex, in: project.id) }
        Button("New Shell") { model.createSession(kind: .shell, in: project.id) }
        Divider()
        Button("Project Settings…") {
            model.selectProject(project.id)
            model.isProjectSettingsOpen = true
        }
        Button("Remove from Workspace") { model.removeProject(project.id) }
    }

    private var addButton: some View {
        Button {
            model.isAddingProject = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 14, weight: .medium))
                .frame(width: Theme.Metrics.projectIconSize, height: Theme.Metrics.projectIconSize)
                .background(Theme.Palette.surfaceRaised)
                .foregroundStyle(Theme.Palette.textSecondary)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .strokeBorder(Theme.Palette.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .relayTooltip("Add project", shortcut: model.binding(for: .addProject), edge: .trailing)
    }

    private var portsButton: some View {
        IconButton(systemImage: "point.3.filled.connected.trianglepath.dotted", help: "", size: 28) {
            openWindow(id: PortsWindow.id)
        }
        .relayTooltip("Ports", shortcut: model.binding(for: .togglePorts), edge: .trailing)
    }

    private var sshButton: some View {
        IconButton(systemImage: "network", help: "", size: 28) {
            openWindow(id: SSHWindow.id)
        }
        .relayTooltip("SSH hosts", shortcut: model.binding(for: .openSSHHosts), edge: .trailing)
    }

    private var paletteButton: some View {
        IconButton(systemImage: "command", help: "", size: 28) {
            model.isCommandPaletteOpen = true
        }
        .relayTooltip("Command Palette", shortcut: model.binding(for: .commandPalette), edge: .trailing)
    }

    private var settingsButton: some View {
        IconButton(systemImage: "gearshape", help: "", size: 28) {
            openSettings()
        }
        .relayTooltip("Settings", shortcut: model.binding(for: .openSettings), edge: .trailing)
    }
}
