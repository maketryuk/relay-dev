import RelayProtocol
import RelayUI
import SwiftUI

/// The line a worktree's sessions are grouped under.
///
/// It carries what the session rows used to repeat: the branch and how far the
/// work on it has got. A click anywhere on it folds it, the way a heading
/// does everywhere else; turning the right-hand panel to this checkout is what
/// choosing one of its sessions does, and "Review Changes" for one with none.
struct WorktreeHeader: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let group: WorktreeGroup

    @State private var isHovering = false
    @State private var isShowingNewSessionMenu = false

    private static let buttonSize: CGFloat = 18

    private var worktree: GitWorktree { group.worktree }
    private var collapseKey: String { "worktree:\(worktree.path)" }
    private var isCollapsed: Bool { model.isSectionCollapsed(collapseKey) }
    private var isActive: Bool { model.isActiveWorktree(worktree, in: project.id) }
    private var status: GitStatus? { model.worktreeStatuses[worktree.path] }

    var body: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(Theme.Palette.textTertiary)
                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                .frame(width: 12, height: 16)

            Image(systemName: worktree.branch == nil ? "circle.dashed" : "arrow.triangle.branch")
                .font(.system(size: 9))
                .foregroundStyle(Theme.Palette.textTertiary)

            Text(verbatim: worktree.name)
                .font(Theme.Typography.rowSecondary.weight(.semibold))
                .foregroundStyle(isActive ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if worktree.isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .relayTooltip(relayLocalized("Locked: git will not remove it until it is unlocked"))
            }

            Spacer(minLength: Theme.Spacing.xsmall)

            // Only while hovered, and to the left of the diff rather than
            // hidden beside it: a button that keeps its place when invisible
            // keeps the diff off the edge it belongs against.
            if isHovering || isShowingNewSessionMenu {
                IconButton(systemImage: "plus", help: "", size: Self.buttonSize) {
                    model.activateWorktree(worktree.path, in: project.id)
                    isShowingNewSessionMenu = true
                }
                .relayTooltip(relayLocalized("New session in this worktree"))
                .popover(isPresented: $isShowingNewSessionMenu, arrowEdge: .bottom) {
                    NewSessionMenu(projectID: project.id) { isShowingNewSessionMenu = false }
                }
            }

            // Folded, the rows are not there to say who needs attention.
            let reporting = group.sessions.filter(\.reportsStatus)
            if isCollapsed, !reporting.isEmpty {
                StatusDot(status: RuntimeStatus.aggregate(reporting.map(\.status)), size: 7)
            }

            if let status, status.hasDiff {
                DiffBadge(insertions: status.insertions, deletions: status.deletions)
            }
        }
        // As tall as the button that comes and goes, so the row does not
        // grow under the pointer when it appears.
        .frame(height: Self.buttonSize)
        .padding(.leading, Theme.Spacing.xsmall)
        .padding(.trailing, Theme.Spacing.xsmall)
        .padding(.vertical, 3)
        .background(isHovering ? Theme.Palette.surfaceHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .contentShape(Rectangle())
        .clickable()
        .onHover { isHovering = $0 }
        .onTapGesture { model.toggleSection(collapseKey) }
        .relayTooltip(HomeRelativePath.abbreviating(worktree.path), edge: .trailing)
        .contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        Button(relayLocalized("Review Changes")) {
            model.openWorktree(worktree, in: project.id)
            model.reviewChanges(in: project.id)
        }
        Divider()
        Button(relayLocalized("Reveal in Finder")) { model.revealInFinder(worktree.path) }
        Button(relayLocalized("Copy Path")) { model.copyToClipboard(worktree.path) }
        if model.canRemoveWorktree(worktree, in: project.id) {
            Divider()
            Button(relayLocalized("Remove Worktree…")) { model.worktreePendingRemoval = worktree }
        }
        if model.offersWorktreeCleanup(in: project.id) {
            if !model.canRemoveWorktree(worktree, in: project.id) { Divider() }
            Button(RelayCommand.cleanUpWorktrees.localizedTitle + "…") {
                model.beginWorktreeCleanup(in: project.id)
            }
        }
    }
}
