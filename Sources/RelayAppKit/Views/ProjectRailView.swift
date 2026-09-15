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
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isDropTargeted = false

    var body: some View {
        @Bindable var model = model

        return VStack(spacing: Theme.Spacing.small) {
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
        }
        .padding(.vertical, Theme.Spacing.small)
        .frame(width: Theme.Metrics.railWidth)
        .frame(maxHeight: .infinity)
        .background(isDropTargeted ? Theme.Palette.accentMuted : Theme.Palette.rail)
        .overlay(alignment: .trailing) { RelayDivider(axis: .vertical) }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    var isDirectory: ObjCBool = false
                    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                          isDirectory.boolValue
                    else { return }
                    Task { @MainActor in model.addProject(at: url) }
                }
            }
            return true
        }
        .sheet(isPresented: $model.isAddingProject) {
            AddProjectSheet()
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
            .relayTooltip(
                project.name,
                shortcut: model.aggregatedStatus(for: project.id).displayName,
                edge: .trailing
            )
            .contextMenu { projectMenu(project) }
        }
    }

    @ViewBuilder
    private func projectMenu(_ project: Project) -> some View {
        Button(relayLocalized("Open")) { model.selectProject(project.id) }
        Button(relayLocalized("Open in Finder")) { model.revealInFinder(project) }
        Button(relayLocalized("Open in Editor")) { model.openInEditor(project) }
        Divider()
        Button(relayLocalized("New Claude Session")) { model.createSession(kind: .claude, in: project.id) }
        Button(relayLocalized("New Codex Session")) { model.createSession(kind: .codex, in: project.id) }
        Button(relayLocalized("New Shell")) { model.createSession(kind: .shell, in: project.id) }
        Divider()
        Button(relayLocalized("Project Settings…")) {
            model.selectProject(project.id)
            model.isProjectSettingsOpen = true
        }
        Button(relayLocalized("Remove from Workspace")) { model.removeProject(project.id) }
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
        .relayTooltip(relayLocalized("Add project"), shortcut: model.binding(for: .addProject), edge: .trailing)
    }

    private func toggle(_ id: String) {
        WindowToggle.toggle(
            id: id,
            isOpen: model.isWindowOpen(id),
            openWindow: openWindow,
            dismissWindow: dismissWindow
        )
    }

    private var portsButton: some View {
        IconButton(systemImage: "point.3.filled.connected.trianglepath.dotted", help: "", size: 28) {
            toggle(PortsWindow.id)
        }
        .relayTooltip(relayLocalized("Ports"), shortcut: model.binding(for: .togglePorts), edge: .trailing)
    }

    private var sshButton: some View {
        IconButton(systemImage: "network", help: "", size: 28) {
            toggle(SSHWindow.id)
        }
        .relayTooltip(relayLocalized("SSH hosts"), shortcut: model.binding(for: .openSSHHosts), edge: .trailing)
    }
}
