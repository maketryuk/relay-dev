import Foundation
import RelayUI

/// Queue rules for the toast stack.
///
/// Extracted from the model so the parts that get irritating when wrong — a
/// repeated message stacking up, an old one outliving its welcome — are pinned
/// by tests rather than by watching the corner of the screen.
enum ToastCenter {
    /// Beyond this the stack stops being glanceable and starts being a wall.
    static let limit = 4

    static func appending(_ toast: ToastContent, to toasts: [ToastContent]) -> [ToastContent] {
        var updated = toasts
        if let key = toast.key {
            // A recurring condition — the daemon dropping, a service failing to
            // start — should update in place, not pile up.
            updated.removeAll { $0.key == key }
        }
        updated.append(toast)
        return Array(updated.suffix(limit))
    }

    static func removing(_ id: UUID, from toasts: [ToastContent]) -> [ToastContent] {
        toasts.filter { $0.id != id }
    }

    static func removing(key: String, from toasts: [ToastContent]) -> [ToastContent] {
        toasts.filter { $0.key != key }
    }
}
