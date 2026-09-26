import AppKit
import RelayProtocol
import RelayTracker
import RelayUI
import SwiftUI

/// One issue: what it says, what people said on it, its fields, and the time
/// spent on it — each of which can be changed from here.
///
/// Opened over the board, so closing it goes back to the board rather than to
/// the terminal. Handing it to an agent closes both, because the agent's
/// terminal is where the next thing happens.
struct IssuePane: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let key: String

    @State private var editingSummary: String?
    @State private var editingDescription: String?
    @State private var reply = ""
    @State private var mentions = MentionState()

    private var tracker: TrackerController { model.tracker }
    private var issue: TrackerIssue? { tracker.issues[key] }
    /// What the board knew, to show something before the issue has been read.
    private var card: TrackerCard? { tracker.card(key) }

    var body: some View {
        VStack(spacing: 0) {
            header
            RelayDivider()
            if let issue {
                HStack(alignment: .top, spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xlarge) {
                            descriptionSection(issue)
                            if !issue.attachments.isEmpty {
                                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                                    sectionTitle(String(format: relayLocalized("Attachments: %d"), issue.attachments.count))
                                    AttachmentsSection(attachments: issue.attachments)
                                }
                            }
                            commentsSection(issue)
                        }
                        .padding(ModalSurface<EmptyView, EmptyView>.horizontalInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    RelayDivider(axis: .vertical)
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xlarge) {
                            IssueFieldsSection(issue: issue)
                            IssueTimeSection(issue: issue)
                        }
                        .padding(Theme.Spacing.large)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(width: 300)
                    .background(Theme.Palette.sidebar)
                }
            } else if let failure = tracker.issueFailures[key] {
                VStack(spacing: Theme.Spacing.medium) {
                    EmptyStateView(
                        systemImage: "exclamationmark.triangle",
                        title: String(format: relayLocalized("Could not read %@"), key),
                        message: TrackerText.describe(failure)
                    )
                    .frame(height: 160)
                    RelayButton(relayLocalized("Try Again")) { tracker.open(key) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.Palette.base)
        .onAppear { if issue == nil { tracker.open(key) } }
        // Whoever can be mentioned is whoever the issue knows of, and that is
        // known only once it has been read.
        .onChange(of: peopleSignature, initial: true) {
            mentions.people = issue?.people(with: tracker.comments[key] ?? []) ?? []
        }
    }

    /// Who opened the issue and who changed it last, and when — which is
    /// most of what says whether it is still being worked on.
    private func history(of issue: TrackerIssue) -> String? {
        let now = Date()
        // An issue read without the dates has them at the epoch.
        let known = Date(timeIntervalSince1970: 1)
        var parts: [String] = []
        if issue.created > known {
            let when = relayRelativeTime(issue.created, relativeTo: now)
            parts.append(issue.reporter.map { String(format: relayLocalized("Reported by %@, %@"), $0.name, when) }
                ?? String(format: relayLocalized("Created %@"), when))
        }
        // Changed since it was made, which a minute after is not.
        if issue.updated > known, issue.updated.timeIntervalSince(issue.created) > 60 {
            let when = relayRelativeTime(issue.updated, relativeTo: now)
            parts.append(issue.updater.map { String(format: relayLocalized("Updated by %@, %@"), $0.name, when) }
                ?? String(format: relayLocalized("Updated %@"), when))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Header

    private var summary: String { issue?.summary ?? card?.summary ?? "" }

    /// The key on a line of its own above the summary, as the tracker lays an
    /// issue out: it is what gets copied and said aloud, and beside a summary
    /// two lines long it pushed the summary into a column of its own.
    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                HStack(spacing: Theme.Spacing.xsmall) {
                    Text(verbatim: key)
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.Palette.surfaceRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .textSelection(.enabled)
                    IssueCopyButton(key: key, summary: summary)
                    if let issue, let history = history(of: issue) {
                        Text(verbatim: history)
                            .font(Theme.Typography.rowSecondary)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .lineLimit(1)
                            .padding(.leading, Theme.Spacing.xsmall)
                    }
                }
                .frame(height: Self.actionHeight)

                if let draft = editingSummary {
                    HStack(spacing: Theme.Spacing.small) {
                        RelayTextField(relayLocalized("Summary"), text: Binding(
                            get: { draft },
                            set: { editingSummary = $0 }
                        ), autofocus: true, onSubmit: saveSummary)
                        RelayButton(relayLocalized("Cancel"), kind: .ghost) { editingSummary = nil }
                        RelayButton(relayLocalized("Save"), kind: .primary, action: saveSummary)
                            .disabled(tracker.writesInFlight.contains(.edit(key)))
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        Text(verbatim: summary)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        if issue != nil {
                            IconButton(systemImage: "pencil", size: Theme.Metrics.action) { editingSummary = summary }
                                .relayTooltip(relayLocalized("Edit the summary"))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // The timer is in the menu: it is started from here seldom enough
            // that a button beside the summary was mostly in the way.
            HStack(spacing: Theme.Spacing.small) {
                sendMenu
                moreMenu
                IconButton(systemImage: "xmark", size: Self.actionHeight) { model.dismissModal() }
            }
            .frame(height: Self.actionHeight)
        }
        .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
        // Taller than other panels' bars: it holds two lines, the key and a
        // summary that may itself be two.
        .padding(.vertical, Theme.Spacing.large)
    }

    /// The height of everything on the key's line, the buttons across from it
    /// included, so they line up on one centre rather than on their tops.
    private static let actionHeight: CGFloat = 28

    private var sendMenu: some View {
        Menu {
            IssueHandoverTargets(project: project, key: key)
        } label: {
            HStack(spacing: Theme.Spacing.xsmall) {
                Image(systemName: "paperplane")
                    .font(.system(size: 11, weight: .semibold))
                Text(relayLocalized("Send to Agent"))
                    .font(Theme.Typography.row)
            }
            .foregroundStyle(Color.white)
            .padding(.horizontal, Theme.Spacing.medium)
            .frame(height: Self.actionHeight)
            .background(Theme.Palette.accent)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        }
        // A button-styled menu draws its label as given; a borderless one
        // keeps only the text and the image, and the pill would be lost.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .clickable()
    }

    private var moreMenu: some View {
        Menu {
            IssueMenuItems(
                project: project,
                key: key,
                summary: summary,
                trackerProject: issue?.project ?? card?.project,
                offersOpening: false
            )
            Divider()
            Button(relayLocalized("Reload")) { tracker.open(key) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.Palette.textSecondary)
                .frame(width: Self.actionHeight, height: Self.actionHeight)
                .contentShape(Rectangle())
        }
        // Drawn as given, like the menu beside it; a borderless menu adds
        // insets of its own and sat higher than the buttons around it.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .clickable()
        .relayTooltip(relayLocalized("More"))
    }

    private func saveSummary() {
        guard let draft = editingSummary?.trimmingCharacters(in: .whitespacesAndNewlines), !draft.isEmpty else { return }
        guard draft != issue?.summary else {
            editingSummary = nil
            return
        }
        Task {
            if await tracker.update(key, with: IssueChange(summary: draft)) { editingSummary = nil }
        }
    }

    // MARK: - Description

    @ViewBuilder
    private func descriptionSection(_ issue: TrackerIssue) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            HStack {
                sectionTitle(relayLocalized("Description"))
                Spacer()
                if editingDescription == nil {
                    RelayButton(relayLocalized("Edit"), kind: .ghost) { editingDescription = issue.description }
                }
            }
            if let draft = editingDescription {
                RichMarkdownEditor(
                    placeholder: relayLocalized("Write a description, or paste one here"),
                    markdown: Binding(get: { draft }, set: { editingDescription = $0 }),
                    minHeight: 260
                )
                HStack {
                    Spacer()
                    RelayButton(relayLocalized("Cancel"), kind: .ghost) { editingDescription = nil }
                    RelayButton(relayLocalized("Save"), kind: .primary) { saveDescription(issue) }
                        .disabled(tracker.writesInFlight.contains(.edit(key)))
                }
            } else if issue.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(relayLocalized("No description"))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
            } else {
                IssueText(source: issue.description, issue: issue)
            }
        }
    }

    private func saveDescription(_ issue: TrackerIssue) {
        guard let draft = editingDescription else { return }
        guard draft != issue.description else {
            editingDescription = nil
            return
        }
        Task {
            if await tracker.update(key, with: IssueChange(description: draft)) { editingDescription = nil }
        }
    }

    // MARK: - Comments

    /// What the list of people to mention is made from, to be made again
    /// when it changes.
    private var peopleSignature: [String] {
        (issue?.people(with: tracker.comments[key] ?? []) ?? []).map(\.login)
    }

    private func commentsSection(_ issue: TrackerIssue) -> some View {
        let comments = tracker.comments[key] ?? []
        return VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            sectionTitle(comments.isEmpty
                ? relayLocalized("Comments")
                : String(format: relayLocalized("Comments: %d"), comments.count))
            ForEach(comments) { comment in
                CommentRow(comment: comment, issue: issue, people: mentions.people)
            }
            VStack(alignment: .trailing, spacing: Theme.Spacing.small) {
                MentionTextEditor(
                    placeholder: relayLocalized("Write a comment — @ to mention someone"),
                    text: $reply,
                    state: mentions
                )
                RelayButton(
                    relayLocalized(tracker.writesInFlight.contains(.comment(key)) ? "Sending…" : "Comment"),
                    kind: .primary
                ) {
                    let text = reply
                    Task { if await tracker.addComment(text, on: key) { reply = "" } }
                }
                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || tracker.writesInFlight.contains(.comment(key)))
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title.uppercased())
            .font(Theme.Typography.sectionHeader)
            .tracking(0.7)
            .foregroundStyle(Theme.Palette.textTertiary)
    }
}

