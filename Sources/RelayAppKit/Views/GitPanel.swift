import RelayProtocol
import RelayUI
import SwiftUI

/// The working copy, file by file, in the panel beside the terminal.
///
/// Beside rather than over: reviewing what an agent just did is something you
/// do *while* it is still running, with the session that produced the change
/// still on screen and still typeable into.
struct GitPane: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var pendingDiscard: GitChange?
    @State private var areNotesExpanded = true

    private var changes: GitWorkingCopy { model.changes(in: project.id) }

    var body: some View {
        VStack(spacing: 0) {
            header
            RelayDivider()

            if !model.comments(in: project.id).isEmpty {
                notes
                RelayDivider()
            }

            if changes.isEmpty {
                EmptyStateView(
                    systemImage: "checkmark.circle",
                    title: relayLocalized("Nothing changed"),
                    message: relayLocalized("The working copy matches the last commit.")
                )
                .frame(maxHeight: .infinity)
            } else {
                files
            }

            RelayDivider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // What an agent is doing to the working copy, while it does it.
        .refreshingWhileVisible(id: project.id, every: .seconds(4)) {
            model.refreshChanges(for: project.id)
        }
        .confirmationDialog(
            relayLocalized("Discard these changes?"),
            isPresented: Binding(
                get: { pendingDiscard != nil },
                set: { if !$0 { pendingDiscard = nil } }
            ),
            presenting: pendingDiscard
        ) { change in
            Button(relayLocalized("Discard"), role: .destructive) {
                model.discard(change, in: project.id)
                pendingDiscard = nil
            }
            Button(relayLocalized("Cancel"), role: .cancel) { pendingDiscard = nil }
        } message: { change in
            Text(change.worktree == .untracked
                ? String(format: relayLocalized("%@ will be deleted. This cannot be undone."), change.path)
                : String(format: relayLocalized("%@ will go back to the last committed version."), change.path))
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xsmall) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)

                if let status = model.gitStatuses[project.id] {
                    Button {
                        model.pickBranch(in: project.id)
                    } label: {
                        HStack(spacing: Theme.Spacing.xsmall) {
                            Text(status.branch)
                                .font(Theme.Typography.title)
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(Theme.Palette.textTertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .clickable()
                    .relayTooltip(relayLocalized("Switch branch"))

                    // The same two colours the project tile gives them: work
                    // of yours that the remote has not got, and work of
                    // everyone else's that you have not. Grey here and
                    // coloured there read as two different facts.
                    if status.ahead > 0 {
                        Text(verbatim: "↑\(status.ahead)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.statusFinished)
                            .monospacedDigit()
                    }
                    if status.behind > 0 {
                        Text(verbatim: "↓\(status.behind)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.statusWorking)
                            .monospacedDigit()
                    }
                }

                Spacer(minLength: Theme.Spacing.xsmall)

                if let running = model.runningRemoteCommand {
                    Text(relayLocalized(running.title))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }

                IconButton(systemImage: "arrow.clockwise", help: "", size: Theme.Metrics.action) {
                    model.refreshChanges(for: project.id)
                    model.refreshGit(for: project.id)
                }
                .relayTooltip(relayLocalized("Re-read the working copy"))

                commandMenu
            }

            HStack(spacing: Theme.Spacing.small) {
                StagingToggle(
                    isOn: !changes.changes.isEmpty && changes.changes.allSatisfy(\.isStaged),
                    isMixed: changes.staged.count > 0 && changes.staged.count < changes.changes.count
                ) { model.setAllStaged(!changes.changes.allSatisfy(\.isStaged), in: project.id) }
                    .relayTooltip(relayLocalized("Stage all"))

                Text(String(format: relayLocalized("%d changed"), changes.changes.count))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .monospacedDigit()

                Spacer(minLength: 0)

                Text(verbatim: "+\(totals.insertions)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.statusFinished)
                    .monospacedDigit()
                Text(verbatim: "−\(totals.deletions)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.statusError)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, Theme.Spacing.small)
    }

    private var totals: (insertions: Int, deletions: Int) {
        changes.changes.reduce(into: (0, 0)) { total, change in
            total.0 += change.insertions
            total.1 += change.deletions
        }
    }

    private var commandMenu: some View {
        Menu {
            // The three dots are the difference: a pull and a push open the
            // panel that says where they are going, since the last answer is
            // not always this one — and a force push has to be seen before it
            // happens. Fetch asks nothing and changes nothing here.
            Button {
                model.planTransfer(.pull, in: project.id)
            } label: {
                Label(relayLocalized("Pull…"), systemImage: "arrow.down")
            }
            Button {
                model.planTransfer(.push, in: project.id)
            } label: {
                Label(relayLocalized("Push…"), systemImage: "arrow.up")
            }
            Button {
                model.run(.fetch, in: project.id)
            } label: {
                Label(relayLocalized("Fetch"), systemImage: "arrow.triangle.2.circlepath")
            }
            if !changes.conflicted.isEmpty || model.mergeState(in: project.id).isInProgress {
                Button {
                    model.resolveConflicts(in: project.id)
                } label: {
                    Label(relayLocalized("Resolve conflicts…"), systemImage: "exclamationmark.triangle")
                }
            }
            Divider()
            Button(relayLocalized("Stage all")) { model.setAllStaged(true, in: project.id) }
            Button(relayLocalized("Unstage all")) { model.setAllStaged(false, in: project.id) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .clickable()
        .relayTooltip(relayLocalized("Git commands"))
    }

    // MARK: - Files

    private var files: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: Theme.Spacing.small) {
                ForEach(ordered) { change in
                    FileCard(
                        project: project,
                        change: change,
                        onDiscard: { pendingDiscard = change }
                    )
                }
            }
            .padding(Theme.Spacing.small)
        }
    }

    /// Conflicts first, because nothing else can be committed until they are
    /// gone; then whatever is still in flight; then what is already staged.
    private var ordered: [GitChange] {
        changes.conflicted
            + changes.changes.filter { !$0.isConflicted && !$0.isStaged }
            + changes.changes.filter { !$0.isConflicted && $0.isStaged }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            CommitMessageField(text: Binding(
                get: { model.commitMessage },
                set: { model.commitMessage = $0 }
            ))

            HStack(spacing: Theme.Spacing.small) {
                RelayButton(commitTitle, kind: .primary) {
                    model.commitStagedChanges(in: project.id)
                }
                .disabled(!canCommit)
                .opacity(canCommit ? 1 : 0.45)

                RelayButton(relayLocalized("Commit and Push")) {
                    model.commitStagedChanges(in: project.id, andPush: true)
                }
                .disabled(!canCommit)
                .opacity(canCommit ? 1 : 0.45)

                Spacer(minLength: 0)
            }
        }
        .padding(Theme.Spacing.small)
    }

    private var commitTitle: String {
        changes.staged.isEmpty
            ? relayLocalized("Commit")
            : String(format: relayLocalized("Commit %d"), changes.staged.count)
    }

    private var canCommit: Bool {
        !changes.staged.isEmpty
            && !model.commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isCommitting
    }

    private var notesForProject: [ReviewComment] { model.comments(in: project.id) }

    /// What has been written on the diff, and the thing worth doing with it:
    /// handing it to an agent — the one already working, or a new one.
    private var notes: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.small) {
                Button { areNotesExpanded.toggle() } label: {
                    HStack(spacing: Theme.Spacing.xsmall) {
                        Image(systemName: areNotesExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textTertiary)
                        Image(systemName: "text.bubble")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Text(relayLocalized("Notes"))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textSecondary)
                        Text(verbatim: "\(notesForProject.count)")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .monospacedDigit()
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()

                SendNotesMenu(project: project, comments: notesForProject)

                IconButton(systemImage: "doc.on.doc", help: "", size: Theme.Metrics.action) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(ReviewCommentTranscript.compose(notesForProject), forType: .string)
                }
                .relayTooltip(relayLocalized("Copy notes"))

                IconButton(systemImage: "trash", help: "", size: Theme.Metrics.action) { model.clearComments(in: project.id) }
                    .relayTooltip(relayLocalized("Clear"))
            }
            .padding(.horizontal, Theme.Spacing.small)
            .padding(.vertical, Theme.Spacing.xsmall)

            if areNotesExpanded {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(notesForProject) { comment in
                            NoteRow(project: project, comment: comment)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.small)
                    .padding(.bottom, Theme.Spacing.small)
                }
                // Enough for a few notes without the file list losing the panel.
                .frame(maxHeight: 180)
            }
        }
    }
}

