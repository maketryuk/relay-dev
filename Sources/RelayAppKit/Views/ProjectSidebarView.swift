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
            if project.isChat {
                // Nothing to rename: the name is the app's, and it is in the
                // window's language rather than in a workspace file.
                Text(project.name)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if isRenamingProject {
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

                if !project.isChat {
                    IconButton(systemImage: "gearshape", help: "", size: 22) {
                        model.openProjectSettings()
                    }
                    .relayTooltip(relayLocalized("Project settings"), shortcut: model.binding(for: .projectSettings))
                }
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
        let tabs = model.browsers(in: project.id)

        return Group {
            if model.isReadingWorktrees(in: project.id) {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, Theme.Spacing.xlarge)
                    .accessibilityLabel(relayLocalized("Reading worktrees…"))
            } else if model.showsWorktrees(in: project.id) {
                worktrees
            } else if list.isEmpty, tabs.isEmpty {
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
                    VStack(spacing: 2) {
                        ReorderableColumn(
                            ids: list.map(\.id),
                            spacing: 2,
                            space: "relay.sessions",
                            onMove: { moved, target, side in
                                model.moveSession(moved, beside: target, side: side)
                            }
                        ) { sessionID in
                            if let session = model.sessions[sessionID] {
                                row(session, subagents: session.subagents)
                            }
                        }

                        browserTabs
                    }
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.vertical, Theme.Spacing.small)
                }
            }
        }
        .confirmationDialog(
            relayLocalized("Remove this worktree?"),
            isPresented: Binding(
                get: { model.worktreePendingRemoval != nil },
                set: { if !$0 { model.worktreePendingRemoval = nil } }
            ),
            presenting: model.worktreePendingRemoval
        ) { request in
            // Asked for by name, because the answer to "remove it" is not the
            // same question when there is work in it that exists nowhere else.
            let isDirty = model.worktreeStatuses[request.worktree.path]?.isDirty ?? false
            Button(removalButtonTitle(for: request, isDirty: isDirty), role: .destructive) {
                model.removeWorktree(
                    request.worktree,
                    discardingChanges: isDirty,
                    in: project.id,
                    following: request.forecast
                )
            }
            Button(relayLocalized("Cancel"), role: .cancel) { model.worktreePendingRemoval = nil }
        } message: { request in
            Text(verbatim: removalMessage(for: request))
        }
    }

    private func removalButtonTitle(for request: WorktreeRemovalRequest, isDirty: Bool) -> String {
        if isDirty { return relayLocalized("Remove and discard changes") }
        switch request.forecast.fate {
        case .staysUnmerged: return relayLocalized("Remove, keep branch")
        case let .detached(stranded) where stranded > 0: return relayLocalized("Remove and lose commits")
        default: return relayLocalized("Remove")
        }
    }

    /// Sessions grouped under the checkout each one is working in, the
    /// project's own first.
    ///
    /// One list per worktree, so a session is dragged among its neighbours
    /// and never into another checkout by accident: moving a row cannot move
    /// the directory its process is running in.
    private var worktrees: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(model.worktreeGroups(in: project.id)) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        WorktreeHeader(project: project, group: group)
                        if !model.isSectionCollapsed("worktree:\(group.id)") {
                            if !group.sessions.isEmpty {
                                ReorderableColumn(
                                    ids: group.sessions.map(\.id),
                                    spacing: 2,
                                    space: "relay.sessions.\(group.id)",
                                    onMove: { moved, target, side in
                                        model.moveSession(moved, beside: target, side: side)
                                    }
                                ) { sessionID in
                                    if let session = model.sessions[sessionID] {
                                        row(session, subagents: group.nestedSubagents(of: session))
                                    }
                                }
                            }
                            // After the sessions and out of their order: they
                            // are not this worktree's to rearrange.
                            ForEach(group.visitors) { visit in
                                if let session = model.sessions[visit.session] {
                                    SubagentRow(subagent: visit.subagent, session: session, isVisiting: true)
                                }
                            }
                        }
                    }
                }

                // After every worktree rather than inside one: a tab shows an
                // address, and a checkout is not something it is in.
                browserTabs
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.small)
        }
    }

    /// Below the sessions, in an order of their own: a tab is not a process,
    /// and the two lists are dragged apart.
    private var browserTabs: some View {
        ReorderableColumn(
            ids: model.browsers(in: project.id).map(\.id),
            spacing: 2,
            space: "relay.browsers",
            onMove: { moved, target, side in
                model.moveBrowser(moved, beside: target, side: side)
            }
        ) { browserID in
            if let page = model.browserPages[browserID] {
                BrowserTabRow(page: page, isSelected: model.focusedBrowser == browserID)
            }
        }
    }

    private func removalMessage(for request: WorktreeRemovalRequest) -> String {
        let worktree = request.worktree
        var lines = [String(
            format: relayLocalized("The folder %@ will be deleted."),
            HomeRelativePath.abbreviating(worktree.path)
        )]
        let running = model.sessions(in: worktree, of: project.id).count
        if running > 0 {
            lines.append(String(format: relayLocalized("Sessions in it will be closed: %d."), running))
        }
        if let status = model.worktreeStatuses[worktree.path], status.isDirty {
            lines.append(relayLocalized(
                "Changes that were never committed will be lost: %d files.",
                count: status.changedFiles
            ))
        }
        lines += branchLines(for: request.forecast)
        return lines.joined(separator: "\n")
    }

    /// What will become of the branch, judged before the question was put,
    /// so that agreeing to the removal is agreeing to that.
    private func branchLines(for forecast: GitWorktreeActions.BranchForecast) -> [String] {
        let branch = forecast.branch ?? ""
        switch forecast.fate {
        case .goes:
            guard let base = forecast.base else {
                return [String(format: relayLocalized("Branch %@ goes with it: everything on it is already merged."), branch)]
            }
            return [String(format: relayLocalized("Branch %@ goes with it: its work is already in %@."), branch, base)]
        case let .staysUnmerged(commits):
            var lines = [forecast.base.map {
                String(format: relayLocalized("Branch %@ stays: it has work that is not in %@."), branch, $0)
            } ?? String(format: relayLocalized("Branch %@ stays: it has work that is not merged anywhere yet."), branch)]
            if commits > 0 {
                lines.append(String(format: relayLocalized("Commits that are not merged: %d."), commits))
            }
            return lines
        case .staysNotRelays:
            return [String(format: relayLocalized("Branch %@ stays: Relay did not create it."), branch)]
        case let .detached(stranded):
            guard stranded > 0 else { return [] }
            return [String(format: relayLocalized("Commits on no branch, lost with it: %d"), stranded)]
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

    /// A session, and under it the subagents working where it works. One
    /// block, so dragging the session takes them along.
    private func row(_ session: SessionSnapshot, subagents: [SubagentSnapshot]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            sessionRow(session)
            ForEach(subagents) { subagent in
                SubagentRow(subagent: subagent, session: session, isVisiting: false)
            }
        }
    }

    @ViewBuilder
    private func sessionRow(_ session: SessionSnapshot) -> some View {
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
                isSelected: model.selectedSessionID == session.id && !model.browserHasKeyboard(in: project.id),
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
