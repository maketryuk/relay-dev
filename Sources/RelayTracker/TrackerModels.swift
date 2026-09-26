import Foundation

public struct TrackerUser: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var login: String
    /// The full name, or the login for an account that has none.
    public var name: String
    /// Where the tracker keeps their picture, as it wrote it — often relative
    /// to the tracker; `IssueTracker.resolve` makes it an address.
    public var avatar: String?

    public init(id: String, login: String, name: String, avatar: String? = nil) {
        self.id = id
        self.login = login
        self.name = name
        self.avatar = avatar
    }
}

public struct TrackerProject: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    /// What the project's issue keys start with: `WEB` in `WEB-342`.
    public var key: String
    public var name: String

    public init(id: String, key: String, name: String) {
        self.id = id
        self.key = key
        self.name = name
    }
}

public struct TrackerSprint: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var isArchived: Bool
    public var start: Date?
    public var finish: Date?

    public init(id: String, name: String, isArchived: Bool = false, start: Date? = nil, finish: Date? = nil) {
        self.id = id
        self.name = name
        self.isArchived = isArchived
        self.start = start
        self.finish = finish
    }
}

public struct TrackerBoard: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var projects: [TrackerProject]
    /// Whether the board is divided into sprints at all. One that is not still
    /// has one behind the scenes, which is what its cards are read from.
    public var usesSprints: Bool
    public var sprints: [TrackerSprint]
    public var currentSprintID: String?
    /// Cards are put on the board by hand rather than found by a query, so one
    /// created here has to be added to it as well.
    public var addsCardsByHand: Bool
    /// The field whose value colours a card, as the board is set up to: usually
    /// the priority. Nil when the board colours cards by something else, or
    /// not at all.
    public var colorField: String?

    public init(
        id: String,
        name: String,
        projects: [TrackerProject] = [],
        usesSprints: Bool = false,
        sprints: [TrackerSprint] = [],
        currentSprintID: String? = nil,
        addsCardsByHand: Bool = false,
        colorField: String? = nil
    ) {
        self.id = id
        self.name = name
        self.projects = projects
        self.usesSprints = usesSprints
        self.sprints = sprints
        self.currentSprintID = currentSprintID
        self.addsCardsByHand = addsCardsByHand
        self.colorField = colorField
    }

    /// The sprints worth offering: the ones not archived, and the one asked
    /// about even if it is.
    public func openSprints(including id: String?) -> [TrackerSprint] {
        sprints.filter { !$0.isArchived || $0.id == id }
    }
}

public struct BoardColumn: Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// The field values the column holds, as the tracker names them in a write.
    /// More than one when columns were merged on the board.
    public var values: [String]
    public var isResolved: Bool
    /// How many cards the team said the column should hold at most.
    public var limit: Int?

    public init(id: String, title: String, values: [String], isResolved: Bool = false, limit: Int? = nil) {
        self.id = id
        self.title = title
        self.values = values
        self.isResolved = isResolved
        self.limit = limit
    }
}

/// A colour a tracker gives a value, as the hex it gives it in.
public struct TrackerColor: Codable, Hashable, Sendable {
    public var background: String
    public var foreground: String

    public init(background: String, foreground: String) {
        self.background = background
        self.foreground = foreground
    }
}

/// One value a field has or could have: a state, a priority, a person.
public struct FieldOption: Hashable, Sendable, Identifiable {
    public var id: String
    /// How the tracker names it in a write.
    public var name: String
    /// How it is shown: the translated name, where the tracker has one.
    public var title: String
    public var color: TrackerColor?
    /// For a state: whether an issue in it counts as done.
    public var isResolved: Bool
    /// For a person, the login a write names them by.
    public var login: String?
    /// For a person, where their picture is.
    public var avatar: String?

    public init(
        id: String,
        name: String,
        title: String? = nil,
        color: TrackerColor? = nil,
        isResolved: Bool = false,
        login: String? = nil,
        avatar: String? = nil
    ) {
        self.id = id
        self.name = name
        self.title = title ?? name
        self.color = color
        self.isResolved = isResolved
        self.login = login
        self.avatar = avatar
    }

    /// The person this value is, for a value of a people field.
    public var user: TrackerUser? {
        login.map { TrackerUser(id: id, login: $0, name: title, avatar: avatar) }
    }
}