/// One note: where it is, what it says, and the two things
/// to do with it.
private struct NoteRow: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let comment: ReviewComment

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draft = ""

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            // A fixed column: `L8` and `L431` are different widths, and text
            // that starts wherever the number happens to end reads as a list
            // that cannot hold a straight line.
            Text(verbatim: comment.line.map { "L\($0)" } ?? "")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .monospacedDigit()
                .frame(width: 34, alignment: .trailing)

            if isEditing {
                RelayTextField(relayLocalized("Comment on this line"), text: $draft) { commit() }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(comment.text)
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(2)
                    Text(comment.path)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                Spacer(minLength: 0)
            }

            HoverReveal(isVisible: isHovering || isEditing) {
                HStack(spacing: Theme.Spacing.xxsmall) {
                    if isEditing {
                        IconButton(systemImage: "checkmark", help: "", size: Theme.Metrics.action) { commit() }
                    } else {
                        SendNotesMenu(project: project, comments: [comment], size: Theme.Metrics.action)
                        IconButton(systemImage: "pencil", help: "", size: Theme.Metrics.action) {
                            draft = comment.text
                            isEditing = true
                        }
                        .relayTooltip(relayLocalized("Edit"))
                    }
                    IconButton(systemImage: "trash", help: "", size: Theme.Metrics.action) { model.removeComment(comment) }
                        .relayTooltip(relayLocalized("Delete"))
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 4)
        .background(isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .onHover { isHovering = $0 }
    }

    private func commit() {
        model.updateComment(comment, text: draft)
        isEditing = false
    }
}

