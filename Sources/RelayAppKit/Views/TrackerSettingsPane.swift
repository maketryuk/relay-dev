import AppKit
import RelayTracker
import RelayUI
import SwiftUI

/// Where the issue tracker is switched on and connected.
///
/// Off by default and entirely absent while off: no board in the rail, no
/// command in the palette, no request anywhere. Switching it on is choosing a
/// tracker, and connecting is an address and a token, checked against the
/// tracker before either is kept.
struct TrackerSettingsPane: View {
    @Environment(AppModel.self) private var model
    @State private var address = ""
    @State private var token = ""
    @State private var failure: TrackerError?
    @State private var isConnecting = false

    private var tracker: TrackerController { model.tracker }

    var body: some View {
        SettingsScroll(title: relayLocalized("Issues")) {
            SettingsGroup(relayLocalized("Tracker")) {
                SettingsRow(
                    title: relayLocalized("Issue tracker"),
                    detail: relayLocalized("Boards, cards and time tracking in Relay, and issues handed to agents")
                ) {
                    Picker("", selection: Binding(
                        get: { tracker.settings.kind },
                        set: { tracker.setKind($0) }
                    )) {
                        Text(relayLocalized("None")).tag(TrackerKind?.none)
                        ForEach(TrackerKind.allCases) { kind in
                            Text(verbatim: kind.displayName).tag(Optional(kind))
                        }
                    }
                    .labelsHidden()
                    .clickable()
                    .frame(width: 160)
                }
            }

            if let kind = tracker.settings.kind {
                connectionGroup(kind)
            }
        }
        .onAppear { address = tracker.settings.address }
    }

    @ViewBuilder
    private func connectionGroup(_ kind: TrackerKind) -> some View {
        SettingsGroup(kind.displayName) {
            SettingsRow(
                title: relayLocalized("Address"),
                detail: relayLocalized("Where you open it in a browser")
            ) {
                RelayTextField("https://example.youtrack.cloud", text: $address, onSubmit: connect)
                    .frame(width: 300)
            }
            SettingsRow(
                title: relayLocalized("Token"),
                detail: relayLocalized("A permanent token: Profile → Account Security → New token. Kept in the keychain.")
            ) {
                HStack(spacing: Theme.Spacing.xsmall) {
                    RelaySecureField(tokenPlaceholder, text: $token, onSubmit: connect)
                        .frame(width: 300 - (tokenPageURL == nil ? 0 : Theme.Metrics.action + Theme.Spacing.xsmall))
                    if let url = tokenPageURL {
                        IconButton(systemImage: "arrow.up.forward.square", size: Theme.Metrics.action) {
                            NSWorkspace.shared.open(url)
                        }
                        .relayTooltip(relayLocalized("Open the page tokens are made on"))
                    }
                }
            }
            SettingsRow(
                title: statusTitle,
                detail: statusDetail,
                detailTint: failure != nil || isFailed ? Theme.Palette.statusError : nil
            ) {
                HStack(spacing: Theme.Spacing.xsmall) {
                    if tracker.isConnected {
                        RelayButton(relayLocalized("Sign Out"), kind: .ghost) {
                            token = ""
                            failure = nil
                            tracker.signOut()
                        }
                    }
                    RelayButton(
                        relayLocalized(isConnecting ? "Connecting…" : (tracker.isConnected ? "Reconnect" : "Connect")),
                        kind: .primary,
                        action: connect
                    )
                    .disabled(isConnecting || token.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var tokenPlaceholder: String {
        tracker.isConnected ? relayLocalized("Kept in the keychain — type a new one to replace it") : "perm:…"
    }

    private var isFailed: Bool {
        if case .failed = tracker.connection { return true }
        return false
    }

    private var statusTitle: String {
        switch tracker.connection {
        case .connected: relayLocalized("Connected")
        case .checking: relayLocalized("Checking…")
        case let .failed(error): relayLocalized(error.kind == .unauthorized ? "Needs a new token" : "Not connected")
        case .needsToken, .off: relayLocalized("Not connected")
        }
    }

    private var statusDetail: String? {
        if let failure { return TrackerText.describe(failure) }
        switch tracker.connection {
        case let .connected(user):
            return String(format: relayLocalized("As %@ (%@), at %@"), user.name, user.login, tracker.settings.address)
        case let .failed(error):
            return TrackerText.describe(error)
        case .needsToken:
            return relayLocalized("Give it the address and a token, and Relay checks them before keeping either")
        case .checking, .off:
            return nil
        }
    }

    /// YouTrack's profile page, where a token is made. Offered once there is an
    /// address to open it at.
    private var tokenPageURL: URL? {
        guard let kind = tracker.settings.kind,
              let base = TrackerController.address(for: kind, typed: address),
              var components = URLComponents(string: base)
        else { return nil }
        components.path += "/users/me"
        components.queryItems = [URLQueryItem(name: "tab", value: "account-security")]
        return components.url
    }

    private func connect() {
        guard let kind = tracker.settings.kind, !isConnecting else { return }
        isConnecting = true
        failure = nil
        Task {
            failure = await tracker.connect(kind, address: address, token: token)
            isConnecting = false
            if failure == nil {
                token = ""
                address = tracker.settings.address
            }
        }
    }
}

/// A field for a secret, dressed as every other field.
struct RelaySecureField: View {
    private let placeholder: String
    @Binding private var text: String
    private let onSubmit: () -> Void

    @FocusState private var isFocused: Bool

    init(_ placeholder: String, text: Binding<String>, onSubmit: @escaping () -> Void = {}) {
        self.placeholder = placeholder
        _text = text
        self.onSubmit = onSubmit
    }

    var body: some View {
        SecureField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.Typography.row)
            .foregroundStyle(Theme.Palette.textPrimary)
            .focused($isFocused)
            .onSubmit(onSubmit)
            .relayFieldPlate(isFocused: isFocused)
    }
}