public enum FieldKind: String, Hashable, Sendable {
    /// One or several values out of a list: a state, a priority, a version.
    case option
    case user
    /// A length of time: an estimate, the time spent.
    case period
    case date
    case text
    /// Anything else, shown as the tracker writes it.
    case other
}

/// A field of an issue, with its value and, when read in full, the values it
/// could take.
public struct TrackerField: Hashable, Sendable, Identifiable {
    public var name: String
    public var kind: FieldKind
    public var allowsSeveral: Bool
    /// The value, for a field whose values are options or people.
    public var values: [FieldOption]
    /// The value written out, for a field whose value is not one of a list.
    public var text: String?
    public var date: Date?
    /// Every value the field could take. Empty when the issue was read for a
    /// card, or the tracker did not say.
    public var options: [FieldOption]
    public var canBeEmpty: Bool
    /// What the tracker shows in place of no value: "Unassigned", "No priority".
    public var emptyText: String?
    /// The tracker's own name for the kind of field, which a write has to
    /// repeat back to it.
    public var wireType: String

    public var id: String { name }

    public init(
        name: String,
        kind: FieldKind,
        allowsSeveral: Bool = false,
        values: [FieldOption] = [],
        text: String? = nil,
        date: Date? = nil,
        options: [FieldOption] = [],
        canBeEmpty: Bool = true,
        emptyText: String? = nil,
        wireType: String
    ) {
        self.name = name
        self.kind = kind
        self.allowsSeveral = allowsSeveral
        self.values = values
        self.text = text
        self.date = date
        self.options = options
        self.canBeEmpty = canBeEmpty
        self.emptyText = emptyText
        self.wireType = wireType
    }

    /// Relay edits the fields that are a choice out of a list, and only once it
    /// knows the list.
    public var isEditable: Bool {
        (kind == .option || kind == .user) && !options.isEmpty
    }

    public var isEmpty: Bool {
        values.isEmpty && (text ?? "").isEmpty && date == nil
    }
}

public struct TrackerTag: Hashable, Sendable {
    public var name: String
    public var color: TrackerColor?

    public init(name: String, color: TrackerColor? = nil) {
        self.name = name
        self.color = color
    }
}

/// An issue as a board shows it.
public struct TrackerCard: Hashable, Sendable, Identifiable {
    /// The tracker's own identifier, which is not the key.
    public var id: String
    public var key: String
    public var summary: String
    public var project: TrackerProject
    public var fields: [TrackerField]
    public var tags: [TrackerTag]
    public var isResolved: Bool
    public var updated: Date

    public init(
        id: String,
        key: String,
        summary: String,
        project: TrackerProject,
        fields: [TrackerField] = [],
        tags: [TrackerTag] = [],
        isResolved: Bool = false,
        updated: Date = Date(timeIntervalSince1970: 0)
    ) {
        self.id = id
        self.key = key
        self.summary = summary
        self.project = project
        self.fields = fields
        self.tags = tags
        self.isResolved = isResolved
        self.updated = updated
    }

    public func field(named name: String) -> TrackerField? {
        fields.first { $0.name == name }
    }

    /// Who the work is with. The field called Assignee when there is one, since
    /// a project may have several people fields and that is the one a board
    /// means; otherwise the only single-person field there is.
    public var assignee: FieldOption? {
        TrackerCard.assignee(in: fields)
    }

    static func assignee(in fields: [TrackerField]) -> FieldOption? {
        let people = fields.filter { $0.kind == .user && !$0.allowsSeveral }
        let chosen = people.first { $0.name.caseInsensitiveCompare("Assignee") == .orderedSame }
            ?? (people.count == 1 ? people.first : nil)
        return chosen?.values.first
    }
}

/// A board as it stands: its columns, and the cards on them.
public struct BoardSnapshot: Equatable, Sendable {
    public var board: TrackerBoard
    public var sprint: TrackerSprint?
    /// The field whose values are the columns — usually the state.
    public var columnField: String?
    public var columns: [BoardColumn]
    /// In the order the tracker lists them, which is the order it shows them in.
    public var cards: [TrackerCard]