/// One comment, which its author can correct in place or take off.
///
/// Offered on your own comments only: editing somebody else's words is a
/// permission trackers keep for administrators, and a pencil on every comment
/// that answers "not allowed" on most of them is a pencil nobody trusts.
private struct CommentRow: View {
    @Environment(AppModel.self) private var model
    let comment: TrackerComment
    let issue: TrackerIssue
    let people: [TrackerUser]

    @State private var isHovering = false
    @State private var draft: String?
    @State private var mentions = MentionState()
    @State private var isConfirmingDeletion = false

    private var tracker: TrackerController { model.tracker }
    private var isMine: Bool { comment.author?.login != nil && comment.author?.login == tracker.user?.login }
    private var isSaving: Bool { tracker.writesInFlight.contains(.changeComment(comment.id)) }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            TrackerAvatar(name: comment.author?.name ?? "?", avatar: comment.author?.avatar, size: 24)
            VStack(alignment: .leading, spacing: Theme.Spacing.xsmall + 2) {
                HStack(spacing: Theme.Spacing.xsmall) {
                    Text(verbatim: comment.author?.name ?? relayLocalized("Someone"))
                        .font(Theme.Typography.row)
                        .foregroundStyle(Theme.Palette.textPrimary)
                    Text(verbatim: relayRelativeTime(comment.created, relativeTo: Date()))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                    Spacer(minLength: 0)
                    if isMine, draft == nil {
                        HoverReveal(isVisible: isHovering || isSaving) {
                            HStack(spacing: 2) {
                                IconButton(systemImage: "pencil", size: 20) { draft = comment.text }
                                    .relayTooltip(relayLocalized("Edit the comment"))
                                IconButton(systemImage: "trash", size: 20, isBusy: isSaving) {
                                    isConfirmingDeletion = true
                                }
                                .relayTooltip(relayLocalized("Delete the comment"))
                            }
                        }
                    }
                }
                if let draft {
                    VStack(alignment: .trailing, spacing: Theme.Spacing.small) {
                        MentionTextEditor(
                            placeholder: relayLocalized("Write a comment — @ to mention someone"),
                            text: Binding(get: { draft }, set: { self.draft = $0 }),
                            state: mentions
                        )
                        HStack(spacing: Theme.Spacing.small) {
                            RelayButton(relayLocalized("Cancel"), kind: .ghost) { self.draft = nil }
                            RelayButton(relayLocalized(isSaving ? "Saving…" : "Save"), kind: .primary) { save(draft) }
                                .disabled(isSaving || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                } else {
                    IssueText(source: comment.text, issue: issue)
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onChange(of: people, initial: true) { mentions.people = people }
        .confirmationDialog(relayLocalized("Delete this comment?"), isPresented: $isConfirmingDeletion) {
            Button(relayLocalized("Delete"), role: .destructive) {
                Task { _ = await tracker.deleteComment(comment, on: issue.key) }
            }
            Button(relayLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(relayLocalized("It is marked deleted, and can be restored in the tracker."))
        }
    }

    private func save(_ text: String) {
        Task {
            if await tracker.updateComment(comment, text: text, on: issue.key) { draft = nil }
        }
    }
}

// MARK: - Fields

private struct IssueFieldsSection: View {
    @Environment(AppModel.self) private var model
    let issue: TrackerIssue

    private var tracker: TrackerController { model.tracker }

    /// Every field with something to say, and every one that could be given
    /// something: an empty field that cannot be set here is only noise.
    private var fields: [TrackerField] {
        issue.fields.filter { !$0.isEmpty || $0.isEditable }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            ForEach(fields) { field in
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                    // Two lines rather than cut short: a field made in
                    // Russian is called "Затраченное время", not "Затр…".
                    Text(verbatim: field.title)
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 104, alignment: .leading)
                    value(of: field)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !issue.tags.isEmpty {
                HStack(spacing: Theme.Spacing.xsmall) {
                    ForEach(issue.tags, id: \.name) { tag in
                        TrackerChip(text: tag.name, systemImage: "tag", color: tag.color)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func value(of field: TrackerField) -> some View {
        if field.isEditable && !field.allowsSeveral {
            Menu {
                if field.canBeEmpty {
                    Button(field.emptyText ?? relayLocalized("None")) { set(field, to: nil) }
                    Divider()
                }
                ForEach(field.options) { option in
                    Button {
                        set(field, to: option)
                    } label: {
                        if field.values.first?.name == option.name {
                            Label(option.title, systemImage: "checkmark")
                        } else {
                            Text(verbatim: option.title)
                        }
                    }
                }
            } label: {
                valueLabel(field, isEditable: true)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .clickable()
            .disabled(tracker.writesInFlight.contains(.edit(issue.key)))
        } else {
            valueLabel(field, isEditable: false)
        }
    }

    private func valueLabel(_ field: TrackerField, isEditable: Bool) -> some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            if field.kind == .user, !field.allowsSeveral, let person = field.values.first {
                TrackerAvatar(name: person.title, avatar: person.avatar, size: 16)
            }
            // Drawn as the tracker draws it when it gives the values colours,
            // so a priority is recognised here by the colour it has there.
            if field.kind == .option, field.values.contains(where: { $0.color != nil }) {
                ForEach(field.values) { option in
                    TrackerChip(text: option.title, color: option.color)
                        .lineLimit(1)
                }
            } else {
                Text(verbatim: shown(field))
                    .font(Theme.Typography.row)
                    .foregroundStyle(field.isEmpty ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                    .lineLimit(2)
            }
            if isEditable {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private func shown(_ field: TrackerField) -> String {
        switch field.kind {
        case .option, .user:
            let titles = field.values.map(\.title)
            return titles.isEmpty ? (field.emptyText ?? "—") : titles.joined(separator: ", ")
        case .date:
            return field.date.map(TrackerText.day) ?? "—"
        case .period, .text, .other:
            return field.text ?? "—"
        }
    }

    private func set(_ field: TrackerField, to option: FieldOption?) {
        guard field.values.first?.name != option?.name else { return }
        let change = IssueChange(fields: [FieldChange(field: field, values: option.map { [$0] } ?? [])])
        Task { _ = await tracker.update(issue.key, with: change) }
    }
}

// MARK: - Time

/// The time on the issue: what everyone and what you recorded, the timer
/// when it is on this issue, and the record day by day — one line per entry,
/// with the whole of it on hover, so a long type or remark does not turn a
/// list into a wall.
private struct IssueTimeSection: View {
    @Environment(AppModel.self) private var model
    let issue: TrackerIssue

    @State private var onlyMine = false

    private var tracker: TrackerController { model.tracker }
    private var items: [TrackerWorkItem] { tracker.workItems[issue.key] ?? [] }
    private var mine: [TrackerWorkItem] { WorkLog.items(items, by: tracker.user?.login) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
            Text(relayLocalized("Time").uppercased())
                .font(Theme.Typography.sectionHeader)
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.textTertiary)

            HStack(spacing: Theme.Spacing.small) {
                total(relayLocalized("Everyone"), minutes: WorkLog.minutes(in: items), isSelected: !onlyMine) {
                    onlyMine = false
                }
                total(relayLocalized("You"), minutes: WorkLog.minutes(in: mine), isSelected: onlyMine) {
                    onlyMine = true
                }
            }

            if let timer = tracker.timer, timer.key == issue.key {
                timerRow(timer)
            }

            RelayButton(relayLocalized("Log Time…"), systemImage: "plus") { model.beginLoggingWork(on: issue.key) }

            let shown = onlyMine ? mine : items
            if shown.isEmpty {
                Text(relayLocalized(onlyMine ? "You have logged no time here" : "No time logged yet"))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    ForEach(WorkLog.days(of: shown, in: .current)) { day in
                        daySection(day)
                    }
                }
            }
        }
    }

    /// A figure that is also the filter: clicking "You" lists your time.
    private func total(_ title: String, minutes: Int, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(Theme.Typography.sectionHeader)
                    .tracking(0.5)
                    .foregroundStyle(isSelected ? Theme.Palette.textSecondary : Theme.Palette.textTertiary)
                    .lineLimit(1)
                Text(verbatim: minutes == 0 ? "—" : TrackerText.duration(minutes: minutes))
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.textPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, Theme.Spacing.small + 2)
            .padding(.vertical, Theme.Spacing.small - 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Theme.Palette.accentMuted : Theme.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(isSelected ? Theme.Palette.accent.opacity(0.6) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
    }

    private func timerRow(_ timer: TrackerTimer) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: Theme.Spacing.small) {
                Image(systemName: timer.isRunning ? "timer" : "pause.circle")
                    .foregroundStyle(Theme.Palette.statusWorking)
                Text(verbatim: TrackerText.clock(timer.elapsed(at: context.date)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Palette.textPrimary)
                Spacer()
                if timer.isRunning {
                    IconButton(systemImage: "pause.fill", size: Theme.Metrics.action) { tracker.pauseTimer() }
                        .relayTooltip(relayLocalized("Pause"))
                } else {
                    IconButton(systemImage: "play.fill", size: Theme.Metrics.action) { tracker.resumeTimer() }
                        .relayTooltip(relayLocalized("Resume"))
                }
                IconButton(systemImage: "checkmark", size: Theme.Metrics.action) { model.stopTimer() }
                    .relayTooltip(relayLocalized("Stop and log"))
            }
        }
        .padding(Theme.Spacing.small)
        .background(Theme.Palette.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
    }

    private func daySection(_ day: WorkLog.Day) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack {
                Text(verbatim: TrackerText.day(day.start))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
                Spacer()
                Text(verbatim: TrackerText.duration(minutes: day.minutes))
                    .font(Theme.Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            ForEach(day.items) { item in
                WorkItemRow(item: item, key: issue.key, isMine: item.author?.login == tracker.user?.login)
            }
        }
    }
}

/// One entry of time. Your own can be corrected — a click on it, or its
/// menu — and taken off, the way your own comments can.
private struct WorkItemRow: View {
    @Environment(AppModel.self) private var model
    let item: TrackerWorkItem
    let key: String
    let isMine: Bool

    @State private var isHovering = false
    @State private var isConfirmingDeletion = false

    /// Everything the row cuts short, for the tooltip.
    private var whole: String {
        [item.author?.name, item.type?.name, item.text.isEmpty ? nil : item.text]
            .compactMap { $0 }
            .joined(separator: "\n")
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.small) {
            TrackerAvatar(name: item.author?.name ?? "?", avatar: item.author?.avatar, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xsmall) {
                    Text(verbatim: item.author?.name ?? relayLocalized("Someone"))
                        .font(Theme.Typography.row)
                        .foregroundStyle(isMine ? Theme.Palette.textPrimary : Theme.Palette.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: Theme.Spacing.xsmall)
                    if isMine, isHovering {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.Palette.textTertiary)
                    }
                    Text(verbatim: TrackerText.duration(minutes: item.minutes))
                        .font(Theme.Typography.row)
                        .monospacedDigit()
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .lineLimit(1)
                        .fixedSize()
                }
                let detail = [item.type?.name, item.text.isEmpty ? nil : item.text].compactMap { $0 }
                if !detail.isEmpty {
                    Text(verbatim: detail.joined(separator: " · "))
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xsmall)
        .padding(.horizontal, Theme.Spacing.xsmall)
        .background(isMine && isHovering ? Theme.Palette.surfaceHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
        .padding(.horizontal, -Theme.Spacing.xsmall)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { if isMine { edit() } }
        .clickable(isMine)
        .relayTooltip(whole)
        .contextMenu {
            if isMine {
                Button(relayLocalized("Edit…")) { edit() }
                Button(relayLocalized("Delete…")) { isConfirmingDeletion = true }
            }
        }
        .confirmationDialog(relayLocalized("Delete this time?"), isPresented: $isConfirmingDeletion) {
            Button(relayLocalized("Delete"), role: .destructive) {
                Task { _ = await model.tracker.deleteWork(item, on: key) }
            }
            Button(relayLocalized("Cancel"), role: .cancel) {}
        } message: {
            Text(verbatim: String(
                format: relayLocalized("%@ logged on %@ is taken off %@."),
                TrackerText.duration(minutes: item.minutes),
                TrackerText.day(item.date),
                key
            ))
        }
    }

    private func edit() {
        model.presentModal(.editWork(key: key, itemID: item.id))
    }
}
