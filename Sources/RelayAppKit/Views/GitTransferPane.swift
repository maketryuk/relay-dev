import RelayProtocol
import RelayUI
import SwiftUI

/// Where a pull or a push is going, asked before it goes.
///
/// The command line is on screen because it is the whole point: a pull that
/// rebases and a pull that merges are different requests, and so are a push to
/// the branch's upstream and a push to somewhere else. What runs is derived
/// from what is shown, so the two cannot drift apart.
struct GitTransferPane: View {
    @Environment(AppModel.self) private var model
    let project: Project
    let direction: GitTransfer.Direction

    @State private var transfer: GitTransfer?

    private var status: GitStatus? { model.gitStatuses[project.id] }
    private var isRunning: Bool { model.runningTransfer != nil }

    /// Branch names on the chosen remote, without the remote's own prefix —
    /// `origin/main` is offered as `main`, because that is what the command
    /// takes.
    private func branchNames(on remote: String) -> [String] {
        let prefix = remote + "/"
        let remoteBranches = model.branches(in: project.id)
            .filter { $0.isRemote && $0.name.hasPrefix(prefix) }
            .map { String($0.name.dropFirst(prefix.count)) }
        let local = status?.branch ?? ""
        // The branch you are on belongs in the list even when the remote has
        // never heard of it: that is the push that creates it.
        let extras = local.isEmpty || remoteBranches.contains(local) ? [] : [local]
        return (extras + remoteBranches.sorted()).uniqued()
    }

