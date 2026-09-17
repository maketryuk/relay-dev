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

            // With nothing above it, a lone plus at the foot of an empty strip
            // is the smallest target in the window for the one thing there is
            // to do. The welcome pane takes it until there is a rail to add to.
            if !model.projects.isEmpty {
                addButton
                RelayDivider()
                    .frame(width: 24)
                    .padding(.vertical, 2)
            }
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
                isSelected: isSelected,
                artwork: model.projectIcons[project.id]
            )
            .clickable()
            .onTapGesture { model.selectProject(project.id) }
            .relayTooltip(
                project.name,
                shortcut: model.aggregatedStatus(for: project.id).displayName,
                edge: .trailing
            )
            .contextMenu { projectMenu(project) }
            .opacity(model.draggingProjectID == project.id ? 0.4 : 1)
            .projectDragSource(project.id, model: model)
            .projectReorderTarget(project.id, model: model)
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
            model.openProjectSettings()
        }
        Button(relayLocalized("Remove from Workspace")) { model.removeProject(project.id) }
    }

    private var addButton: some View {
        Button {
            model.toggleModal(.addProject)
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
        .clickable()
        .relayTooltip(relayLocalized("Add project"), shortcut: model.binding(for: .addProject), edge: .trailing)
    }

    private var portsButton: some View {
        IconButton(
            systemImage: "point.3.filled.connected.trianglepath.dotted",
            help: "",
            size: 28,
            prominence: .selectable,
            isSelected: model.activeModal == .ports
        ) {
            model.toggleModal(.ports)
        }
        .relayTooltip(relayLocalized("Ports"), shortcut: model.binding(for: .togglePorts), edge: .trailing)
    }

    private var sshButton: some View {
        IconButton(
            systemImage: "network",
            help: "",
            size: 28,
            prominence: .selectable,
            isSelected: model.activeModal == .sshHosts
        ) {
            model.toggleModal(.sshHosts)
        }
        .relayTooltip(relayLocalized("SSH hosts"), shortcut: model.binding(for: .openSSHHosts), edge: .trailing)
    }
}
