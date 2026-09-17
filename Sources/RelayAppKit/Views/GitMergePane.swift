import RelayProtocol
import RelayUI
import SwiftUI

/// Three revisions of one file: what each side wrote, and what is going to be
/// committed.
///
/// The middle is a text editor, not a list of buttons, because the answer to a
/// conflict is often neither side as written — a line from each, or a line that
/// mentions both. Taking a side is a shortcut for an edit, and the edit is
/// always available.
struct GitMergePane: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let path: String

    /// What will be written. Starts as the file git left behind, markers and
    /// all, and is whittled down by taking sides or by typing.
    @State private var result = ""
    @State private var original: GitConflictFile?
    @State private var conflict = 0
    @State private var scroll: CGFloat?

    /// The conflicts still in the result, re-read from it after every change:
    /// the text is what is true, and choices recorded beside it would drift
    /// from it the moment anybody typed.
    private var pending: GitConflictFile { GitConflictFile.parse(result) }
    private var isResolved: Bool { !pending.hasConflicts }

    var body: some View {
        ModalSurface(path, onDismiss: { model.dismissModal() }) {
            VStack(spacing: 0) {
                toolbar
                RelayDivider()
                panes
            }
        } footer: {
            footer
        }
        .task {
            guard let root = model.project(project.id)?.rootPath else { return }
            let url = URL(fileURLWithPath: root).appendingPathComponent(path)
            let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            result = contents
            original = GitConflictFile.parse(contents)
        }
    }

    // MARK: - What is left to settle

    private var toolbar: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(status)
                .font(Theme.Typography.rowSecondary)
                .foregroundStyle(isResolved ? Theme.Palette.statusFinished : Theme.Palette.statusWaiting)

            Spacer(minLength: Theme.Spacing.small)

            if !pending.hunks.isEmpty {
                let hunk = pending.hunks[min(conflict, pending.hunks.count - 1)]
                RelayButton(relayLocalized("Take left")) { take(.ours, hunk) }
                RelayButton(relayLocalized("Keep both")) { take(.both, hunk) }
                RelayButton(relayLocalized("Take right")) { take(.theirs, hunk) }
                if pending.hunks.count > 1 {
                    RelayButton(relayLocalized("Next")) {
                        conflict = (conflict + 1) % pending.hunks.count
                    }
                }
            }
        }
        .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
        .padding(.vertical, Theme.Spacing.small)
    }

    private var status: String {
        guard !isResolved else { return relayLocalized("Nothing left in dispute") }
        let count = pending.hunks.count
        let current = min(conflict + 1, count)
        return String(format: relayLocalized("Conflict %d of %d"), current, count)
    }

    /// Answers one conflict by rewriting the text, which is where the truth is
    /// kept: an edit by hand and a click on "take left" have to be the same
    /// kind of change or they cannot be mixed.
    private func take(_ choice: GitConflictChoice, _ hunk: GitConflictHunk) {
        result = pending.resolved(with: [hunk.id: choice])
        conflict = 0
    }

    private func takeAll(_ choice: GitConflictChoice) {
        let choices = Dictionary(uniqueKeysWithValues: pending.hunks.map { ($0.id, choice) })
        result = pending.resolved(with: choices)
        conflict = 0
    }

    // MARK: - The three revisions

    private var panes: some View {
        HStack(spacing: 0) {
            pane(
                title: ourTitle,
                tint: Theme.Palette.statusError,
                text: .constant(original?.version(.ours) ?? ""),
                isEditable: false,
                tints: [:]
            )
            RelayDivider(axis: .vertical)
            pane(
                title: relayLocalized("Result"),
                tint: Theme.Palette.accent,
                text: $result,
                isEditable: true,
                tints: resultTints
            )
            RelayDivider(axis: .vertical)
            pane(
                title: theirTitle,
                tint: Theme.Palette.statusFinished,
                text: .constant(original?.version(.theirs) ?? ""),
                isEditable: false,
                tints: [:]
            )
        }
    }

    /// The two sides keep git's own names for themselves — `HEAD` and the
    /// commit being replayed — because which of them is "mine" reverses
    /// between a merge and a rebase.
    private var ourTitle: String {
        original?.hunks.first?.ourLabel ?? relayLocalized("ours")
    }

    private var theirTitle: String {
        original?.hunks.first?.theirLabel ?? relayLocalized("theirs")
    }

    private var resultTints: [Int: Color] {
        let map = pending.written(with: [:]).map
        var tints: [Int: Color] = [:]
        for line in map.ours { tints[line] = Theme.Palette.statusError.opacity(0.18) }
        for line in map.theirs { tints[line] = Theme.Palette.statusFinished.opacity(0.18) }
        for line in map.markers { tints[line] = Theme.Palette.statusWaiting.opacity(0.16) }
        return tints
    }

    private func pane(
        title: String,
        tint: Color,
        text: Binding<String>,
        isEditable: Bool,
        tints: [Int: Color]
    ) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.xsmall) {
                Text(verbatim: title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, 5)
            .background(Theme.Palette.sidebar)

            RelayDivider()

            CodeTextView(
                text: text,
                isEditable: isEditable,
                tints: tints,
                // The three scroll together, since the same passage is at the
                // same height in all of them.
                onScroll: { offset in scroll = offset },
                scrollOffset: scroll
            )
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.small) {
            RelayButton(relayLocalized("Accept left")) { takeAll(.ours) }
            RelayButton(relayLocalized("Accept right")) { takeAll(.theirs) }

            Spacer(minLength: Theme.Spacing.small)

            RelayButton(relayLocalized("Cancel")) { model.dismissModal() }
            RelayButton(
                relayLocalized("Apply"),
                kind: isResolved ? .primary : .secondary
            ) {
                model.applyMerge(result, to: path, in: project.id)
            }
            .disabled(!isResolved)
            .opacity(isResolved ? 1 : 0.5)
            .relayTooltip(
                isResolved
                    ? relayLocalized("Writes the file and stages it")
                    : relayLocalized("Every conflict has to be answered first"),
                edge: .top
            )
        }
    }
}
