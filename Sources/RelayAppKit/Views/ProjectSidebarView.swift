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

    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.small) {
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
            }

            // Fixed height: an expanding drag area would stretch the header to
            // fill the sidebar, which is exactly what it did.
            WindowDragArea()
                .frame(minWidth: Theme.Spacing.small, maxWidth: .infinity, minHeight: 30, maxHeight: 30)

            IconButton(systemImage: "plus", help: "", size: 22) {
                isShowingNewSessionMenu.toggle()
            }
            .relayTooltip("New session", shortcut: model.binding(for: .newShell))
            .popover(isPresented: $isShowingNewSessionMenu, arrowEdge: .bottom) {
                NewSessionMenu(projectID: project.id) {
                    isShowingNewSessionMenu = false
                }
            }

            IconButton(systemImage: "gearshape", help: "", size: 22) {
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

    /// No section header: with sessions the only thing in this sidebar, a
    /// heading would be labelling the whole panel.
    private var sessions: some View {
        let list = model.interactiveSessions(in: project.id)

        return Group {
            if list.isEmpty {
                VStack(spacing: Theme.Spacing.small) {
                    Text("No sessions yet")
                        .font(Theme.Typography.row)
                        .foregroundStyle(Theme.Palette.textSecondary)
                    Text("Press + to start one")
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, Theme.Spacing.xlarge)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(list) { session in
                            row(session)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, Theme.Spacing.small)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ session: SessionSnapshot) -> some View {
        if model.renamingSessionID == session.id {
            RelayTextField("Session name", text: $renameText) {
                model.renameSession(session.id, to: renameText)
                model.renamingSessionID = nil
            }
            .padding(.horizontal, Theme.Spacing.xsmall)
            .padding(.vertical, 4)
            .onExitCommand { model.renamingSessionID = nil }
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
}
