import Foundation
import RelayProtocol

/// A finished run of a session.
///
/// The daemon forgets a session once it is closed, so anything worth keeping has
/// to be recorded as it ends. Transcripts are not stored — that would mean
/// persisting unbounded terminal output, and the scrollback already lives in the
/// daemon for as long as the session does — but knowing what ran, for how long
/// and how it ended is what the history is actually for.
struct SessionHistoryEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var projectID: ProjectID
    var kind: SessionKind
    var name: String
    var command: [String]
    var startedAt: Date
    var endedAt: Date
    var exitCode: Int32?

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    var succeeded: Bool { (exitCode ?? 0) == 0 }

    init(from snapshot: SessionSnapshot, endedAt: Date = Date()) {
        id = snapshot.id.rawValue
        projectID = snapshot.projectID
        kind = snapshot.kind
        name = snapshot.displayName
        command = snapshot.command
        startedAt = snapshot.startedAt
        self.endedAt = endedAt
        exitCode = snapshot.exitCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectID = try container.decode(ProjectID.self, forKey: .projectID)
        kind = try container.decodeIfPresent(SessionKind.self, forKey: .kind) ?? .custom
        name = try container.decode(String.self, forKey: .name)
        command = try container.decodeIfPresent([String].self, forKey: .command) ?? []
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        endedAt = try container.decode(Date.self, forKey: .endedAt)
        exitCode = try container.decodeIfPresent(Int32.self, forKey: .exitCode)
    }

    var durationText: String {
        let seconds = Int(duration.rounded())
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }
}

enum SessionHistory {
    /// Enough to look back over a few days of work without the workspace file
    /// growing without end.
    static let limit = 300

    static func appending(
        _ entry: SessionHistoryEntry,
        to history: [SessionHistoryEntry]
    ) -> [SessionHistoryEntry] {
        // A session can be reported as ended more than once — an exit event and
        // then a forget — so the id decides rather than the order.
        var updated = history.filter { $0.id != entry.id }
        updated.insert(entry, at: 0)
        return Array(updated.prefix(limit))
    }

    static func entries(in history: [SessionHistoryEntry], for projectID: ProjectID) -> [SessionHistoryEntry] {
        history.filter { $0.projectID == projectID }
    }
}
