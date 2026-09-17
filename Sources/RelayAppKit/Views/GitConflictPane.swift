import RelayProtocol
import RelayUI
import SwiftUI

/// What a pull left unsettled, file by file.
///
/// A list rather than an editor: most conflicts are answered wholesale — take
/// mine, take theirs — and the ones that are not are answered in the merge
/// panes, which this opens. Offering the whole apparatus for a file that only
/// needs one of two buttons is how a dialog becomes something to get through.
struct GitConflictPane: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var selected: String?

    private var conflicted: [GitChange] { model.changes(in: project.id).conflicted }
    private var state: GitMergeState { model.mergeState(in: project.id) }
    private var path: String? { selected ?? conflicted.first?.path }

    var body: some View {
        ModalSurface(relayLocalized("Resolve conflicts"), onDismiss: { model.dismissModal() }) {
            VStack(alignment: .leading, spacing: 0) {
                summary
                RelayDivider()
                if conflicted.isEmpty {
                    EmptyStateView(
                        systemImage: "checkmark.circle",
                        title: relayLocalized("Nothing is conflicted"),
                        message: relayLocalized("Everything has been resolved and staged.")
                    )
                    .frame(maxHeight: .infinity)
                } else {
                    table
                }
            }
        } footer: {
            footer
        }
        .refreshingWhileVisible(id: project.id, every: .seconds(3)) {
            model.refreshChanges(for: project.id)
        }
    }

    // MARK: - What is going on

    private var summary: some View {
        HStack(spacing: Theme.Spacing.small) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Palette.statusWaiting)
            Text(operationName)
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Palette.textPrimary)
            Text(String(format: relayLocalized("%d conflicted"), conflicted.count))
                .font(Theme.Typography.rowSecondary)
                .foregroundStyle(Theme.Palette.textTertiary)
                .monospacedDigit()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
        .padding(.vertical, Theme.Spacing.small)
    }

    private var operationName: String {
        switch state.operation {
        case .rebase: relayLocalized("Rebase in progress")
        case .merge: relayLocalized("Merge in progress")
        case .cherryPick: relayLocalized("Cherry-pick in progress")
        case .revert: relayLocalized("Revert in progress")
        case nil: relayLocalized("Conflicts in the working copy")
        }
    }

    // MARK: - The files

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.small) {
                Text(relayLocalized("File"))
                Spacer(minLength: Theme.Spacing.small)
                Text(relayLocalized("ours"))
                    .frame(width: 90, alignment: .leading)
                Text(relayLocalized("theirs"))
                    .frame(width: 90, alignment: .leading)
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, 6)

            RelayDivider()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 1) {
                    ForEach(conflicted) { change in
                        row(change)
                    }
                }
                .padding(Theme.Spacing.small)
            }
        }
    }

    private func row(_ change: GitChange) -> some View {
        Button {
            selected = change.path
        } label: {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "doc.text")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(verbatim: change.path)
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(change.path == path ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: Theme.Spacing.small)
                Text(ConflictSides.describe(change.unmergedCode?.ours))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(width: 90, alignment: .leading)
                Text(ConflictSides.describe(change.unmergedCode?.theirs))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(width: 90, alignment: .leading)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 6)
            .background(change.path == path ? Theme.Palette.surfaceActive : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .relayTooltip(change.path)
        .onTapGesture(count: 2) { merge(change.path) }
    }

    private func merge(_ path: String) {
        model.openMerge(path, in: project.id)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.small) {
            if let path {
                RelayButton(relayLocalized("Accept ours")) {
                    model.acceptSide(.ours, of: path, in: project.id)
                }
                RelayButton(relayLocalized("Accept theirs")) {
                    model.acceptSide(.theirs, of: path, in: project.id)
                }
                RelayButton(relayLocalized("Merge…"), kind: .primary) { merge(path) }
            }

            Spacer(minLength: Theme.Spacing.small)

            if state.isInProgress {
                RelayButton(relayLocalized("Abort"), kind: .destructive) {
                    model.abortMergeOperation(in: project.id)
                }
                RelayButton(
                    relayLocalized("Continue"),
                    kind: conflicted.isEmpty ? .primary : .secondary
                ) {
                    model.finishMergeOperation(in: project.id)
                }
                .disabled(!conflicted.isEmpty)
                .opacity(conflicted.isEmpty ? 1 : 0.5)
            }
        }
    }
}

/// How each side fared, as the two letters of an unmerged entry say.
enum ConflictSides {
    @MainActor
    static func describe(_ state: GitFileState?) -> String {
        switch state {
        case .deleted: relayLocalized("Deleted")
        case .added: relayLocalized("Added")
        case .modified, .conflicted: relayLocalized("Modified")
        default: "—"
        }
    }
}
