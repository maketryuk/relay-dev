import Foundation
import RelayProtocol

/// Filter predicate for the ports popover.
///
/// Extracted from the view so the matching rules — which fields count, and that
/// matching ignores case — are pinned by tests rather than by trying it.
enum PortFiltering {
    static func matches(_ port: ListeningPort, query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return true }
        return String(port.port).contains(trimmed)
            || port.processName.lowercased().contains(trimmed)
            || (port.ownerName?.lowercased().contains(trimmed) ?? false)
    }
}
