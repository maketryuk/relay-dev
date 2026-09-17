import RelayProtocol
import RelayUI
import SwiftUI

/// Resolving what a pull left behind.
///
/// Conflicts are the one part of a pull that cannot be automated away, and
/// until now Relay said git's refusal in a toast and left the repository
/// stopped mid-rebase with no way out of it that did not involve a terminal.
/// What is needed is small: which files, which two versions of each passage,
/// and the one command that finishes the operation once they are all answered.
struct GitConflictPane: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var selected: String?
    /// The answers, per file and per conflict in it. Held here rather than in
    /// the model because they describe a decision in progress, not the state
    /// of the repository — the repository learns of them when the file is
    /// written.
    @State private var choices: [String: [Int: GitConflictChoice]] = [:]

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
                    HStack(spacing: 0) {
                        files
                        RelayDivider(axis: .vertical)
                        hunks
                    }
                }
            }
        } footer: {
            footer
        }
        .task(id: path ?? "") {
            guard let path else { return }
            model.loadConflict(path, in: project.id)
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

    // MARK: - Files

    private var files: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 1) {
                ForEach(conflicted) { change in
                    Button {
                        selected = change.path
                    } label: {
                        HStack(spacing: Theme.Spacing.small) {
                            Text(verbatim: change.path)
                                .font(Theme.Typography.rowSecondary)
                                .foregroundStyle(
                                    change.path == path ? Theme.Palette.textPrimary : Theme.Palette.textSecondary
                                )
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 0)
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
                }
            }
            .padding(Theme.Spacing.small)
        }
        .frame(width: 220)
    }

    // MARK: - The two versions

    @ViewBuilder
    private var hunks: some View {
        if let path, let file = model.conflict(path, in: project.id) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
                    ForEach(file.hunks) { hunk in
                        conflictBlock(hunk, in: path)
                    }
                    if !file.hasConflicts {
                        Text(relayLocalized("No markers left in this file — mark it resolved."))
                            .font(Theme.Typography.rowSecondary)
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                }
                .padding(Theme.Spacing.medium)
            }
            .frame(maxWidth: .infinity)
        } else {
            EmptyStateView(
                systemImage: "doc.text",
                title: relayLocalized("Reading…"),
                message: ""
            )
            .frame(maxWidth: .infinity)
        }
    }

    private func conflictBlock(_ hunk: GitConflictHunk, in path: String) -> some View {
        let chosen = choices[path]?[hunk.id]

        return VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            side(
                label: hunk.ourLabel,
                lines: hunk.ours,
                isChosen: chosen == .ours || chosen == .both,
                accent: Theme.Palette.statusError
            ) {
                choose(.ours, hunk.id, in: path)
            }

            side(
                label: hunk.theirLabel,
                lines: hunk.theirs,
                isChosen: chosen == .theirs || chosen == .both,
                accent: Theme.Palette.statusFinished
            ) {
                choose(.theirs, hunk.id, in: path)
            }

            HStack(spacing: Theme.Spacing.small) {
                RelayButton(
                    relayLocalized("Keep both"),
                    kind: chosen == .both ? .primary : .secondary
                ) {
                    choose(.both, hunk.id, in: path)
                }
                if chosen != nil {
                    RelayButton(relayLocalized("Undo")) {
                        choices[path]?.removeValue(forKey: hunk.id)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(Theme.Spacing.small)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }

    /// One version of the passage, with the name git gave it.
    ///
    /// Named by git's own labels — `HEAD`, a hash and a subject — because
    /// which side is "mine" reverses between a merge and a rebase: rebasing
    /// replays your commits onto theirs, so `HEAD` is the upstream and the
    /// hash is your own work.
    private func side(
        label: String,
        lines: [String],
        isChosen: Bool,
        accent: Color,
        onChoose: @escaping () -> Void
    ) -> some View {
        Button(action: onChoose) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Spacing.small) {
                    Text(verbatim: label.isEmpty ? "—" : label)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if isChosen {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.Palette.accent)
                    }
                }
                Text(verbatim: lines.isEmpty ? "(nothing)" : lines.joined(separator: "\n"))
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(Theme.Spacing.small)
            .background(Theme.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(isChosen ? Theme.Palette.accent : Theme.Palette.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
    }

    private func choose(_ choice: GitConflictChoice, _ hunk: Int, in path: String) {
        choices[path, default: [:]][hunk] = choice
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.small) {
            if let path {
                RelayButton(relayLocalized("Open in Editor")) {
                    model.openFileInEditor(path, in: project)
                }
                RelayButton(
                    relayLocalized("Mark resolved"),
                    kind: isFileAnswered ? .primary : .secondary
                ) {
                    model.resolveConflict(path, in: project.id, choosing: choices[path] ?? [:])
                    choices.removeValue(forKey: path)
                    selected = nil
                }
                .disabled(!isFileAnswered)
                .opacity(isFileAnswered ? 1 : 0.5)
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

    /// Whether every conflict in the file on screen has an answer. A file
    /// written with one still open is a file git will refuse, which is the
    /// right refusal but a pointless round trip.
    private var isFileAnswered: Bool {
        guard let path, let file = model.conflict(path, in: project.id) else { return false }
        guard file.hasConflicts else { return true }
        let answered = choices[path] ?? [:]
        return file.hunks.allSatisfy { answered[$0.id] != nil }
    }
}
