import Foundation

/// YouTrack's answers turned into the tracker-neutral models the app draws.
enum YouTrackMapping {
    static func user(_ wire: YouTrackWire.User?) -> TrackerUser? {
        guard let wire, let login = wire.login ?? wire.id else { return nil }
        return TrackerUser(
            id: wire.id ?? login,
            login: login,
            name: nonEmpty(wire.fullName) ?? login,
            avatar: nonEmpty(wire.avatarUrl)
        )
    }

    static func project(_ wire: YouTrackWire.Project?) -> TrackerProject {
        guard let wire else { return TrackerProject(id: "", key: "", name: "") }
        let key = wire.shortName ?? ""
        return TrackerProject(id: wire.id, key: key, name: wire.name ?? key)
    }

    static func color(_ wire: YouTrackWire.Color?) -> TrackerColor? {
        guard let background = wire?.background, let foreground = wire?.foreground else { return nil }
        return TrackerColor(background: background, foreground: foreground)
    }

    static func date(_ milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    // MARK: - Boards

    static func board(_ wire: YouTrackWire.Board) -> TrackerBoard {
        let usesSprints = !(wire.sprintsSettings?.disableSprints ?? false)
        return TrackerBoard(
            id: wire.id,
            name: wire.name ?? wire.id,
            projects: (wire.projects ?? []).map(project),
            usesSprints: usesSprints,
            sprints: (wire.sprints ?? []).map(sprint),
            currentSprintID: wire.currentSprint?.id,
            addsCardsByHand: wire.sprintsSettings?.isExplicit ?? false,
            colorField: wire.colorCoding?.prototype?.name
        )
    }

    static func sprint(_ wire: YouTrackWire.SprintReference) -> TrackerSprint {
        TrackerSprint(
            id: wire.id,
            name: wire.name ?? wire.id,
            isArchived: wire.archived ?? false,
            start: date(wire.start),
            finish: date(wire.finish)
        )
    }

    /// Left to right, as the board has them.
    static func columns(_ wire: YouTrackWire.ColumnSettings?) -> [BoardColumn] {
        (wire?.columns ?? [])
            .enumerated()
            .sorted { ($0.element.ordinal ?? $0.offset, $0.offset) < ($1.element.ordinal ?? $1.offset, $1.offset) }
            .map { _, column in
                let values = (column.fieldValues ?? []).compactMap(\.name)
                let title = column.presentation ?? values.joined(separator: ", ")
                return BoardColumn(
                    id: column.id,
                    title: title.isEmpty ? column.id : title,
                    values: values,
                    isResolved: column.isResolved ?? false,
                    limit: column.wipLimit?.max
                )
            }
    }

    static func snapshot(
        of board: TrackerBoard,
        settings: YouTrackWire.ColumnSettings?,
        sprint: YouTrackWire.Sprint
    ) -> BoardSnapshot {
        BoardSnapshot(
            board: board,
            sprint: TrackerSprint(
                id: sprint.id,
                name: sprint.name ?? sprint.id,
                isArchived: sprint.archived ?? false,
                start: date(sprint.start),
                finish: date(sprint.finish)
            ),
            columnField: settings?.field?.name,
            columns: columns(settings),
            cards: (sprint.issues ?? []).map(card)
        )
    }

    // MARK: - Issues

    static func card(_ wire: YouTrackWire.Issue) -> TrackerCard {
        TrackerCard(
            id: wire.id,
            key: wire.idReadable ?? wire.id,
            summary: wire.summary ?? "",
            project: project(wire.project),
            fields: (wire.customFields ?? []).map(field),
            tags: (wire.tags ?? []).compactMap(tag),
            isResolved: wire.resolved != nil,
            updated: date(wire.updated) ?? Date(timeIntervalSince1970: 0)
        )
    }

    static func issue(_ wire: YouTrackWire.Issue) -> TrackerIssue {
        TrackerIssue(
            id: wire.id,
            key: wire.idReadable ?? wire.id,
            summary: wire.summary ?? "",
            description: wire.description ?? "",
            project: project(wire.project),
            reporter: user(wire.reporter),
            created: date(wire.created) ?? Date(timeIntervalSince1970: 0),
            updated: date(wire.updated) ?? Date(timeIntervalSince1970: 0),
            resolved: date(wire.resolved),
            fields: (wire.customFields ?? []).map(field),
            tags: (wire.tags ?? []).compactMap(tag),
            attachments: (wire.attachments ?? []).compactMap(attachment)
        )
    }

    /// A file that has been removed is still listed, marked so; it is gone
    /// as far as anybody reading the issue is concerned.
    static func attachment(_ wire: YouTrackWire.Attachment) -> TrackerAttachment? {
        guard wire.removed != true, let name = wire.name, let url = nonEmpty(wire.url) else { return nil }
        return TrackerAttachment(
            id: wire.id,
            name: name,
            url: url,
            thumbnail: nonEmpty(wire.thumbnailURL),
            mimeType: nonEmpty(wire.mimeType),
            size: wire.size
        )
    }

    static func tag(_ wire: YouTrackWire.Tag) -> TrackerTag? {
        guard let name = wire.name, !name.isEmpty else { return nil }
        return TrackerTag(name: name, color: color(wire.color))
    }

    static func field(_ wire: YouTrackWire.CustomField) -> TrackerField {
        let kind = YouTrackAPI.kind(of: wire.type)
        var field = TrackerField(
            name: wire.name,
            kind: kind,
            allowsSeveral: YouTrackAPI.allowsSeveral(wire.type),
            canBeEmpty: wire.projectCustomField?.canBeEmpty ?? true,
            emptyText: wire.projectCustomField?.emptyFieldText,
            wireType: wire.type
        )

        switch wire.value ?? .none {
        case .none:
            break
        case let .one(entity):
            place(entity, in: &field)
        case let .many(entities):
            field.values = entities.compactMap { option($0, kind: kind) }
        case let .number(number):
            if kind == .date {
                field.date = Date(timeIntervalSince1970: number / 1000)
            } else {
                field.text = number == number.rounded() ? String(Int(number)) : String(number)
            }
        case let .string(string):
            field.text = string
        }

        if let bundle = wire.projectCustomField?.bundle {
            field.options = kind == .user
                ? (bundle.aggregatedUsers ?? []).compactMap(userOption)
                : (bundle.values ?? []).compactMap { option($0, kind: kind) }
        }
        return field
    }

    /// A single value is an option for a field of options and people, and a
    /// line of text for the rest — a period's `1h 30m`, a text field's body.
    private static func place(_ entity: YouTrackWire.Entity, in field: inout TrackerField) {
        switch field.kind {
        case .option, .user:
            field.values = option(entity, kind: field.kind).map { [$0] } ?? []
        case .period:
            field.text = entity.presentation ?? entity.minutes.map(WorkDuration.written)
        case .text:
            field.text = entity.text
        case .date, .other:
            field.text = entity.presentation ?? entity.text ?? entity.name
        }
    }

    static func option(_ entity: YouTrackWire.Entity, kind: FieldKind) -> FieldOption? {
        if kind == .user {
            guard let login = entity.login ?? entity.name else { return nil }
            return FieldOption(
                id: entity.id ?? login,
                name: login,
                title: nonEmpty(entity.fullName) ?? login,
                login: login,
                avatar: nonEmpty(entity.avatarUrl)
            )
        }
        guard let name = entity.name ?? entity.presentation else { return nil }
        return FieldOption(
            id: entity.id ?? name,
            name: name,
            title: nonEmpty(entity.localizedName) ?? nonEmpty(entity.presentation) ?? name,
            color: color(entity.color),
            isResolved: entity.isResolved ?? false
        )
    }

    static func userOption(_ wire: YouTrackWire.User) -> FieldOption? {
        guard let user = user(wire) else { return nil }
        return FieldOption(id: user.id, name: user.login, title: user.name, login: user.login, avatar: user.avatar)
    }

    // MARK: - Conversation and time

    static func comment(_ wire: YouTrackWire.Comment) -> TrackerComment {
        TrackerComment(
            id: wire.id,
            text: wire.text ?? "",
            author: user(wire.author),
            created: date(wire.created) ?? Date(timeIntervalSince1970: 0)
        )
    }

    static func workItem(_ wire: YouTrackWire.WorkItem) -> TrackerWorkItem {
        TrackerWorkItem(
            id: wire.id,
            minutes: wire.duration?.minutes ?? 0,
            date: date(wire.date) ?? Date(timeIntervalSince1970: 0),
            text: wire.text ?? "",
            author: user(wire.author),
            type: wire.type.map { TrackerWorkType(id: $0.id, name: $0.name ?? $0.id) }
        )
    }

    static func workTypes(_ wire: YouTrackWire.TimeTrackingSettings) -> [TrackerWorkType] {
        guard wire.enabled ?? true else { return [] }
        return (wire.workItemTypes ?? []).map { TrackerWorkType(id: $0.id, name: $0.name ?? $0.id) }
    }

    // MARK: - Failures

    /// What a refusal amounts to, from its status and what came with it.
    static func failure(status: Int, body: Data, location: String?, isWrite: Bool) -> TrackerError {
        let said = (try? JSONDecoder().decode(YouTrackWire.Failure.self, from: body))
            .flatMap { nonEmpty($0.errorDescription) ?? nonEmpty($0.error) }
            .map(tidy)
        switch status {
        case 300 ..< 400: return TrackerError(.redirected(to: location), message: said)
        case 401: return TrackerError(.unauthorized, message: said)
        case 403: return TrackerError(.forbidden, message: said)
        case 404: return TrackerError(.notFound, message: said)
        case 429: return TrackerError(.rateLimited, message: said)
        case 500...: return TrackerError(isWrite ? .uncertain : .serverFailure(status: status), message: said)
        default: return TrackerError(.rejected, message: said)
        }
    }

    /// One line, and not a page of it: this goes into a toast.
    private static func tidy(_ message: String) -> String {
        let line = message
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return line.count > 300 ? String(line.prefix(299)) + "…" : line
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