/// Where notes go: a session already running, or one started for them.
private struct SendNotesMenu: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let comments: [ReviewComment]
    var size: CGFloat = Theme.Metrics.action

    var body: some View {
        Menu {
            let agents = model.agentsForReview(in: project.id)
            if !agents.isEmpty {
                Section(relayLocalized("Send notes to")) {
                    ForEach(agents) { session in
                        Button(model.label(for: session)) { model.send(comments, to: session.id) }
                    }
                }
            }
            Section(relayLocalized("New agent")) {
                ForEach(model.sessionPresets.filter(\.kind.isAgent)) { preset in
                    Button(preset.name) {
                        model.send(comments, toNewSessionFrom: preset, in: project.id)
                    }
                }
            }
        } label: {
            Image(systemName: "paperplane")
                // The ratio `IconButton` uses. Anything else and the two
                // sitting side by side look like different sizes, because they
                // are.
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(Theme.Palette.accent)
                .frame(width: size, height: size)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: size)
        .clickable()
        .relayTooltip(relayLocalized("Send notes"))
    }
}



// MARK: - One file

private struct FileCard: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let change: GitChange
    let onDiscard: () -> Void

    @State private var isHovering = false

    private var isExpanded: Bool { model.isExpanded(change) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                RelayDivider()
                body(for: change)
            }
        }
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .strokeBorder(Theme.Palette.border, lineWidth: 1)
        )
        .onHover { isHovering = $0 }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            StagingToggle(isOn: change.isStaged, isMixed: change.isStaged && change.isUnstaged) {
                model.setStaged(change, !change.isStaged, in: project.id)
            }
            .relayTooltip(change.isStaged ? relayLocalized("Unstage") : relayLocalized("Stage"))

            Button {
                model.toggleExpansion(of: change, in: project.id)
            } label: {
                HStack(spacing: Theme.Spacing.small) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .frame(width: 10)

                    Text(change.name)
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if !change.directory.isEmpty {
                        Text(change.directory)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .layoutPriority(-1)
                    }

                    Spacer(minLength: Theme.Spacing.xsmall)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .clickable()

            counts

            HoverReveal(isVisible: isHovering) {
                HStack(spacing: Theme.Spacing.xxsmall) {
                    IconButton(systemImage: "doc.on.doc", help: "", size: Theme.Metrics.action) { copyPath() }
                        .relayTooltip(relayLocalized("Copy path"))
                    IconButton(systemImage: "arrow.uturn.backward", help: "", size: Theme.Metrics.action, action: onDiscard)
                        .relayTooltip(relayLocalized("Discard"))
                    IconButton(systemImage: "arrow.up.forward.square", help: "", size: Theme.Metrics.action) { open() }
                        .relayTooltip(relayLocalized("Open"))
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 6)
    }

    private var counts: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            if change.insertions > 0 {
                Text(verbatim: "+\(change.insertions)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.statusFinished)
                    .monospacedDigit()
            }
            if change.deletions > 0 {
                Text(verbatim: "−\(change.deletions)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.statusError)
                    .monospacedDigit()
            }
            if change.worktree == .untracked {
                Text(relayLocalized("new"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            if change.isConflicted {
                Text(relayLocalized("conflict"))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.statusWaiting)
            }
        }
    }

    @ViewBuilder
    private func body(for change: GitChange) -> some View {
        if let diff = model.fileDiffs[change.path] {
            if diff.isBinary {
                note(relayLocalized("Binary file"))
            } else if diff.isTooLarge {
                note(relayLocalized("Too large to show"))
            } else if diff.isEmpty {
                note(relayLocalized("No textual difference"))
            } else {
                DiffBody(project: project, change: change, diff: diff)
            }
        } else if model.loadingDiffs.contains(change.path) {
            note(relayLocalized("Reading…"))
        } else {
            note(relayLocalized("Nothing to show"))
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.textTertiary)
            .padding(Theme.Spacing.small)
    }

    private func copyPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(change.path, forType: .string)
    }

    private func open() {
        model.openFileInEditor(change.path, in: project)
    }
}

// MARK: - The diff itself

private struct DiffBody: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let change: GitChange
    let diff: FileDiff

    /// The line a remark is being written on, if any.
    @State private var composingAt: Int?
    @State private var draft = ""
    @State private var hoveredLine: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(diff.hunks.enumerated()), id: \.element.id) { index, hunk in
                if let hidden = hiddenLines(before: index), hidden > 0 {
                    UnmodifiedGap(count: hidden) {
                        model.expandContext(of: change, in: project.id)
                    }
                }

                ForEach(hunk.lines) { line in
                    row(line)
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// How many untouched lines sit between what is drawn above and this hunk.
    private func hiddenLines(before index: Int) -> Int? {
        let hunk = diff.hunks[index]
        guard index > 0 else { return hunk.oldStart - 1 }
        let previous = diff.hunks[index - 1]
        return hunk.oldStart - previous.oldEnd
    }

    @ViewBuilder
    private func row(_ line: DiffLine) -> some View {
        DiffLineRow(
            line: line,
            isHovered: hoveredLine == line.id,
            onHover: { hoveredLine = $0 ? line.id : (hoveredLine == line.id ? nil : hoveredLine) },
            onComment: {
                composingAt = line.id
                draft = ""
            }
        )

        ForEach(model.comments(for: change.path, in: project.id).filter { $0.line != nil && $0.line == line.number }) { comment in
            CommentBubble(comment: comment) { model.removeComment(comment) }
        }

        if composingAt == line.id {
            CommentComposer(text: $draft) {
                model.comment(on: change.path, line: line.number, code: line.text, text: draft, in: project.id)
                composingAt = nil
                draft = ""
            } onCancel: {
                composingAt = nil
                draft = ""
            }
        }
    }
}

/// The "26 unmodified lines" strip, which is also the way to see them.
private struct UnmodifiedGap: View {
    let count: Int
    let onExpand: () -> Void

    var body: some View {
        Button(action: onExpand) {
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .frame(width: 44, alignment: .trailing)
                Text(String(format: relayLocalized("%d unmodified lines"), count))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 3)
            .background(Theme.Palette.surfaceRaised.opacity(0.6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let isHovered: Bool
    let onHover: (Bool) -> Void
    let onComment: () -> Void

    /// The gutter is as wide as the widest line number the panel is likely to
    /// show, and never changes width: a column that resizes under the pointer
    /// takes the code with it.
    private static let gutterWidth: CGFloat = 48

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(number)
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.Palette.statusOffline)
                .monospacedDigit()
                .frame(width: Self.gutterWidth - 4, alignment: .trailing)
                .padding(.trailing, 4)
                // Hidden rather than removed: the button below is drawn over
                // the number, and taking the number out would move the line.
                .opacity(isHovered ? 0 : 1)

            Text(verbatim: sign)
                .font(Theme.Typography.mono)
                .foregroundStyle(tint)
                .frame(width: 10, alignment: .leading)

            Text(verbatim: line.text)
                .font(Theme.Typography.mono)
                .foregroundStyle(line.kind == .context ? Theme.Palette.textSecondary : tint)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, Theme.Spacing.small)
        }
        .background(background)
        // An overlay, so the row keeps the height of its text. Laid out in the
        // line, the button — taller than a line of code — grew every row the
        // pointer touched, and the file appeared to shift under it.
        .overlay(alignment: .topLeading) {
            if isHovered {
                Button(action: onComment) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 9.5))
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(width: Self.gutterWidth - 6, height: 14, alignment: .leading)
                        .padding(.leading, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()
                .relayTooltip(relayLocalized("Comment on this line"))
            }
        }
        .onHover(perform: onHover)
    }

    private var number: String {
        line.number.map(String.init) ?? ""
    }

    private var sign: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .note: "\\"
        case .context: " "
        }
    }

    private var tint: Color {
        switch line.kind {
        case .added: Theme.Palette.statusFinished
        case .removed: Theme.Palette.statusError
        case .note: Theme.Palette.textTertiary
        case .context: Theme.Palette.textSecondary
        }
    }

    /// The pointer is answered with light rather than with movement.
    private var background: Color {
        switch line.kind {
        case .added: Theme.Palette.statusFinished.opacity(isHovered ? 0.17 : 0.1)
        case .removed: Theme.Palette.statusError.opacity(isHovered ? 0.17 : 0.1)
        default: isHovered ? Theme.Palette.surfaceHover.opacity(0.6) : .clear
        }
    }
}

