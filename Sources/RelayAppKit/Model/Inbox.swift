import Foundation
import RelayProtocol

/// One notification, kept in the app so it can be read after the banner is gone.
struct InboxItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let event: AttentionEvent
    let projectID: ProjectID
    let occurredAt: Date
    var isRead: Bool

    init(event: AttentionEvent, projectID: ProjectID, occurredAt: Date = Date()) {
        id = UUID()
        self.event = event
        self.projectID = projectID
        self.occurredAt = occurredAt
        isRead = false
    }
}

enum Inbox {
    /// A banner is transient; this list is the record. It is bounded because a
    /// busy day of agents would otherwise grow it without limit.
    static let limit = 100

    static func appending(_ item: InboxItem, to items: [InboxItem]) -> [InboxItem] {
        // One session cannot have two outstanding notices of the same kind —
        // an agent that asks, is answered and asks again should replace, not
        // accumulate.
        var updated = items.filter {
            !($0.event.sessionID == item.event.sessionID && $0.event.kind == item.event.kind && !$0.isRead)
        }
        updated.insert(item, at: 0)
        return Array(updated.prefix(limit))
    }

    static func unreadCount(_ items: [InboxItem]) -> Int {
        items.count { !$0.isRead }
    }

    static func markingAllRead(_ items: [InboxItem]) -> [InboxItem] {
        items.map { item in
            var updated = item
            updated.isRead = true
            return updated
        }
    }

    static func marking(_ id: UUID, readIn items: [InboxItem]) -> [InboxItem] {
        items.map { item in
            guard item.id == id else { return item }
            var updated = item
            updated.isRead = true
            return updated
        }
    }
}
