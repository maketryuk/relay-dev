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
        case .ports: CGSize(width: 640, height: 560)
        case .sshHosts: CGSize(width: 560, height: 540)
        case .settings: CGSize(width: 760, height: 580)
        }
    }
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

            ModalSurface(modal.title, onDismiss: { model.dismissModal() }) {
                content
            }
            .frame(width: modal.size.width, height: modal.size.height)
            .modalPlate()
            // A text field inside swallows Escape before SwiftUI sees it, so
            // the key is caught at the window instead.
            .background { KeyCaptureView(onEscape: { model.dismissModal() }) }
        }
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