private struct CommentBubble: View {
    let comment: ReviewComment
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 9))
                .foregroundStyle(Theme.Palette.accent)
            Text(comment.text)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            IconButton(systemImage: "xmark", help: "", size: 16, action: onRemove)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 5)
        .background(Theme.Palette.accentMuted.opacity(0.5))
    }
}

private struct CommentComposer: View {
    @Binding var text: String
    let onAdd: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.small) {
            RelayTextField(relayLocalized("Comment on this line"), text: $text, onSubmit: onAdd)
            RelayButton(relayLocalized("Add"), kind: .primary, action: onAdd)
            IconButton(systemImage: "xmark", help: "", size: Theme.Metrics.action, action: onCancel)
        }
        .padding(.horizontal, Theme.Spacing.small)
        .padding(.vertical, 5)
        .background(Theme.Palette.surfaceRaised)
    }
}

// MARK: - Pieces

/// The tick that says whether a file would be carried by the next commit.
private struct StagingToggle: View {
    let isOn: Bool
    let isMixed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isOn || isMixed ? Theme.Palette.accent : Theme.Palette.textTertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
    }

    private var symbol: String {
        if isMixed { return "minus.square.fill" }
        return isOn ? "checkmark.square.fill" : "square"
    }
}

/// A commit message is a subject and a body, so it is not one line.
///
/// Built on the text view rather than on `TextEditor`, because the editor's
/// insets are not ours to set: its first line sits a few points above and to
/// the left of anything drawn over it, so the caret never lines up with the
/// prompt it is sitting on. Here the inset is stated, and the placeholder uses
/// the same one.
private struct CommitMessageField: View {
    @Binding var text: String
    @State private var isFocused = false

