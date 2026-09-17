import RelayUI
import SwiftUI
import UniformTypeIdentifiers

/// Creates or edits one `Host` block in the user's OpenSSH configuration.
///
/// The form covers what a connection usually needs and hands everything else to
/// a free-text field, because a config carries directives Relay has never heard
/// of and a form that cannot show them is a form that deletes them.
struct SSHHostEditorView: View {
    @Environment(AppModel.self) private var model

    /// Nil for a host that does not exist yet.
    let host: SSHHost?

    @State private var draft = SSHHostDraft()
    @State private var problem: SSHHostDraftProblem?
    @State private var isChoosingIdentity = false
    /// The key this host would authenticate with, and its fingerprint, so the
    /// panel can say whether connecting will stop to ask for a passphrase.
    @State private var keyPath: String?
    @State private var keyFingerprint: String?

    private var isEditing: Bool { host != nil }

    var body: some View {
        ModalSurface(
            relayLocalized(isEditing ? "Edit Host" : "New Host"),
            onDismiss: { model.dismissModal() }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                    fields
                    extras
                    notes
                }
                .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
                .padding(.vertical, ModalSurface<EmptyView, EmptyView>.verticalInset)
            }
        } footer: {
            footer
        }
        .onAppear { draft = host.map(SSHHostDraft.init(editing:)) ?? SSHHostDraft() }
        .task(id: identityFile ?? "") {
            let path = SSHAgent.keyPath(forIdentityFile: identityFile)
            keyPath = path
            keyFingerprint = await Task.detached(priority: .utility) {
                path.flatMap(SSHAgent.fingerprint(ofKeyAt:))
            }.value
        }
        .task {
            // The key is unlocked in another session, so the answer arrives
            // while this panel is open rather than before it.
            while !Task.isCancelled {
                model.refreshSSHAgent()
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .fileImporter(
            isPresented: $isChoosingIdentity,
            allowedContentTypes: [.item]
        ) { result in
            if case let .success(url) = result { draft.identityFile = HomeRelativePath.abbreviating(url) }
        }
    }

    // MARK: - Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.large) {
            field(relayLocalized("Alias")) {
                VStack(alignment: .leading, spacing: 4) {
                    RelayTextField("staging", text: $draft.alias, onSubmit: save)
                    Text(verbatim: "ssh \(draft.alias.trimmingCharacters(in: .whitespaces))")
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }
            }

            field(relayLocalized("Host name")) {
                RelayTextField(
                    placeholder("staging.example.com", inherited: host?.hostName),
                    text: $draft.hostName,
                    onSubmit: save
                )
            }

            HStack(alignment: .top, spacing: Theme.Spacing.medium) {
                field(relayLocalized("User")) {
                    RelayTextField(
                        placeholder("deploy", inherited: host?.user),
                        text: $draft.user,
                        onSubmit: save
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                field(relayLocalized("Port")) {
                    RelayTextField(
                        placeholder("22", inherited: host?.port.map(String.init)),
                        text: $draft.port,
                        onSubmit: save
                    )
                }
                .frame(width: 96)
            }

            field(relayLocalized("Identity file")) {
                HStack(spacing: Theme.Spacing.small) {
                    RelayTextField(
                        placeholder("~/.ssh/id_ed25519", inherited: host?.identityFile),
                        text: $draft.identityFile,
                        onSubmit: save
                    )
                    RelayButton(relayLocalized("Choose…"), kind: .secondary) { isChoosingIdentity = true }
                }
            }

            agent

            field(relayLocalized("Proxy jump")) {
                VStack(alignment: .leading, spacing: 4) {
                    RelayTextField(
                        placeholder("bastion", inherited: host?.proxyJump),
                        text: $draft.proxyJump,
                        onSubmit: save
                    )
                    Text(relayLocalized("The host to connect through first."))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textTertiary)
                }
            }

            field(relayLocalized("Forward agent")) {
                ChipPicker(items: SSHFlagValue.allCases, selection: $draft.forwardAgent) { value, _ in
                    Text(flagLabel(value))
                        .font(Theme.Typography.rowSecondary)
                        .foregroundStyle(Theme.Palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    // MARK: - The agent

    /// Whether the passphrase will be asked for, and the one thing that stops
    /// it being asked for again.
    ///
    /// The prompt people actually meet is not the server's password but their
    /// own key's passphrase, and the fix for it is not a field in Relay: it is
    /// the agent macOS already runs and the keychain it already has.
    @ViewBuilder
    private var agent: some View {
        let status = SSHAgent.status(ofKey: keyFingerprint, in: model.sshAgentKeys)
        if status != .unknown, let keyPath {
            field(relayLocalized("Key")) {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                        Circle()
                            .fill(status == .loaded ? Theme.Palette.statusFinished : Theme.Palette.statusWaiting)
                            .frame(width: 7, height: 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(message(for: status))
                                .font(Theme.Typography.rowSecondary)
                                .foregroundStyle(Theme.Palette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(verbatim: HomeRelativePath.abbreviating(keyPath))
                                .font(Theme.Typography.mono)
                                .foregroundStyle(Theme.Palette.textTertiary)
                                .lineLimit(1)
                        }
                    }

                    if status == .notLoaded {
                        RelayButton(
                            relayLocalized("Unlock once"),
                            systemImage: "key",
                            kind: .secondary
                        ) { model.presentModal(.sshKeyUnlock(keyPath: keyPath)) }
                    }

                    if status != .loaded, !model.sshUsesKeychain {
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
                            Text(relayLocalized(
                                "After a restart the agent is empty again. AddKeysToAgent and UseKeychain in Host * let macOS answer for the key."
                            ))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Palette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            RelayButton(relayLocalized("Add to Host *"), kind: .ghost) {
                                model.enableSSHKeychain()
                            }
                        }
                    }
                }
            }
        }
    }

    private func message(for status: SSHAgentStatus) -> String {
        switch status {
        case .loaded: relayLocalized("In the agent — no passphrase will be asked for.")
        case .notLoaded: relayLocalized("Not in the agent — the passphrase is asked for on every connection.")
        case .noAgent: relayLocalized("No ssh-agent is running, so every connection asks for the passphrase.")
        case .unknown: ""
        }
    }

    /// What the host would authenticate with: what the form says, or what it
    /// inherits when the form says nothing.
    private var identityFile: String? {
        let own = draft.identityFile.trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? host?.identityFile : own
    }

    private var extras: some View {
        field(relayLocalized("Other directives")) {
            VStack(alignment: .leading, spacing: 4) {
                RelayTextEditor("ServerAliveInterval 60", text: $draft.extraDirectives, minHeight: 84)
                Text(relayLocalized("One per line, written into the block as they are."))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.textTertiary)
            }
        }
    }

    /// What the user needs to know before pressing Save, and nothing that is
    /// merely true.
    @ViewBuilder
    private var notes: some View {
        if let definition = host?.definitions.first, definition.patterns.count > 1 {
            note(
                relayLocalized("This block also names: %@"),
                definition.patterns.filter { $0 != host?.alias }.joined(separator: ", ")
            )
        }
        if let host, host.definitions.count > 1 {
            note(
                relayLocalized("%@ is declared in more than one block; this edits the first."),
                host.alias
            )
        }
        if let file = host?.definitions.first?.file, file != SSHConfigStore.rootConfig {
            note(relayLocalized("Saved to %@"), HomeRelativePath.abbreviating(file))
        }
    }

    private func note(_ format: String, _ argument: String) -> some View {
        Text(verbatim: String(format: format, argument))
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Palette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.medium) {
            if let problem {
                Text(message(for: problem))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Palette.statusError)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.small)
            RelayButton(relayLocalized("Cancel"), kind: .ghost) { model.dismissModal() }
            RelayButton(relayLocalized(isEditing ? "Save" : "Add"), kind: .primary) { save() }
        }
    }

    // MARK: - Saving

    private func save() {
        let found = SSHConfigWriter.problem(with: draft, takenAliases: model.sshAliases(excluding: host))
        problem = found
        guard found == nil else { return }
        model.saveSSHHost(draft, replacing: host)
    }

    private func message(for problem: SSHHostDraftProblem) -> String {
        switch problem {
        case .emptyAlias: relayLocalized("A host needs a name to be connected by.")
        case .aliasHasWhitespace: relayLocalized("An alias cannot contain spaces.")
        case .aliasIsPattern: relayLocalized("An alias cannot be a pattern: ssh would match it against others.")
        case .aliasTaken: relayLocalized("That alias is already in the config.")
        case .invalidPort: relayLocalized("A port is a number between 1 and 65535.")
        case let .notADirective(line): String(format: relayLocalized("Not a directive: %@"), line)
        }
    }

    // MARK: - Pieces

    /// Shows what the host would use anyway, so an empty field reads as
    /// inherited rather than as unset.
    private func placeholder(_ example: String, inherited: String?) -> String {
        guard isEditing, let inherited, !inherited.isEmpty else { return example }
        return inherited
    }

    private func flagLabel(_ value: SSHFlagValue) -> String {
        switch value {
        case .unset: relayLocalized("Leave unset")
        case .yes: relayLocalized("Yes")
        case .no: relayLocalized("No")
        }
    }

    /// Takes a phrase already looked up rather than looking one up itself: a
    /// label handed over as a bare key is invisible to the test that checks
    /// every phrase has a translation, and shows English to a Russian window.
    private func field(_ label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.small) {
            Text(label.uppercased())
                .font(Theme.Typography.sectionHeader)
                .tracking(0.7)
                .foregroundStyle(Theme.Palette.textTertiary)
            content()
        }
    }
}
