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
    /// Whether the text above came from the file rather than from nowhere.
    @State private var isLoaded = false
    @State private var conflict = 0
    /// What is still in dispute in the result, and where.
    ///
    /// Parsed when the text changes rather than every time the panel draws:
    /// the panes ask for this to know what to tint, and re-reading the file on
    /// every frame of a scroll is work nobody asked for.
    @State private var pending = GitConflictFile(segments: [])
    @State private var tints: [Int: Color] = [:]

    private var isResolved: Bool { !pending.hasConflicts }
    /// The file as git left it, which is what the two side panes show.
    private var original: GitConflictFile? { model.conflict(path, in: project.id) }

    var body: some View {
        ModalSurface(path, onDismiss: { model.dismissModal() }) {
            VStack(spacing: 0) {
                if !isLoaded {
                    // Only ever seen if the panel is reached with nothing
                    // loaded: the model reads the file before opening it.
                    EmptyStateView(
                        systemImage: "doc.text",
                        title: relayLocalized("Reading…"),
                        message: ""
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    toolbar
                    RelayDivider()
                    panes
                }
            }
        } footer: {
            footer
        }
        // The model reads the file, so the first frame this panel draws
        // already has it: a panel that fills in a moment after it opens cannot
        // be told apart from a broken one.
        .onChange(of: model.conflictText(path, in: project.id) ?? "", initial: true) { _, text in
            guard !isLoaded, !text.isEmpty else { return }
            result = text
            isLoaded = true
            reread()
        }
        .onChange(of: result) { _, _ in reread() }
        .task {
            // Belt and braces: the panel can be reached with nothing loaded —
            // reopened after a reload, say — and then it asks for itself.
            guard model.conflictText(path, in: project.id) == nil else { return }
            model.loadConflict(path, in: project.id)
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

    /// Re-reads the result: what is left in dispute, and which lines to tint.
    private func reread() {
        let parsed = GitConflictFile.parse(result)
        let map = parsed.written(with: [:]).map
        var painted: [Int: Color] = [:]
        for line in map.ours { painted[line] = Theme.Palette.statusError.opacity(0.18) }
        for line in map.theirs { painted[line] = Theme.Palette.statusFinished.opacity(0.18) }
        for line in map.markers { painted[line] = Theme.Palette.statusWaiting.opacity(0.16) }
        pending = parsed
        tints = painted
        conflict = min(conflict, max(parsed.hunks.count - 1, 0))
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
            revision(title: ourTitle, tint: Theme.Palette.statusError, text: original?.version(.ours) ?? "")
            RelayDivider(axis: .vertical)
            editor
            RelayDivider(axis: .vertical)
            revision(title: theirTitle, tint: Theme.Palette.statusFinished, text: original?.version(.theirs) ?? "")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    /// One side, read-only, drawn by SwiftUI.
    ///
    /// Not a text view: three of those side by side are three AppKit views
    /// inside one SwiftUI layout, and SwiftUI gives each its own full-size
    /// compositing layer — the later ones covered the earlier ones, so two of
    /// the three panes were simply not on screen. Nothing here needs editing,
    /// and text that cannot be typed into does not need a text view.
    private func revision(title: String, tint: Color, text: String) -> some View {
        let lines = text.components(separatedBy: "\n")

        return VStack(spacing: 0) {
            paneHeader(title, tint: tint)
            ScrollView([.vertical, .horizontal], showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(verbatim: "\(index + 1)")
                                .font(Theme.Typography.mono)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .frame(width: 28, alignment: .trailing)
                            Text(verbatim: line.isEmpty ? " " : line)
                                .font(Theme.Typography.mono)
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 1)
                    }
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .defaultScrollAnchor(.topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.Palette.base)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The middle: the one pane that is typed into, and so the one AppKit view
    /// in the panel.
    private var editor: some View {
        VStack(spacing: 0) {
            paneHeader(relayLocalized("Result"), tint: Theme.Palette.accent)
            CodeTextView(text: $result, isEditable: true, tints: tints)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func paneHeader(_ title: String, tint: Color) -> some View {
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