    /// Shared by the text and the prompt, which is the whole point.
    static let inset: CGFloat = 7

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(relayLocalized("Commit message"))
                    .font(Theme.Typography.row)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .padding(.horizontal, Self.inset)
                    .padding(.top, Self.inset)
                    .allowsHitTesting(false)
            }

            MessageTextView(text: $text, isFocused: $isFocused)
        }
        .frame(height: 62)
        .background(Theme.Palette.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(isFocused ? Theme.Palette.accent.opacity(0.7) : Theme.Palette.border, lineWidth: 1)
        )
    }
}

private struct MessageTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.focusRingType = .none

        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.string = text
        view.font = .systemFont(ofSize: 12.5, weight: .medium)
        view.textColor = NSColor(Theme.Palette.textPrimary)
        view.insertionPointColor = NSColor(Theme.Palette.accent)
        view.drawsBackground = false
        view.isRichText = false
        view.allowsUndo = true
        view.focusRingType = .none
        view.textContainerInset = NSSize(width: CommitMessageField.inset, height: CommitMessageField.inset)
        // The text container adds five points of its own on each side, which is
        // five points the prompt drawn over it does not have.
        view.textContainer?.lineFragmentPadding = 0
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>
        private let isFocused: Binding<Bool>

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            self.text = text
            self.isFocused = isFocused
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }

        func textDidBeginEditing(_ notification: Notification) {
            isFocused.wrappedValue = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isFocused.wrappedValue = false
        }
    }
}
