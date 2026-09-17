import RelayUI
import SwiftUI

/// Asks for a key's passphrase once.
///
/// Once, and then never again: it goes straight to `ssh-add`, which puts it in
/// the login keychain, and from then on `ssh` reads it back itself. Relay keeps
/// nothing — the field below is emptied as soon as the key is unlocked, and
/// there is nowhere for it to have been written in between.
struct SSHKeyUnlockView: View {
    @Environment(AppModel.self) private var model

    let keyPath: String

    @State private var passphrase = ""
    @State private var failure: String?
    @State private var isWorking = false
    @FocusState private var isFocused: Bool

    var body: some View {
        ModalSurface(relayLocalized("Unlock Key"), onDismiss: { model.dismissModal() }) {
            VStack(alignment: .leading, spacing: Theme.Spacing.large) {
                VStack(alignment: .leading, spacing: Theme.Spacing.small) {
                    Text(relayLocalized("Passphrase").uppercased())
                        .font(Theme.Typography.sectionHeader)
                        .tracking(0.7)
                        .foregroundStyle(Theme.Palette.textTertiary)

                    SecureField("", text: $passphrase)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.row)
                        .foregroundStyle(Theme.Palette.textPrimary)
                        .focused($isFocused)
                        .onSubmit(unlock)
                        .padding(.horizontal, Theme.Spacing.small + 2)
                        .padding(.vertical, 7)
                        .background(Theme.Palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                                .strokeBorder(
                                    isFocused ? Theme.Palette.accent.opacity(0.7) : Theme.Palette.border,
                                    lineWidth: 1
                                )
                        )

                    Text(verbatim: HomeRelativePath.abbreviating(keyPath))
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.Palette.textTertiary)
                        .lineLimit(1)
                }

                Text(relayLocalized(
                    "It is handed to ssh-add and kept by the macOS keychain, which ssh reads itself from then on. Relay stores nothing."
                ))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Palette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)

                if let failure {
                    Text(failure)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.statusError)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, ModalSurface<EmptyView, EmptyView>.horizontalInset)
            .padding(.vertical, ModalSurface<EmptyView, EmptyView>.verticalInset)
        } footer: {
            HStack {
                Spacer()
                RelayButton(relayLocalized("Cancel"), kind: .ghost) { model.dismissModal() }
                RelayButton(
                    relayLocalized(isWorking ? "Unlocking…" : "Unlock"),
                    kind: .primary,
                    action: unlock
                )
            }
        }
        .onAppear { isFocused = true }
    }

    private func unlock() {
        guard !passphrase.isEmpty, !isWorking else { return }
        isWorking = true
        failure = nil
        model.unlockSSHKey(at: keyPath, passphrase: passphrase) { result in
            isWorking = false
            passphrase = ""
            switch result {
            case .added:
                model.dismissModal()
            case .wrongPassphrase:
                failure = relayLocalized("That passphrase does not open this key.")
                isFocused = true
            case let .failed(message):
                failure = message
            }
        }
    }
}
