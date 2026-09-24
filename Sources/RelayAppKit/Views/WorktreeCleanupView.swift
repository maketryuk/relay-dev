import RelayProtocol
import RelayUI
import SwiftUI

/// Every worktree of a project that could be removed, what would stop each
/// from going, and removing the chosen ones in one go.
///
/// One list rather than a series of steps: what stands in the way of a
/// worktree is written on its row, so choosing and checking are one look.
/// Nothing is removed that was not ticked and on screen when Remove was
/// pressed, and nothing is ticked that the person could not have ticked.
struct WorktreeCleanupView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var isConfirming = false

    private var state: WorktreeCleanupState { model.worktreeCleanups[project.id] ?? WorktreeCleanupState() }
    private var isRemoving: Bool { state.progress != nil }

    var body: some View {
        let now = Date()
        let all = model.worktreeCleanupCandidates(in: project.id)
        let shown = WorktreeCleanup.shown(all, filter: state.filter, now: now)
        let removable = WorktreeCleanup.removable(
            shown,
            selection: state.selection,
            discardConsent: state.discardConsent
        )

        ModalSurface(relayLocalized("Clean Up Worktrees"), onDismiss: { model.dismissModal() }) {
            VStack(alignment: .leading, spacing: 0) {
                toolbar(all: all, shown: shown, picked: removable.count, now: now)
                RelayDivider()
                list(all: all, shown: shown, now: now)
            }
        } footer: {
            footer(removable)
        }
        .refreshingWhileVisible(id: project.id, every: .seconds(30)) {
            model.readWorktreeCleanupFacts(in: project.id)
        }
        .confirmationDialog(
            String(format: relayLocalized("Remove worktrees: %d?"), removable.count),
            isPresented: $isConfirming
        ) {
            let discarding = removable.contains {
                WorktreeCleanup.discardsChanges($0, discardConsent: state.discardConsent[$0.id])
            }
            Button(
                relayLocalized(discarding ? "Remove and discard changes" : "Remove"),
                role: .destructive
            ) {
                model.removeWorktrees(removable.map(\.id), in: project.id)
            }
            Button(relayLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: confirmation(for: removable))
        }
    }

    // MARK: - Filters and picking

    private func toolbar(
        all: [WorktreeCleanupCandidate],
        shown: [WorktreeCleanupCandidate],
        picked: Int,
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: Theme.Spacing.small) {
                filterChip(relayLocalized("Merged"), systemImage: "arrow.triangle.merge", isOn: state.filter.integrated) {
                    $0.integrated.toggle()
                }
                filterChip(relayLocalized("Clean"), systemImage: "checkmark.circle", isOn: state.filter.clean) {
                    $0.clean.toggle()
                }
                HStack(spacing: 2) {
                    filterChip(
                        String(format: relayLocalized("Idle over %d days"), state.filter.idleDays),
                        systemImage: "moon.zzz",
                        isOn: state.filter.idle
                    ) {
                        $0.idle.toggle()
                    }
                    idleThreshold
                }
                Spacer(minLength: Theme.Spacing.small)
                IconButton(
                    systemImage: "arrow.clockwise",
                    help: "",
                    size: Theme.Metrics.action,
                    isEnabled: !isRemoving,
                    isBusy: state.isReading
                ) {
                    model.readWorktreeCleanupFacts(in: project.id)
                }
                .relayTooltip(relayLocalized("Read the worktrees again"))
            }

            HStack(spacing: Theme.Spacing.medium) {
                Text(String(format: relayLocalized("Shown: %d of %d"), shown.count, all.count))
                Text(String(format: relayLocalized("Picked: %d"), picked))
                Spacer(minLength: Theme.Spacing.small)
                textButton(relayLocalized("Pick suggested")) {
                    $0.select(WorktreeCleanup.suggestions(among: all, now: now))
                }
                .relayTooltip(relayLocalized("Merged, clean, nothing running in it, and left alone for a day"))
                textButton(relayLocalized("Pick all")) { changed in
                    changed.select(Set(shown.filter {
                        WorktreeCleanup.canPick($0, discardConsent: changed.discardConsent[$0.id])
                    }.map(\.id)))
                }
                textButton(relayLocalized("Pick none")) { $0.select([]) }
            }
            .font(Theme.Typography.rowSecondary)
            .foregroundStyle(Theme.Palette.textTertiary)
            .monospacedDigit()
        }
        .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
        .padding(.vertical, Theme.Spacing.medium)
    }

    private var idleThreshold: some View {
        Menu {
            ForEach(WorktreeCleanupFilter.idleChoices, id: \.self) { days in
                Button(String(format: relayLocalized("Idle over %d days"), days)) {
                    change {
                        $0.filter.idleDays = days
                        $0.filter.idle = true
                    }
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .clickable()
        .relayTooltip(relayLocalized("How long without activity"))
    }

    private func filterChip(
        _ title: String,
        systemImage: String,
        isOn: Bool,
        toggle: @escaping (inout WorktreeCleanupFilter) -> Void
    ) -> some View {
        Chip(isSelected: isOn, action: { change { toggle(&$0.filter) } }) {
            HStack(spacing: Theme.Spacing.xsmall) {
                Image(systemName: systemImage)
                    .font(.system(size: 10))
                    .foregroundStyle(isOn ? Theme.Palette.accent : Theme.Palette.textTertiary)
                Text(verbatim: title)
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(isOn ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .fixedSize()
    }

    private func textButton(_ title: String, _ apply: @escaping (inout WorktreeCleanupState) -> Void) -> some View {
        Button { change(apply) } label: {
            Text(verbatim: title).foregroundStyle(isRemoving ? Theme.Palette.textTertiary : Theme.Palette.accent)
        }
        .buttonStyle(.plain)
        .clickable(!isRemoving)
        .disabled(isRemoving)
    }

    // MARK: - Rows

    @ViewBuilder
    private func list(all: [WorktreeCleanupCandidate], shown: [WorktreeCleanupCandidate], now: Date) -> some View {
        if all.isEmpty {
            EmptyStateView(
                systemImage: "square.stack.3d.up",
                title: relayLocalized("No worktrees to clean up"),
                message: relayLocalized("The project's own folder and the main worktree are never removed here.")
            )
        } else if shown.isEmpty {
            EmptyStateView(
                systemImage: "line.3.horizontal.decrease.circle",
                title: relayLocalized("No match"),
                message: relayLocalized("No worktree fits every filter that is on.")
            )
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(shown) { candidate in
                        WorktreeCleanupRow(
                            candidate: candidate,
                            state: state,
                            now: now,
                            onToggle: { change { $0.toggle(candidate.id) } },
                            onDiscard: { discarding in
                                change { changed in
                                    if discarding {
                                        changed.consentToDiscard(candidate)
                                    } else {
                                        changed.withdrawConsent(from: candidate.id)
                                    }
                                }
                            }
                        )
                    }
                }
                .padding(Theme.Spacing.small)
            }
        }
    }

    // MARK: - Removing

    private func footer(_ removable: [WorktreeCleanupCandidate]) -> some View {
        HStack(spacing: Theme.Spacing.small) {
            Group {
                if let progress = state.progress {
                    HStack(spacing: Theme.Spacing.small) {
                        ProgressView().controlSize(.small)
                        Text(verbatim: progressLine(progress))
                            .foregroundStyle(Theme.Palette.textSecondary)
                    }
                } else {
                    Text(relayLocalized(
                        "A branch Relay made goes with its worktree only when it is merged. Any other branch stays."
                    ))
                    .foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .font(Theme.Typography.caption)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)

            RelayButton(relayLocalized("Close"), kind: .ghost) { model.dismissModal() }
            RelayButton(
                String(format: relayLocalized("Remove %d"), removable.count),
                kind: .destructive
            ) {
                isConfirming = true
            }
            .disabled(removable.isEmpty || isRemoving)
        }
    }

    private func progressLine(_ progress: WorktreeCleanupProgress) -> String {
        let name = progress.current.flatMap { path in
            model.worktrees[project.id]?.first { $0.path == path }?.name
        } ?? ""
        return String(
            format: relayLocalized("Removing %@ (%d of %d)"),
            name,
            min(progress.finished + 1, progress.total),
            progress.total
        )
    }

    /// Says what pressing it will do, in the words the sidebar uses for one.
    private func confirmation(for removable: [WorktreeCleanupCandidate]) -> String {
        var lines = [relayLocalized("Their folders will be deleted.")]
        let sessions = removable.map(\.sessions).reduce(0, +)
        if sessions > 0 {
            lines.append(String(format: relayLocalized("Sessions in them will be closed: %d."), sessions))
        }
        let discarded = removable
            .filter { WorktreeCleanup.discardsChanges($0, discardConsent: state.discardConsent[$0.id]) }
            .compactMap(\.facts?.uncommittedFiles)
            .reduce(0, +)
        if discarded > 0 {
            lines.append(String(
                format: relayLocalized("Changes that were never committed will be lost: %d files."),
                discarded
            ))
        }
        lines.append(relayLocalized(
            "Their branches are deleted only if Relay created them and everything on them is merged."
        ))
        return lines.joined(separator: "\n")
    }

    /// The one way the window changes what it was told, so a state that is
    /// not there yet — the window opened some other way than through the
    /// model — is made rather than silently not written to.
    private func change(_ apply: (inout WorktreeCleanupState) -> Void) {
        var changed = model.worktreeCleanups[project.id] ?? WorktreeCleanupState()
        apply(&changed)
        model.worktreeCleanups[project.id] = changed
    }
}

/// One worktree: a tick box, what it is, and everything that bears on
/// removing it.
private struct WorktreeCleanupRow: View {
    let candidate: WorktreeCleanupCandidate
    let state: WorktreeCleanupState
    let now: Date
    let onToggle: () -> Void
    let onDiscard: (Bool) -> Void

    @State private var isHovering = false

    private var consent: Int? { state.discardConsent[candidate.id] }
    private var blockers: [WorktreeCleanupBlocker] {
        WorktreeCleanup.blockers(of: candidate, discardConsent: consent)
    }

    private var isRemoving: Bool { state.progress != nil }
    private var isBeingRemoved: Bool { state.progress?.current == candidate.id }
    private var canPick: Bool { blockers.isEmpty && !isRemoving }
    private var isDiscarding: Bool { WorktreeCleanup.discardsChanges(candidate, discardConsent: consent) }

    /// Only where agreeing is what stands between the row and being picked:
    /// consent to lose the files under a working agent would buy nothing and
    /// leave an agreement lying about for later.
    private var offersDiscarding: Bool {
        guard !isRemoving, let files = candidate.facts?.uncommittedFiles, files > 0 else { return false }
        return isDiscarding || blockers == [.uncommittedChanges(files)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            RelayCheckbox(isOn: blockers.isEmpty && state.selection.contains(candidate.id), action: onToggle) {
                title
            }
            .disabled(!canPick)
            .opacity(blockers.isEmpty ? 1 : 0.6)

            WrappingRow(spacing: Theme.Spacing.xsmall) {
                ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                    Badge(note.text, systemImage: note.systemImage, tint: note.tint)
                }
                if offersDiscarding {
                    discardButton
                }
            }
            .padding(.leading, Self.textInset)

            if let failure = state.failures[candidate.id] {
                Text(verbatim: failure)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.statusError)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Self.textInset)
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.small)
        .background(isHovering ? Theme.Palette.surfaceHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .onHover { isHovering = $0 }
    }

    /// Past the tick box, so the notes line up under the name.
    private static let textInset: CGFloat = 15 + Theme.Spacing.small

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xsmall) {
            Image(systemName: candidate.worktree.branch == nil ? "circle.dashed" : "arrow.triangle.branch")
                .font(.system(size: 9))
                .foregroundStyle(Theme.Palette.textTertiary)
            Text(verbatim: candidate.worktree.name)
                .font(Theme.Typography.row)
                .foregroundStyle(Theme.Palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Text(verbatim: HomeRelativePath.abbreviating(candidate.worktree.path))
                .font(Theme.Typography.rowSecondary)
                .foregroundStyle(Theme.Palette.textTertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: Theme.Spacing.small)
            if isBeingRemoved {
                ProgressView().controlSize(.mini)
            } else if let last = candidate.lastActivity {
                Text(verbatim: Self.formatter.localizedString(for: last, relativeTo: now))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .relayTooltip(relayLocalized("Last activity"))
            }
        }
    }

    private struct Note {
        var text: String
        var systemImage: String?
        var tint: Color
    }

    /// What stops it first, in the colour of how much it matters; then what
    /// removing it would do.
    private var notes: [Note] {
        var notes = blockers.map { blocker in
            Note(text: blocker.reason, systemImage: symbol(for: blocker), tint: tint(for: blocker))
        }
        if candidate.worktree.isPrunable {
            notes.append(Note(
                text: relayLocalized("Folder already gone"),
                systemImage: "folder.badge.questionmark",
                tint: Theme.Palette.textTertiary
            ))
        }
        if let facts = candidate.facts {
            notes.append(integrationNote(facts))
        }
        if let unpushed = WorktreeCleanup.unpushedWork(of: candidate) {
            notes.append(Note(
                text: String(format: relayLocalized("Unpushed commits: %d, kept on its branch"), unpushed),
                systemImage: "arrow.up.circle",
                tint: Theme.Palette.statusWaiting
            ))
        }
        if isDiscarding, let files = candidate.facts?.uncommittedFiles {
            notes.append(Note(
                text: String(format: relayLocalized("Uncommitted files to discard: %d"), files),
                systemImage: "trash",
                tint: Theme.Palette.statusError
            ))
        }
        if candidate.sessions > 0 {
            notes.append(Note(
                text: String(format: relayLocalized("Sessions to close: %d"), candidate.sessions),
                systemImage: "terminal",
                tint: Theme.Palette.textTertiary
            ))
        }
        return notes
    }

    private func integrationNote(_ facts: WorktreeDiskFacts) -> Note {
        guard let base = facts.base else {
            return Note(text: relayLocalized("Nothing to compare it with"), systemImage: nil, tint: Theme.Palette.textTertiary)
        }
        switch facts.integration {
        case .merged:
            return Note(
                text: String(format: relayLocalized("Merged into %@"), base),
                systemImage: "checkmark",
                tint: Theme.Palette.statusFinished
            )
        case .squashMerged:
            return Note(
                text: String(format: relayLocalized("Squash-merged into %@"), base),
                systemImage: "checkmark",
                tint: Theme.Palette.statusFinished
            )
        case .unmerged:
            return Note(
                text: String(format: relayLocalized("Not merged into %@"), base),
                systemImage: "arrow.triangle.branch",
                tint: Theme.Palette.textTertiary
            )
        case .unknown:
            return Note(
                text: String(format: relayLocalized("Could not compare it with %@"), base),
                systemImage: nil,
                tint: Theme.Palette.textTertiary
            )
        }
    }

    private func symbol(for blocker: WorktreeCleanupBlocker) -> String? {
        switch blocker {
        case .reading: nil
        case .unreadable, .strandedCommits: "exclamationmark.triangle"
        case .locked: "lock.fill"
        case .agentWaiting: "questionmark.circle"
        case .agentWorking: "ellipsis.circle"
        case .uncommittedChanges: "pencil"
        }
    }

    private func tint(for blocker: WorktreeCleanupBlocker) -> Color {
        switch blocker {
        case .reading, .locked: Theme.Palette.textTertiary
        case .unreadable, .strandedCommits: Theme.Palette.statusError
        case .agentWaiting, .uncommittedChanges: Theme.Palette.statusWaiting
        case .agentWorking: Theme.Palette.statusWorking
        }
    }

    /// Consent to lose the files, given on the row they are in, and only for
    /// as many as there are now.
    private var discardButton: some View {
        Button { onDiscard(!isDiscarding) } label: {
            Text(relayLocalized(isDiscarding ? "Keep them" : "Discard them"))
                .font(Theme.Typography.caption)
                .foregroundStyle(isDiscarding ? Theme.Palette.textSecondary : Theme.Palette.statusError)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Theme.Palette.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
    }

    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

/// Laid out the way words are: along the line, and onto the next once it is
/// full. A row of notes that does not wrap loses the one at the end, which
/// is as likely as any to be the one that matters.
private struct WrappingRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(subviews, width: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: bounds.width)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    /// Each is offered the whole line, so one longer than it — git's words
    /// about why it could not read a worktree — wraps inside itself rather
    /// than running off the edge.
    private func arrange(_ subviews: Subviews, width: CGFloat) -> (frames: [CGRect], size: CGSize) {
        let offer = ProposedViewSize(width: width.isFinite ? width : nil, height: nil)
        var frames: [CGRect] = []
        var cursor = CGPoint.zero
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(offer)
            if cursor.x > 0, cursor.x + size.width > width {
                cursor = CGPoint(x: 0, y: cursor.y + lineHeight + spacing)
                lineHeight = 0
            }
            frames.append(CGRect(origin: cursor, size: size))
            widest = max(widest, cursor.x + size.width)
            cursor.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (frames, CGSize(width: widest, height: cursor.y + lineHeight))
    }
}
