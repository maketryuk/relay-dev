import RelayUI
import SwiftUI

extension View {
    /// Tooltip overload that formats a `KeyBinding` for display, so callers
    /// never build shortcut strings by hand.
    func relayTooltip(_ label: String, shortcut: KeyBinding?, edge: Edge = .bottom) -> some View {
        relayTooltip(label, shortcut: shortcut?.displayString, edge: edge)
    }
}
