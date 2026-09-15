import AppKit
import SwiftUI

/// Opens, focuses or closes an auxiliary window.
///
/// `openWindow` only ever opens, so a shortcut bound to it could not put the
/// window away again. Closing unconditionally would be just as wrong: a window
/// sitting behind the main one should come forward, not vanish. So the rule is
/// the one every panel toggle uses — front and focused means close, anything
/// else means show me.
@MainActor
enum WindowToggle {
    static func toggle(
        id: String,
        isOpen: Bool,
        openWindow: OpenWindowAction,
        dismissWindow: DismissWindowAction
    ) {
        guard isOpen else {
            openWindow(id: id)
            return
        }

        if isFrontmost(id: id) {
            dismissWindow(id: id)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: id)
        }
    }

    /// SwiftUI stamps the scene identifier onto the window, which is the only
    /// way to ask AppKit which of them has focus.
    private static func isFrontmost(id: String) -> Bool {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains(id) == true }) else {
            // Without a window to inspect, assume it is in front: the toggle
            // then closes it, which the user can undo with the same key.
            return true
        }
        return window.isKeyWindow || window.isMainWindow
    }
}

/// Tracks which auxiliary windows are on screen.
///
/// The scene itself reports this rather than the app guessing from `NSApp`,
/// because a scene that has never been opened has no window to find.
struct WindowPresenceReporter: ViewModifier {
    @Environment(AppModel.self) private var model
    let id: String

    func body(content: Content) -> some View {
        content
            .onAppear { model.windowOpened(id) }
            .onDisappear { model.windowClosed(id) }
    }
}

extension View {
    func reportsWindowPresence(_ id: String) -> some View {
        modifier(WindowPresenceReporter(id: id))
    }
}
