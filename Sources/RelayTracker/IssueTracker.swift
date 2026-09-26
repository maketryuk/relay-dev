import Foundation

/// What Relay asks of an issue tracker.
///
/// Shaped by what a board is everywhere rather than by YouTrack: columns that
/// are the values of one field, cards that sit in the column their value names,
/// and moving a card is setting that field. GitHub's projects and GitLab's
/// boards are the same shape with other words for it, so a second tracker is a
/// second conformance, and nothing in the app has to learn it.
///
/// Issues are named by the key people write — `WEB-342` — because that is what
/// arrives from everywhere else: a branch name, a commit, a link pasted into a
/// terminal.
public protocol IssueTracker: Sendable {
    /// Who the token belongs to. Also how a connection is checked.
    func currentUser() async throws -> TrackerUser

    func boards() async throws -> [TrackerBoard]

    /// The board's columns and the cards on them: for `sprint` when the board
    /// has sprints and one is named, for its current one when none is.
    func snapshot(of board: TrackerBoard, sprint: String?) async throws -> BoardSnapshot

    /// One issue in full, with the values each of its fields could take.
    func issue(_ key: String) async throws -> TrackerIssue

    /// Oldest first, the order a conversation is read in.
    func comments(on key: String) async throws -> [TrackerComment]

    func addComment(_ text: String, on key: String) async throws -> TrackerComment

    func updateComment(_ commentID: String, text: String, on key: String) async throws -> TrackerComment

    /// Takes a comment off the issue the way the tracker's own delete does,
    /// where that leaves it restorable there.
    func deleteComment(_ commentID: String, on key: String) async throws

    func workItems(on key: String) async throws -> [TrackerWorkItem]

    /// The kinds of work a project records time as. Empty when it has none, or
    /// when the account is not allowed to read them.
    func workTypes(in project: TrackerProject) async throws -> [TrackerWorkType]

    func logWork(_ entry: WorkEntry, on key: String) async throws -> TrackerWorkItem

    func updateWork(_ itemID: String, with entry: WorkEntry, on key: String) async throws -> TrackerWorkItem

    func deleteWork(_ itemID: String, on key: String) async throws

    /// Puts the card in the column, which is setting the board's field to the
    /// column's value. Answers with the card as the tracker now has it: a
    /// workflow may have changed more than the one field.
    func move(_ card: TrackerCard, to column: BoardColumn, on snapshot: BoardSnapshot) async throws -> TrackerCard

    func update(_ key: String, with change: IssueChange) async throws -> TrackerIssue

    /// Creates an issue and puts it on the board, in `column` when one is named.
    /// Throws only when the issue was not made: once it exists, what went wrong
    /// in putting it where it was asked for is in the answer, so a person who
    /// tries again does not make it twice.
    func create(_ draft: IssueDraft, in column: BoardColumn?, on snapshot: BoardSnapshot) async throws -> CreatedIssue

    /// The tracker's own page for the issue.
    func webURL(for key: String) -> URL

    /// An address for a link the tracker wrote — a picture, an attachment —
    /// which it often writes relative to itself.
    func resolve(_ link: String) -> URL?

    /// What is at an address the tracker gave: an avatar, an attachment. With
    /// the token when the address is the tracker's own, and without it
    /// anywhere else.
    func contents(of url: URL) async throws -> Data
}

/// The trackers Relay can be connected to.
public enum TrackerKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case youTrack

    public var id: String { rawValue }

    /// A product name, the same in every language.
    public var displayName: String {
        switch self {
        case .youTrack: "YouTrack"
        }
    }
}