    var body: some View {
        ModalSurface(title, onDismiss: { model.dismissModal() }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                if let transfer {
                    command(transfer)
                    options(transfer)
                    if direction == .push { outgoing(transfer) }
                    Spacer(minLength: 0)
                } else if status == nil {
                    EmptyStateView(
                        systemImage: "arrow.triangle.branch",
                        title: relayLocalized("Not a repository"),
                        message: relayLocalized("There is no git repository in this project.")
                    )
                } else {
                    // The remotes are read as the panel appears, and what they
                    // are decides every default in it.
                    EmptyStateView(
                        systemImage: "arrow.triangle.branch",
                        title: relayLocalized("Reading…"),
                        message: ""
                    )
                }
            }
            .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
            .padding(.vertical, ModalSurface<EmptyView, EmptyView>.verticalInset)
        } footer: {
            footer
        }
        .onAppear(perform: start)
        // The remotes arrive after the panel does, and the first one of them is
        // what an unset transfer is waiting for.
        .onChange(of: model.remotes(in: project.id)) { _, _ in start() }
        .onChange(of: transfer?.remoteRef ?? "") { _, ref in
            guard direction == .push, !ref.isEmpty else { return }
            model.loadOutgoingCommits(in: project.id, against: ref)
        }
    }

    private var title: String {
        let branch = status?.branch ?? project.name
        return direction == .pull
            ? String(format: relayLocalized("Pull into %@"), branch)
            : String(format: relayLocalized("Push %@"), branch)
    }

    private func start() {
        // Waits for the remotes rather than guessing at them: every default in
        // the panel is derived from which ones there are. Once it is set up it
        // is left alone, since re-deriving under the person as a branch list
        // arrives would undo what they just chose.
        guard status != nil, transfer == nil, model.hasReadRemotes(project.id) else { return }
        let initial = GitTransfer.initial(
            direction: direction,
            status: status,
            remotes: model.remotes(in: project.id)
        )
        transfer = initial
        if direction == .push, !initial.remote.isEmpty {
            model.loadOutgoingCommits(in: project.id, against: initial.remoteRef)
        }
    }

    // MARK: - The command

    /// One control, in three parts, reading as the command it is: the verb,
    /// the remote, the branch. Three separate boxes floating on a row read as
    /// three unrelated settings, which is what they were and what they are not.
    private func command(_ transfer: GitTransfer) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            HStack(spacing: 0) {
                Text(verbatim: direction == .pull ? "git pull" : "git push")
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .padding(.horizontal, Theme.Spacing.small + 2)
                    .frame(height: Self.fieldHeight)
                    .background(Theme.Palette.surface)

                RelayDivider(axis: .vertical)

                FieldPicker(
                    value: transfer.remote,
                    placeholder: relayLocalized("No remote"),
                    options: model.remotes(in: project.id)
                ) { remote in
                    self.transfer?.remote = remote
                    // A branch that existed on the old remote need not exist on
                    // this one; the branch you are on always does as a target.
                    if !branchNames(on: remote).contains(transfer.branch) {
                        self.transfer?.branch = status?.branch ?? transfer.branch
                    }
                }
                .frame(width: 150)

                RelayDivider(axis: .vertical)

                FieldPicker(
                    value: transfer.branch,
                    placeholder: relayLocalized("No branch"),
                    options: branchNames(on: transfer.remote)
                ) { branch in
                    self.transfer?.branch = branch
                }
                .frame(maxWidth: .infinity)
            }
            .frame(height: Self.fieldHeight)
            .background(Theme.Palette.surfaceRaised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .strokeBorder(Theme.Palette.border, lineWidth: 1)
            )

            HStack(spacing: Theme.Spacing.small) {
                Text(verbatim: transfer.commandLine)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                if direction == .push, transfer.localBranch != transfer.branch {
                    Text(verbatim: "\(transfer.localBranch) → \(transfer.remote)/\(transfer.branch)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.statusWaiting)
                }
            }
        }
    }

    static let fieldHeight: CGFloat = 30

    // MARK: - Options

    private func options(_ transfer: GitTransfer) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(relayLocalized("Options"))
                .padding(.bottom, Theme.Spacing.xsmall)

            ForEach(GitTransfer.Option.all(for: direction)) { option in
                let isAvailable = transfer.isAvailable(option)
                RelayCheckbox(isOn: transfer.options.contains(option)) {
                    self.transfer?.set(option, !transfer.options.contains(option))
                } label: {
                    // The wording first and the flag second, the way the flag
                    // lists in every git interface read: what it does is the
                    // question, and the flag is the answer's name.
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        Text(explanation(option))
                            .font(Theme.Typography.row)
                            .foregroundStyle(Theme.Palette.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: Theme.Spacing.small)
                        Text(verbatim: option.flag)
                            .font(Theme.Typography.mono)
                            .foregroundStyle(
                                option.isDestructive ? Theme.Palette.statusError : Theme.Palette.textTertiary
                            )
                    }
                }
                .disabled(!isAvailable)
                .opacity(isAvailable ? 1 : 0.35)
                .padding(.vertical, 3)
            }
        }
    }

    private func explanation(_ option: GitTransfer.Option) -> String {
        switch option {
        case .rebase:
            relayLocalized("Rebase the current branch on top of incoming changes")
        case .fastForwardOnly:
            relayLocalized("Merge only if it can be fast-forwarded")
        case .noFastForward:
            relayLocalized("Create a merge commit even if it can be fast-forwarded")
        case .squash:
            relayLocalized("Create a single commit for all pulled changes")
        case .noCommit:
            relayLocalized("Merge, but do not commit the result")
        case .autostash:
            relayLocalized("Set uncommitted changes aside for the pull and put them back after")
        case .forceWithLease:
            relayLocalized("Overwrite the remote branch, refusing if it moved since you last fetched")
        case .tags:
            relayLocalized("Send tags along with the commits")
        case .setUpstream:
            relayLocalized("Make this branch follow the one it is pushed to")
        case .noVerify:
            direction == .pull
                ? relayLocalized("Bypass the pre-merge and commit message hooks")
                : relayLocalized("Bypass the pre-push hook")
        }
    }

    // MARK: - What is going out

    @ViewBuilder
    private func outgoing(_ transfer: GitTransfer) -> some View {
        let commits = model.outgoingCommits(in: project.id, against: transfer.remoteRef)
        let isNew = model.remoteBranchIsNew(in: project.id, ref: transfer.remoteRef)

        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            SectionHeader(outgoingTitle(commits: commits, isNew: isNew))

            if isNew {
                Text(String(
                    format: relayLocalized("%@ has no branch called %@ yet; pushing creates it."),
                    transfer.remote,
                    transfer.branch
                ))
                .font(Theme.Typography.rowSecondary)
                .foregroundStyle(Theme.Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            } else if let commits, commits.isEmpty {
                Text(relayLocalized("Nothing to push — the remote branch is already here."))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textSecondary)
            } else if let commits {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(commits) { commit in
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                                Text(verbatim: commit.sha)
                                    .font(Theme.Typography.mono)
                                    .foregroundStyle(Theme.Palette.textTertiary)
                                Text(verbatim: commit.subject)
                                    .font(Theme.Typography.rowSecondary)
                                    .foregroundStyle(Theme.Palette.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            } else {
                Text(relayLocalized("Reading…"))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    private func outgoingTitle(commits: [GitCommitSummary]?, isNew: Bool) -> String {
        guard !isNew, let commits, !commits.isEmpty else { return relayLocalized("Commits") }
        return String(format: relayLocalized("%d commits to push"), commits.count)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: Theme.Spacing.small) {
            if let status, direction == .pull, status.behind > 0 {
                Text(String(format: relayLocalized("%d behind"), status.behind))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.textTertiary)
                    .monospacedDigit()
            }
            if let status, status.isDirty, direction == .pull {
                Text(relayLocalized("The working copy has changes"))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.statusWaiting)
            }
            if transfer?.isDetached == true {
                Text(relayLocalized("You are not on a branch"))
                    .font(Theme.Typography.rowSecondary)
                    .foregroundStyle(Theme.Palette.statusWaiting)
            }

            Spacer(minLength: Theme.Spacing.small)

            RelayButton(relayLocalized("Cancel")) { model.dismissModal() }
            RelayButton(
                actionTitle,
                kind: isForcing ? .destructive : .primary
            ) { run() }
                .disabled(!canRun)
                .opacity(canRun ? 1 : 0.5)
        }
    }

    private var isForcing: Bool {
        transfer?.options.contains(.forceWithLease) ?? false
    }

    /// Says what the button will do rather than what it is called: a force
    /// push is worth reading on the button that performs it.
    private var actionTitle: String {
        if isRunning { return relayLocalized("Running…") }
        if direction == .pull { return relayLocalized("Pull") }
        return isForcing ? relayLocalized("Force push") : relayLocalized("Push")
    }

    private var canRun: Bool {
        guard !isRunning, let transfer else { return false }
        return transfer.isRunnable
    }

    private func run() {
        guard canRun, let transfer else { return }
        model.run(transfer, in: project.id)
    }
}

