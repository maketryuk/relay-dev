import Foundation

/// Where the work in a worktree has got to, as whoever is doing it says.
/// The raw values are what the command line accepts and the workspace file stores.
public enum WorktreeWorkStatus: String, Codable, CaseIterable, Sendable {
    case todo
    case inProgress = "in-progress"
    case inReview = "in-review"
    case completed
}

/// What has been said about one worktree.
///
/// Said by a person from the sidebar or by an agent through `relay worktree
/// set`, and kept by the app beside the worktree's path, because it is the one
/// thing about a worktree that git has nowhere to put.
public struct WorktreeNote: Codable, Equatable, Sendable {
    public var status: WorktreeWorkStatus?
    public var comment: String?
    public var updatedAt: Date

    public init(status: WorktreeWorkStatus? = nil, comment: String? = nil, updatedAt: Date = Date()) {
        self.status = status
        self.comment = comment
        self.updatedAt = updatedAt
    }

    /// A status this build does not know — one a later build added — reads as
    /// none rather than failing the note, so the comment beside it survives
    /// going back a version.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try? container.decodeIfPresent(WorktreeWorkStatus.self, forKey: .status)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    /// Nothing left to show, so nothing worth keeping.
    public var isEmpty: Bool { status == nil && (comment ?? "").isEmpty }
}
