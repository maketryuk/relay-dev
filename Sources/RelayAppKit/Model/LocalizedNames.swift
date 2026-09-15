import Foundation
import RelayProtocol
import RelayUI

/// Display names for types that live below the UI layer.
///
/// `RuntimeStatus` and the command registry are part of the model, and the model
/// has no business knowing which language the window is in. The English name
/// stays where it is defined and doubles as the lookup key.
@MainActor
extension RuntimeStatus {
    var localizedName: String { relayLocalized(displayName) }
}

@MainActor
extension RelayCommand {
    var localizedTitle: String { relayLocalized(title) }
}

@MainActor
extension ShortcutCategory {
    var localizedTitle: String { relayLocalized(title) }
}

@MainActor
extension RightSidebarTab {
    var localizedTitle: String { relayLocalized(title) }
    var localizedComingSoon: String { relayLocalized(comingSoonDescription) }
}

@MainActor
extension ServiceState {
    var localizedName: String { relayLocalized(displayName) }
}

@MainActor
extension ComposeAction {
    var localizedTitle: String { relayLocalized(title) }
}

@MainActor
extension ContainerAction {
    var localizedTitle: String { relayLocalized(title) }
}