    public init(
        board: TrackerBoard,
        sprint: TrackerSprint? = nil,
        columnField: String? = nil,
        columns: [BoardColumn] = [],
        cards: [TrackerCard] = []
    ) {
        self.board = board
        self.sprint = sprint
        self.columnField = columnField
        self.columns = columns
        self.cards = cards
    }

    /// The column the card's value puts it in, or nil for a card whose value
    /// no column holds — the board does not show those either.
    public func column(of card: TrackerCard) -> BoardColumn? {
        guard let columnField, let field = card.field(named: columnField) else { return nil }
        let names = Set(field.values.map(\.name))
        return columns.first { column in column.values.contains(where: names.contains) }
    }

    public func cards(in column: BoardColumn) -> [TrackerCard] {
        cards.filter { self.column(of: $0)?.id == column.id }
    }

    /// The kind the board's field is, read off a card that has it: a write
    /// has to name it, and a card about to be moved may not carry the field
    /// at all.
    public func columnFieldWireType() -> String? {
        guard let columnField else { return nil }
        return cards.lazy.compactMap { $0.field(named: columnField)?.wireType }.first
    }

    /// Moves a card to a column here, before the tracker has agreed, so a drop
    /// lands where it was dropped instead of waiting on a round trip.
    public mutating func place(_ card: TrackerCard, in column: BoardColumn) {
        guard let columnField, let value = column.values.first,
              let index = cards.firstIndex(where: { $0.id == card.id })
        else { return }
        let option = FieldOption(id: column.id, name: value, title: column.title, isResolved: column.isResolved)
        if let fieldIndex = cards[index].fields.firstIndex(where: { $0.name == columnField }) {
            cards[index].fields[fieldIndex].values = [option]
        } else if let wireType = columnFieldWireType() {
            cards[index].fields.append(TrackerField(
                name: columnField,
                kind: .option,
                values: [option],
                wireType: wireType
            ))
        }
    }

    /// Puts the tracker's answer in place of what was there, or at the end
    /// when the card is new to the board.
    public mutating func replace(_ card: TrackerCard) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) {
            cards[index] = card
        } else {
            cards.append(card)
        }
    }
}

/// An issue in full.
public struct TrackerIssue: Equatable, Sendable, Identifiable {
    public var id: String
    public var key: String
    public var summary: String
    /// Markdown, as the tracker stores it.
    public var description: String
    public var project: TrackerProject
    public var reporter: TrackerUser?
    /// Who changed it last.
    public var updater: TrackerUser?
    public var created: Date
    public var updated: Date
    public var resolved: Date?
    public var fields: [TrackerField]
    public var tags: [TrackerTag]
    /// The files on the issue and on its comments, which its text refers to by
    /// name.
    public var attachments: [TrackerAttachment]

    public init(
        id: String,
        key: String,
        summary: String,
        description: String = "",
        project: TrackerProject,
        reporter: TrackerUser? = nil,
        updater: TrackerUser? = nil,
        created: Date = Date(timeIntervalSince1970: 0),
        updated: Date = Date(timeIntervalSince1970: 0),
        resolved: Date? = nil,
        fields: [TrackerField] = [],
        tags: [TrackerTag] = [],
        attachments: [TrackerAttachment] = []
    ) {
        self.id = id
        self.key = key
        self.summary = summary
        self.description = description
        self.project = project
        self.reporter = reporter
        self.updater = updater
        self.created = created
        self.updated = updated
        self.resolved = resolved
        self.fields = fields
        self.tags = tags
        self.attachments = attachments
    }

    public func field(named name: String) -> TrackerField? {
        fields.first { $0.name == name }
    }

    public var assignee: FieldOption? {
        TrackerCard.assignee(in: fields)
    }

    /// The attachment a piece of text refers to — by its name, as YouTrack's
    /// Markdown does (`![](Screenshot.png)`), or by its address.
    public func attachment(named reference: String) -> TrackerAttachment? {
        let decoded = reference.removingPercentEncoding ?? reference
        return attachments.first { $0.name == decoded || $0.name == reference || $0.url == reference }
    }

