import RelayUI
import SwiftUI

/// The panels that open over the window rather than beside it.
///
/// They were separate windows, each with its own traffic lights to chase around
/// the screen and dismiss. Nothing here is a document or a place to leave open
/// while working — they are things you consult and close — so they behave like
/// the command palette: one Escape, one click outside, gone.
enum RelayModal: String, Identifiable, Hashable, CaseIterable {
    case ports
    case sshHosts
    case settings

    var id: String { rawValue }

    @MainActor
    var title: String {
        switch self {
        case .ports: relayLocalized("Ports")
        case .sshHosts: relayLocalized("SSH Hosts")
        case .settings: relayLocalized("Settings")
        }
    }

    var size: CGSize {
        switch self {
        case .ports: CGSize(width: 640, height: 540)
        case .sshHosts: CGSize(width: 560, height: 520)
        // Its own layout is fixed; the modal only frames it.
        case .settings: CGSize(width: 720, height: 520)
        }
    }

    /// Settings draws its own two-pane layout, title included.
    var drawsOwnHeader: Bool { self == .settings }
}

struct ModalHost: View {
    @Environment(AppModel.self) private var model
    let modal: RelayModal

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { model.dismissModal() }

            panel
                .frame(width: modal.size.width, height: modal.size.height)
                .background(Theme.Palette.base)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                        .strokeBorder(Theme.Palette.border, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.55), radius: 40, y: 16)
                // A text field inside swallows Escape before SwiftUI sees it,
                // so the key is caught at the window instead.
                .background { KeyCaptureView(onEscape: { model.dismissModal() }) }
        }
    }

    @ViewBuilder
    private var panel: some View {
        if modal.drawsOwnHeader {
            content
        } else {
            VStack(spacing: 0) {
                header
                RelayDivider()
                content
            }
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.small) {
            Text(modal.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Palette.textPrimary)
            Spacer(minLength: Theme.Spacing.small)
            IconButton(systemImage: "xmark", help: "") { model.dismissModal() }
                .relayTooltip(relayLocalized("Close"), shortcut: "esc")
        }
        .padding(.horizontal, Theme.Spacing.large)
        .padding(.top, Theme.Spacing.large)
        .padding(.bottom, Theme.Spacing.medium)
    }

    @ViewBuilder
    private var content: some View {
        switch modal {
        case .ports: PortsPane()
        case .sshHosts: SSHPane()
        case .settings: SettingsView()
        }
    }
}
