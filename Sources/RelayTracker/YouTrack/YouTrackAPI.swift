import Foundation

/// One call to YouTrack's REST API, before it has an address or a token.
///
/// Built by pure functions so what Relay asks for — which path, which fields,
/// which body — is tested without a YouTrack to ask.
struct YouTrackRequest: Equatable, Sendable {
    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case delete = "DELETE"
    }

    var method: Method
    /// Below `/api/`, already escaped where it names an issue.
    var path: String
    var query: [URLQueryItem]
    var body: Data?

    var isWrite: Bool { method != .get }

    func urlRequest(for connection: YouTrackConnection, timeout: TimeInterval) -> URLRequest {
        var components = URLComponents(url: connection.baseURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedPath = components.percentEncodedPath + "/api/" + path
        components.queryItems = query.isEmpty ? nil : query
        // `URLComponents` leaves `$` and `,` alone in a query, which YouTrack
        // reads as written; a `+` it would read as a space, so it is escaped.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: components.url!)
        request.httpMethod = method.rawValue
        request.timeoutInterval = timeout
        request.setValue("Bearer \(connection.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }
}

/// What Relay asks YouTrack, and in which words.
///
/// YouTrack answers with only the fields a request names, so each list below
/// is the whole of what the app knows about the thing it describes. Names that
/// exist on only some kinds of value — `login` on a person, `minutes` on a
/// period — are asked for together, and each value answers with the ones it
/// has.
enum YouTrackAPI {
    static let userFields = "id,login,fullName,avatarUrl"
    static let projectFields = "id,shortName,name"
    static let colorFields = "color(background,foreground)"
    static let valueFields = "id,name,localizedName,login,fullName,avatarUrl,presentation,text,minutes,isResolved,\(colorFields)"
    static let optionFields = "id,name,localizedName,isResolved,\(colorFields)"
    static let cardFields = [
        "id,idReadable,summary,updated,resolved",
        "project(\(projectFields))",
        "tags(name,\(colorFields))",
        "customFields(name,$type,value(\(valueFields)))",
    ].joined(separator: ",")
    static let issueFields = [
        "id,idReadable,summary,description,created,updated,resolved",
        "project(\(projectFields))",
        "reporter(\(userFields))",
        "updater(\(userFields))",
        "tags(name,\(colorFields))",
        "customFields(name,$type,value(\(valueFields)),projectCustomField(canBeEmpty,emptyFieldText,"
            + "bundle(values(\(optionFields)),aggregatedUsers(\(userFields)))))",
        "attachments(id,name,url,thumbnailURL,mimeType,size,removed)",
    ].joined(separator: ",")
    static let boardFields = [
        "id,name",
        "projects(\(projectFields))",
        "sprintsSettings(disableSprints,isExplicit)",
        "currentSprint(id,name)",
        "sprints(id,name,archived,start,finish)",
        "columnSettings(field(name),columns(id,presentation,isResolved,ordinal,wipLimit(max),fieldValues(name,isResolved)))",
        // `prototype` is the field a card is coloured by; only colouring by a
        // field has one, and colouring by project answers without it.
        "colorCoding(prototype(name))",
    ].joined(separator: ",")
    static let commentFields = "id,text,created,deleted,author(\(userFields))"
    static let workItemFields = "id,date,text,duration(minutes),author(\(userFields)),type(id,name)"

    /// YouTrack answers a list with forty-two entries unless told otherwise,
    /// which is a board missing its last column's worth of anything.
    static let listLimit = "500"

    static func currentUser() -> YouTrackRequest {
        get("users/me", fields: userFields)
    }

    static func boards() -> YouTrackRequest {
        get("agiles", fields: boardFields, top: listLimit)
    }

    static func board(_ id: String) -> YouTrackRequest {
        get("agiles/\(escaped(id))", fields: boardFields)
    }

    static func sprint(_ sprintID: String, of boardID: String) -> YouTrackRequest {
        get(
            "agiles/\(escaped(boardID))/sprints/\(escaped(sprintID))",
            fields: "id,name,archived,start,finish,issues(\(cardFields))"
        )
    }

    static func issue(_ key: String) -> YouTrackRequest {
        get("issues/\(escaped(key))", fields: issueFields)
    }

    static func card(_ key: String) -> YouTrackRequest {
        get("issues/\(escaped(key))", fields: cardFields)
    }

    /// Applies a command the way the command box in YouTrack does, workflows
    /// and all. The one way to move a state a state machine governs: such a
    /// field does not take a value, only a transition, and which transition
    /// leads where is the workflow's knowledge rather than the API's.
    static func command(_ query: String, on key: String) -> YouTrackRequest {
        post("commands", fields: "id", body: ["query": query, "issues": [["idReadable": key]]])
    }

    /// `State {In Progress}`: the braces are how a command takes a value with
    /// spaces in it, and cannot themselves be part of one.
    static func commandQuery(field: String, value: String) -> String {
        let bare = value.filter { $0 != "{" && $0 != "}" }
        return "\(field) {\(bare)}"
    }

    /// The kind of field that changes by transition rather than by value.
    static let stateMachine = "StateMachineIssueCustomField"

    static func comments(on key: String) -> YouTrackRequest {
        get("issues/\(escaped(key))/comments", fields: commentFields, top: listLimit)
    }

    static func addComment(_ text: String, on key: String) -> YouTrackRequest {
        post("issues/\(escaped(key))/comments", fields: commentFields, body: ["text": text])
    }

    static func workItems(on key: String) -> YouTrackRequest {
        get("issues/\(escaped(key))/timeTracking/workItems", fields: workItemFields, top: listLimit)
    }

    static func workTypes(in projectID: String) -> YouTrackRequest {
        get("admin/projects/\(escaped(projectID))/timeTrackingSettings", fields: "enabled,workItemTypes(id,name)")
    }

    static func updateComment(_ commentID: String, text: String, on key: String) -> YouTrackRequest {
        post("issues/\(escaped(key))/comments/\(escaped(commentID))", fields: commentFields, body: ["text": text])
    }

    /// What YouTrack's own delete does: the comment is marked deleted and can
    /// be restored from the issue there, rather than erased from its database,
    /// which is what a `DELETE` of it would do.
    static func deleteComment(_ commentID: String, on key: String) -> YouTrackRequest {
        post("issues/\(escaped(key))/comments/\(escaped(commentID))", fields: "id", body: ["deleted": true])
    }

    static func logWork(_ entry: WorkEntry, on key: String) -> YouTrackRequest {
        post("issues/\(escaped(key))/timeTracking/workItems", fields: workItemFields, body: workBody(entry, clearsType: false))
    }

    /// Every part of the entry, the kind of work included: one taken away in
    /// the edit is written as none, not left as it was.
    static func updateWork(_ itemID: String, with entry: WorkEntry, on key: String) -> YouTrackRequest {
        post(
            "issues/\(escaped(key))/timeTracking/workItems/\(escaped(itemID))",
            fields: workItemFields,
            body: workBody(entry, clearsType: true)
        )
    }

    static func deleteWork(_ itemID: String, on key: String) -> YouTrackRequest {
        YouTrackRequest(
            method: .delete,
            path: "issues/\(escaped(key))/timeTracking/workItems/\(escaped(itemID))",
            query: [],
            body: nil
        )
    }

    private static func workBody(_ entry: WorkEntry, clearsType: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "duration": ["minutes": entry.minutes],
            "date": milliseconds(entry.date),
            "text": entry.text,
        ]
        if let typeID = entry.typeID {
            body["type"] = ["id": typeID]
        } else if clearsType {
            body["type"] = NSNull()
        }
        return body
    }

    /// Sets one field to one value, as a move between columns does.
    static func setColumn(
        of key: String,
        field: String,
        wireType: String,
        value: String
    ) -> YouTrackRequest {
        let bare = TrackerField(name: field, kind: kind(of: wireType), allowsSeveral: allowsSeveral(wireType), wireType: wireType)
        let option = FieldOption(id: value, name: value, login: value)
        return post(
            "issues/\(escaped(key))",
            fields: cardFields,
            body: ["customFields": [fieldJSON(FieldChange(field: bare, values: [option]))]]
        )
    }

    static func update(_ key: String, with change: IssueChange) -> YouTrackRequest {
        var body: [String: Any] = [:]
        if let summary = change.summary { body["summary"] = summary }
        if let description = change.description { body["description"] = description }
        if !change.fields.isEmpty { body["customFields"] = change.fields.map(fieldJSON) }
        return post("issues/\(escaped(key))", fields: issueFields, body: body)
    }

    static func create(_ draft: IssueDraft) -> YouTrackRequest {
        post("issues", fields: cardFields, body: [
            "project": ["id": draft.project.id],
            "summary": draft.summary,
            "description": draft.description,
        ])
    }

    /// Puts an issue on a board that is filled by hand.
    static func addToSprint(issueID: String, sprintID: String, boardID: String) -> YouTrackRequest {
        post(
            "agiles/\(escaped(boardID))/sprints/\(escaped(sprintID))/issues",
            fields: "id",
            body: ["id": issueID, "$type": "Issue"]
        )
    }

    /// One field as a write names it: by name, with its kind repeated back,
    /// and each value by the name the tracker gave it — a person by login.
    static func fieldJSON(_ change: FieldChange) -> [String: Any] {
        let field = change.field
        func value(_ option: FieldOption) -> [String: Any] {
            field.kind == .user ? ["login": option.login ?? option.name] : ["name": option.name]
        }
        let written: Any
        if field.allowsSeveral {
            written = change.values.map(value)
        } else if let first = change.values.first {
            written = value(first)
        } else {
            written = NSNull()
        }
        return ["name": field.name, "$type": field.wireType, "value": written]
    }

    // MARK: - Field kinds

    /// What kind of field a `$type` describes. The single and multiple forms
    /// share a stem — `SingleEnumIssueCustomField`, `MultiEnumIssueCustomField`.
    static func kind(of wireType: String) -> FieldKind {
        if wireType.contains("User") { return .user }
        if wireType.contains("Period") { return .period }
        if wireType.contains("Date") { return .date }
        if wireType.hasPrefix("Text") { return .text }
        if wireType.hasPrefix("Simple") { return .other }
        let listed = ["Enum", "State", "Owned", "Version", "Build", "Group"]
        return listed.contains(where: wireType.contains) ? .option : .other
    }

    static func allowsSeveral(_ wireType: String) -> Bool {
        wireType.hasPrefix("Multi")
    }

    // MARK: - Building

    private static func get(_ path: String, fields: String, top: String? = nil) -> YouTrackRequest {
        var query = [URLQueryItem(name: "fields", value: fields)]
        if let top { query.append(URLQueryItem(name: "$top", value: top)) }
        return YouTrackRequest(method: .get, path: path, query: query, body: nil)
    }

    private static func post(_ path: String, fields: String, body: [String: Any]) -> YouTrackRequest {
        let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return YouTrackRequest(
            method: .post,
            path: path,
            query: [URLQueryItem(name: "fields", value: fields)],
            body: data
        )
    }

    static func escaped(_ segment: String) -> String {
        segment.addingPercentEncoding(withAllowedCharacters: .urlPathSegmentAllowed) ?? segment
    }

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }
}

private extension CharacterSet {
    /// What may stand in one path segment unescaped: a slash may not.
    static let urlPathSegmentAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return allowed
    }()
}