    /// Everyone the issue knows of: whoever its people fields could name, who
    /// reported it and who commented on it. Who can be mentioned in a reply.
    public func people(with comments: [TrackerComment]) -> [TrackerUser] {
        var found: [String: TrackerUser] = [:]
        func add(_ user: TrackerUser?) {
            guard let user, found[user.login] == nil else { return }
            found[user.login] = user
        }
        for field in fields where field.kind == .user {
            (field.values + field.options).forEach { add($0.user) }
        }
        add(reporter)
        comments.forEach { add($0.author) }
        return found.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The same issue as a board would show it, for putting an edit made in
    /// the issue back on the board without reading the board again.
    public var card: TrackerCard {
        TrackerCard(
            id: id,
            key: key,
            summary: summary,
            project: project,
            fields: fields.map { field in
                var bare = field
                bare.options = []
                return bare
            },
            tags: tags,
            isResolved: resolved != nil,
            updated: updated
        )
    }
}

public struct TrackerComment: Hashable, Sendable, Identifiable {
    public var id: String
    /// Markdown, as the tracker stores it.
    public var text: String
    public var author: TrackerUser?
    public var created: Date

    public init(id: String, text: String, author: TrackerUser? = nil, created: Date) {
        self.id = id
        self.text = text
        self.author = author
        self.created = created
    }
}

public struct TrackerWorkType: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// Time spent on an issue, as the tracker has it recorded.
public struct TrackerWorkItem: Hashable, Sendable, Identifiable {
    public var id: String
    public var minutes: Int
    public var date: Date
    public var text: String
    public var author: TrackerUser?
    public var type: TrackerWorkType?

    public init(
        id: String,
        minutes: Int,
        date: Date,
        text: String = "",
        author: TrackerUser? = nil,
        type: TrackerWorkType? = nil
    ) {
        self.id = id
        self.minutes = minutes
        self.date = date
        self.text = text
        self.author = author
        self.type = type
    }
}

/// Time to record against an issue.
public struct WorkEntry: Equatable, Sendable {
    public var minutes: Int
    /// The day the work was done on.
    public var date: Date
    public var text: String
    public var typeID: String?

    public init(minutes: Int, date: Date, text: String = "", typeID: String? = nil) {
        self.minutes = minutes
        self.date = date
        self.text = text
        self.typeID = typeID
    }
}

/// A new value for one field: none clears it.
public struct FieldChange: Equatable, Sendable {
    public var field: TrackerField
    public var values: [FieldOption]

    public init(field: TrackerField, values: [FieldOption]) {
        self.field = field
        self.values = values
    }
}

/// What to change about an issue. Whatever is nil stays as it is.
public struct IssueChange: Equatable, Sendable {
    public var summary: String?
    public var description: String?
    public var fields: [FieldChange]

    public init(summary: String? = nil, description: String? = nil, fields: [FieldChange] = []) {
        self.summary = summary
        self.description = description
        self.fields = fields
    }

    public var isEmpty: Bool {
        summary == nil && description == nil && fields.isEmpty
    }
}

/// A file on an issue.
public struct TrackerAttachment: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// Where it is, as the tracker wrote it.
    public var url: String
    public var thumbnail: String?
    public var mimeType: String?
    public var size: Int64?

    public init(id: String, name: String, url: String, thumbnail: String? = nil, mimeType: String? = nil, size: Int64? = nil) {
        self.id = id
        self.name = name
        self.url = url
        self.thumbnail = thumbnail
        self.mimeType = mimeType
        self.size = size
    }

    public var isImage: Bool {
        if let mimeType { return mimeType.hasPrefix("image/") }
        let pictures: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff", "svg"]
        return pictures.contains((name as NSString).pathExtension.lowercased())
    }
}

/// An issue just made, and what stopped it landing where it was asked for.
public struct CreatedIssue: Equatable, Sendable {
    public var card: TrackerCard
    /// Why it is not on the board, or not in its column, when it is not.
    public var misplaced: TrackerError?

    public init(card: TrackerCard, misplaced: TrackerError? = nil) {
        self.card = card
        self.misplaced = misplaced
    }
}

/// An issue that does not exist yet.
public struct IssueDraft: Equatable, Sendable {
    public var project: TrackerProject
    public var summary: String
    public var description: String

    public init(project: TrackerProject, summary: String, description: String = "") {
        self.project = project
        self.summary = summary
        self.description = description
    }
}
