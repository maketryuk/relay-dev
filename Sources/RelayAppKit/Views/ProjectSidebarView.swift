import RelayProtocol
import RelayUI
import SwiftUI

/// The left sidebar: the project, and its sessions.
///
/// Everything else moved to the right-hand panel. A sidebar that mixed sessions,
/// services, containers and hosts made the one list you actually navigate with
/// compete for space with four you only occasionally consult.
struct ProjectSidebarView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var renameText = ""
    @State private var isShowingNewSessionMenu = false
    @State private var isRenamingProject = false
    @State private var projectNameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            RelayDivider()
            sessions
        }
        .frame(width: model.sidebarWidth)
        .background(Theme.Palette.sidebar)
        .overlay(alignment: .trailing) { RelayDivider(axis: .vertical) }
    }

    // MARK: - Header

    /// The name across the top, then the path and the buttons on one line.
    ///
    /// The name used to share its row with two icons, which left the rename
    /// field about a word wide — too narrow to see what was being typed in it.
    /// The path can be truncated and the buttons are a fixed size, so they are
    /// the pair that belongs on a shared line.
    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            if isRenamingProject {
                InlineRenameField(
                    relayLocalized("Project name"),
                    text: $projectNameDraft,
                    onCommit: commitProjectRename,
                    onCancel: { isRenamingProject = false }
                )
                .frame(maxWidth: .infinity)
            } else {
                Text(project.name)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    // One click, not two: the name is the only thing on this
                    // line and there is nothing else a click on it could mean.
                    // Escape and the cross beside the field undo a stray one.
                    .onTapGesture {
                        projectNameDraft = project.name
                        isRenamingProject = true
                    }
                    .relayPointer(.text)
            }

            HStack(spacing: Theme.Spacing.small) {
                Text(project.displayPath)
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)

                Spacer(minLength: Theme.Spacing.small)

                IconButton(systemImage: "plus", help: "", size: 22) {
                    isShowingNewSessionMenu.toggle()
                }
                .relayTooltip(relayLocalized("New session"), shortcut: model.binding(for: .newShell))
                .popover(isPresented: $isShowingNewSessionMenu, arrowEdge: .bottom) {
                    NewSessionMenu(projectID: project.id) {
                        isShowingNewSessionMenu = false
                    }
                }

                IconButton(systemImage: "gearshape", help: "", size: 22) {
                    model.openProjectSettings()
                }
                .relayTooltip(relayLocalized("Project settings"), shortcut: model.binding(for: .projectSettings))
            }
        }
        .padding(.horizontal, Theme.Spacing.medium)
        .padding(.vertical, Theme.Spacing.medium)
        .background(Theme.Palette.sidebar)
    }

    // MARK: - Sessions

    /// No section header: with sessions the only thing in this sidebar, a
    /// heading would be labelling the whole panel.
    private var sessions: some View {
        let list = model.interactiveSessions(in: project.id)

        return Group {
            if list.isEmpty {
                VStack(spacing: Theme.Spacing.small) {
                    Text(relayLocalized("No sessions yet"))
                        .font(Theme.Typography.row)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Text(startHint)
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.Spacing.medium)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, Theme.Spacing.xlarge)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    ReorderableColumn(
                        ids: list.map(\.id),
                        spacing: 2,
                        space: "relay.sessions",
                        onMove: { moved, target, side in
                            model.moveSession(moved, beside: target, side: side)
                        }
                    ) { sessionID in
                        if let session = model.sessions[sessionID] {
                            row(session)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, Theme.Spacing.small)
                }
            }
        }
    }

    private func commitProjectRename() {
        let trimmed = projectNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isRenamingProject = false
        guard !trimmed.isEmpty, trimmed != project.name else { return }
        var updated = project
        updated.name = trimmed
        model.updateProject(updated)
    }

    /// Names the actual shortcut rather than pointing at a button, and stays
    /// correct if the user rebinds it.
    private var startHint: String {
        guard let shortcut = model.binding(for: .newShell)?.displayString else {
            return relayLocalized("Press + to start one")
        }
        return String(format: relayLocalized("Press %@ for a terminal, or + to choose"), shortcut)
    }

    @ViewBuilder
    private func row(_ session: SessionSnapshot) -> some View {
        if model.renamingSessionID == session.id {
            InlineRenameField(
                relayLocalized("Session name"),
                text: $renameText,
                onCommit: {
                    model.renameSession(session.id, to: renameText)
                    model.renamingSessionID = nil
                },
                onCancel: { model.renamingSessionID = nil }
            )
            .padding(.horizontal, Theme.Spacing.xsmall)
            .padding(.vertical, 4)
            .onAppear { renameText = session.displayName }
        } else {
            SessionRow(
                session: session,
                isSelected: model.selectedSessionID == session.id,
                onSelect: { model.selectSession(session.id) },
                onRename: {
                    renameText = session.displayName
                    model.renamingSessionID = session.id
                }
            )
            .contextMenu {
                Button(relayLocalized("Rename…")) {
                    renameText = session.displayName
                    model.renamingSessionID = session.id
                }
                if session.exitCode == nil {
                    Button(relayLocalized("Terminate")) { model.terminateSession(session.id) }
                }
                Button(relayLocalized("Close")) { model.closeSession(session.id) }
            }
        }
    }
}
