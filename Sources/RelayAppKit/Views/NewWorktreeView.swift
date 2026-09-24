import RelayProtocol
import RelayUI
import SwiftUI

/// Starts a piece of work in a checkout of its own: a branch, a folder for it,
/// and what should run there first.
///
/// One panel rather than three steps, because the three are one thought — "an
/// agent on a new branch, doing this" — and the point of a worktree is that it
/// costs nothing to have another.
struct NewWorktreeView: View {
    @Environment(AppModel.self) private var model
    let project: Project

    @State private var name = ""
    /// Nil until the branches have been read; git then starts from `HEAD`.
    @State private var base: String?
    @State private var start: Start = .nothing
    @State private var prompt = ""

    private enum Start: Hashable {
        case nothing
        case preset(String)
    }

    private var branch: String { WorktreeNaming.branchName(from: name) }

    private var branches: [GitBranch] { model.branches(in: project.id) }

    /// A name that is already a local branch opens that branch rather than
    /// starting a new one, so there is nothing to start it from.
    private var opensExistingBranch: Bool {
        branches.contains { !$0.isRemote && $0.name == branch }
    }

    /// The first run is cheap to pick and costly to type: presets whose
    /// command would be empty are left out.
    private var presets: [SessionPreset] {
        model.sessionPresets.filter { $0.kind != .custom || !($0.customCommand ?? "").isEmpty }
    }

    private var chosenPreset: SessionPreset? {
        guard case let .preset(id) = start else { return nil }
        return presets.first { $0.id == id }
    }

    var body: some View {
        ModalSurface(relayLocalized("New Worktree"), onDismiss: { model.dismissModal() }) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    field("Branch") {
                        VStack(alignment: .leading, spacing: 4) {
                            RelayTextField("fix-login-redirect", text: $name, autofocus: true, onSubmit: create)
                            Text(verbatim: summary)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if !opensExistingBranch {
                        field("Start from") { basePicker }
                    }

                    field("Then start") {
                        ChipPicker(
                            items: [Start.nothing] + presets.map { Start.preset($0.id) },
                            selection: $start
                        ) { item, _ in
                            startLabel(item)
                        }
                    }

                    if chosenPreset?.kind.isAgent == true {
                        field("First prompt") {
                            VStack(alignment: .leading, spacing: 4) {
                                RelayTextEditor(relayLocalized("What should it do?"), text: $prompt, minHeight: 88)
                                Text(relayLocalized("Handed to the agent once it is ready for it. Optional."))
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Palette.textTertiary)
                            }
                        }
                    }
                }
                .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
                .padding(.vertical, ModalSurface<EmptyView, EmptyView>.verticalInset)
            }
        } footer: {
            HStack(spacing: Theme.Spacing.small) {
                if let failure = model.worktreeCreationFailure {
                    Text(verbatim: failure)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.statusError)
                        .lineLimit(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Spacer()
                }
                RelayButton(relayLocalized("Cancel"), kind: .ghost) { model.dismissModal() }
                RelayButton(
                    relayLocalized(model.isCreatingWorktree ? "Creating…" : "Create"),
                    kind: .primary,
                    action: create
                )
                .disabled(branch.isEmpty || model.isCreatingWorktree)
            }
        }
        .onAppear {
            // The project's usual agent, when there is still a preset for it.
            let preferred = SessionPresets.preferred(for: project.defaultAgent, in: presets)
            start = presets.contains(preferred) ? .preset(preferred.id) : .nothing
            base = base ?? currentBranch
        }
        .onChange(of: branches) {
            base = base ?? currentBranch
        }
    }

    private var currentBranch: String? {
        branches.first(where: \.isCurrent)?.name
    }

    /// Says what will happen before it does: which branch, from where, and the
    /// folder it will be in — the three things a worktree is.
    private var summary: String {
        guard !branch.isEmpty else {
            return relayLocalized("A branch of its own, checked out in a folder of its own.")
        }
        let folder = HomeRelativePath.abbreviating(plannedDirectory)
        if opensExistingBranch {
            return String(format: relayLocalized("Opens the existing branch %@ in %@"), branch, folder)
        }
        return String(
            format: relayLocalized("New branch %@ from %@, in %@"),
            branch,
            base ?? "HEAD",
            folder
        )
    }

    private var plannedDirectory: String {
        let main = model.worktrees[project.id]?.first(where: \.isMain)?.path ?? project.rootPath
        return WorktreeNaming.directory(
            for: branch,
            repository: WorktreeNaming.repositoryName(mainWorktree: main),
            in: RelayPaths.worktreesDirectory
        ) { FileManager.default.fileExists(atPath: $0) }
    }

    private var basePicker: some View {
        Picker("", selection: $base) {
            // Until the branches have been read, the only honest answer.
            if base == nil {
                Text(verbatim: "HEAD").tag(String?.none)
            }
            ForEach(branches.filter { !$0.isRemote }) { branch in
                Text(verbatim: branch.name).tag(Optional(branch.name))
            }
            let remote = branches.filter(\.isRemote)
            if !remote.isEmpty {
                Divider()
                ForEach(remote) { branch in
                    Text(verbatim: branch.name).tag(Optional(branch.name))
                }
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(maxWidth: 280, alignment: .leading)
        .clickable()
    }

    @ViewBuilder
    private func startLabel(_ item: Start) -> some View {
        switch item {
        case .nothing:
            HStack(spacing: Theme.Spacing.xsmall) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.textTertiary)
                Text(relayLocalized("Nothing yet"))
                    .font(Theme.Typography.row)
                    .lineLimit(1)
            }
        case let .preset(id):
            if let preset = presets.first(where: { $0.id == id }) {
                HStack(spacing: Theme.Spacing.xsmall) {
                    SessionGlyph(kind: preset.kind, size: 11, tint: Color(hex: preset.kind.accentHex))
                    Text(verbatim: preset.name)
                        .font(Theme.Typography.row)
                        .lineLimit(1)
                }
            }
        }
    }

    private func create() {
        guard !branch.isEmpty, !model.isCreatingWorktree else { return }
        model.createWorktree(
            named: name,
            from: opensExistingBranch ? nil : base,
            starting: chosenPreset,
            prompt: chosenPreset?.kind.isAgent == true ? prompt : "",
            in: project.id
        )
    }

    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(relayLocalized(label).uppercased())
                .font(Theme.Typography.sectionHeader)
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.textTertiary)
            content()
        }
    }
}