/// One segment of the command row: what is chosen, and a list to choose from.
///
/// Not a `Menu`: AppKit draws its own indicator wherever it likes and ignores
/// the plate the label is wearing, which is how the row ended up as bare text
/// with a chevron leaning on it. A button and a popover are a control this app
/// can actually shape.
private struct FieldPicker: View {
    let value: String
    let placeholder: String
    let options: [String]
    let onPick: (String) -> Void

    @State private var isOpen = false
    @State private var isHovering = false

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: Theme.Spacing.xsmall) {
                Text(verbatim: value.isEmpty ? placeholder : value)
                    .font(Theme.Typography.row)
                    .foregroundStyle(value.isEmpty ? Theme.Palette.textTertiary : Theme.Palette.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
            .padding(.horizontal, Theme.Spacing.small + 2)
            .frame(height: GitTransferPane.fieldHeight)
            .background(isHovering ? Theme.Palette.surfaceHover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .onHover { isHovering = $0 }
        .disabled(options.isEmpty)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { list }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 1) {
                ForEach(options, id: \.self) { option in
                    Button {
                        onPick(option)
                        isOpen = false
                    } label: {
                        HStack(spacing: Theme.Spacing.small) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.Palette.accent)
                                .opacity(option == value ? 1 : 0)
                                .frame(width: 10)
                            Text(verbatim: option)
                                .font(Theme.Typography.row)
                                .foregroundStyle(Theme.Palette.textPrimary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Theme.Spacing.small)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .clickable()
                }
            }
            .padding(Theme.Spacing.xsmall)
        }
        .frame(width: 260)
        .frame(maxHeight: 280)
        .background(Theme.Palette.surface)
    }
}

private extension [String] {
    /// Keeps the first of each, since the order here is meaningful: the branch
    /// you are on comes before the rest.
    func uniqued() -> [String] {
        var seen = Set<String>()
        return filter { seen.insert($0).inserted }
    }
}
