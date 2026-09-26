import Foundation
import Testing

@testable import RelayTracker

/// Answers in the shape YouTrack gives them: `$type` on every entity, values
/// that are objects for one kind of field and numbers for another, and the
/// fields a request did not name simply absent.
enum YouTrackFixtures {
    static let boards = """
    [
      {
        "id": "108-4",
        "name": "Website",
        "projects": [{"id": "0-3", "shortName": "WEB", "name": "Website", "$type": "Project"}],
        "sprintsSettings": {"disableSprints": false, "isExplicit": true, "$type": "SprintsSettings"},
        "colorCoding": {"prototype": {"name": "Priority", "$type": "CustomField"}, "$type": "FieldBasedColorCoding"},
        "currentSprint": {"id": "109-8", "name": "Sprint 3", "$type": "Sprint"},
        "sprints": [
          {"id": "109-7", "name": "Sprint 2", "archived": true, "start": 1540000000000, "finish": 1541000000000, "$type": "Sprint"},
          {"id": "109-8", "name": "Sprint 3", "archived": false, "start": 1541372400000, "finish": 1542582000000, "$type": "Sprint"}
        ],
        "columnSettings": {
          "field": {"name": "State", "$type": "CustomField"},
          "columns": [
            {"id": "c3", "presentation": "Done", "isResolved": true, "ordinal": 2, "wipLimit": null,
             "fieldValues": [{"name": "Fixed", "isResolved": true}, {"name": "Verified", "isResolved": true}]},
            {"id": "c1", "presentation": "Open", "isResolved": false, "ordinal": 0, "wipLimit": null,
             "fieldValues": [{"name": "Open", "isResolved": false}]},
            {"id": "c2", "presentation": "In Progress", "isResolved": false, "ordinal": 1, "wipLimit": {"max": 3},
             "fieldValues": [{"name": "In Progress", "isResolved": false}]}
          ],
          "$type": "ColumnSettings"
        },
        "$type": "Agile"
      },
      {
        "id": "108-9",
        "name": "Apps kanban",
        "projects": [{"id": "0-5", "shortName": "APP", "name": "Apps"}],
        "sprintsSettings": {"disableSprints": true, "isExplicit": false},
        "colorCoding": {"$type": "ProjectBasedColorCoding"},
        "currentSprint": null,
        "sprints": [{"id": "109-20", "name": "Default", "archived": false}],
        "columnSettings": {"field": {"name": "Stage"}, "columns": []}
      }
    ]
    """

    static let sprint = """
    {
      "id": "109-8",
      "name": "Sprint 3",
      "archived": false,
      "start": 1541372400000,
      "finish": 1542582000000,
      "issues": [
        {
          "id": "2-35",
          "idReadable": "WEB-342",
          "summary": "Login redirects to a blank page",
          "updated": 1541400000000,
          "resolved": null,
          "project": {"id": "0-3", "shortName": "WEB", "name": "Website"},
          "tags": [{"name": "frontend", "color": {"background": "#e5f6ff", "foreground": "#0070b8"}}],
          "customFields": [
            {"name": "State", "$type": "StateIssueCustomField",
             "value": {"id": "67-2", "name": "In Progress", "localizedName": "В работе", "isResolved": false,
                       "color": {"background": "#fed74a", "foreground": "#444"}, "$type": "StateBundleElement"}},
            {"name": "Priority", "$type": "SingleEnumIssueCustomField",
             "value": {"id": "65-1", "name": "Major", "localizedName": null,
                       "color": {"background": "#e30000", "foreground": "#fff"}, "$type": "EnumBundleElement"}},
            {"name": "Assignee", "$type": "SingleUserIssueCustomField",
             "value": {"id": "1-2", "login": "jane", "fullName": "Jane Doe",
                       "avatarUrl": "/hub/api/rest/avatar/abc?s=48", "$type": "User"}},
            {"name": "Estimation", "$type": "PeriodIssueCustomField",
             "value": {"id": "p", "minutes": 150, "presentation": "2h 30m", "$type": "PeriodValue"}},
            {"name": "Due Date", "$type": "DateIssueCustomField", "value": 1542582000000},
            {"name": "Fix versions", "$type": "MultiVersionIssueCustomField",
             "value": [{"id": "v1", "name": "1.0"}, {"id": "v2", "name": "1.1"}]}
          ]
        },
        {
          "id": "2-36",
          "idReadable": "WEB-343",
          "summary": "Done already",
          "updated": 1541300000000,
          "resolved": 1541350000000,
          "project": {"id": "0-3", "shortName": "WEB", "name": "Website"},
          "customFields": [
            {"name": "State", "$type": "StateIssueCustomField", "value": {"id": "67-5", "name": "Verified", "isResolved": true}},
            {"name": "Assignee", "$type": "SingleUserIssueCustomField", "value": null}
          ]
        },
        {
          "id": "2-37",
          "idReadable": "WEB-344",
          "summary": "In a state no column holds",
          "project": {"id": "0-3", "shortName": "WEB", "name": "Website"},
          "customFields": [
            {"name": "State", "$type": "StateIssueCustomField", "value": {"id": "67-9", "name": "Won't fix"}}
          ]
        }
      ]
    }
    """

    static let issue = """
    {
      "id": "2-35",
      "idReadable": "WEB-342",
      "summary": "Login redirects to a blank page",
      "description": "Steps:\\n1. Log in\\n2. See nothing",
      "created": 1541000000000,
      "updated": 1541400000000,
      "resolved": null,
      "project": {"id": "0-3", "shortName": "WEB", "name": "Website"},
      "reporter": {"id": "1-3", "login": "max", "fullName": ""},
      "updater": {"id": "1-4", "login": "jane", "fullName": "Jane Doe"},
      "tags": [],
      "attachments": [
        {"id": "74-1", "name": "Screenshot 2026-09-23 at 13.13.59.png", "url": "/api/files/74-1?sign=abc&updated=1",
         "thumbnailURL": "/api/files/74-1?sign=abc&updated=1&thumb=true", "mimeType": "image/png", "size": 1024,
         "removed": false},
        {"id": "74-2", "name": "old.log", "url": "/api/files/74-2?sign=def", "mimeType": "text/plain", "removed": true},
        {"id": "74-3", "name": "notes.pdf", "url": "/api/files/74-3?sign=ghi", "removed": false}
      ],
      "customFields": [
        {"name": "Priority", "$type": "SingleEnumIssueCustomField",
         "value": {"id": "65-1", "name": "Major"},
         "projectCustomField": {"canBeEmpty": false, "emptyFieldText": "No priority",
           "bundle": {"values": [
             {"id": "65-0", "name": "Critical", "color": {"background": "#e30000", "foreground": "#fff"}},
             {"id": "65-1", "name": "Major"},
             {"id": "65-2", "name": "Minor", "localizedName": "Низкий"}
           ], "$type": "EnumBundle"}, "$type": "EnumProjectCustomField"}},
        {"name": "Assignee", "$type": "SingleUserIssueCustomField",
         "value": null,
         "projectCustomField": {"canBeEmpty": true, "emptyFieldText": "Unassigned",
           "bundle": {"aggregatedUsers": [
             {"id": "1-2", "login": "jane", "fullName": "Jane Doe"},
             {"id": "1-3", "login": "max", "fullName": null}
           ], "$type": "UserBundle"}, "$type": "UserProjectCustomField"}},
        {"name": "Spent time", "$type": "PeriodIssueCustomField",
         "value": {"minutes": 95},
         "projectCustomField": {"canBeEmpty": true, "$type": "PeriodProjectCustomField"}},
        {"name": "Notes", "$type": "TextIssueCustomField",
         "value": {"text": "Seen on Safari only", "$type": "TextFieldValue"}},
        {"name": "Story points", "$type": "SimpleIssueCustomField", "value": 5}
      ]
    }
    """

    static let comments = """
    [
      {"id": "4-2", "text": "Second", "created": 1541300000000, "author": {"id": "1-2", "login": "jane", "fullName": "Jane Doe"}},
      {"id": "4-1", "text": "First", "created": 1541200000000, "author": null}
    ]
    """

    static let workItems = """
    [
      {"id": "w1", "date": 1541200000000, "text": "Reproduced", "duration": {"minutes": 30, "$type": "DurationValue"},
       "author": {"id": "1-2", "login": "jane", "fullName": "Jane Doe"}, "type": {"id": "65-0", "name": "Development"}},
      {"id": "w2", "date": 1541300000000, "text": null, "duration": {"minutes": 65}, "author": null, "type": null}
    ]
    """

    static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}

@Suite("Reading YouTrack's answers")
struct YouTrackMappingTests {
    private func boards() throws -> [TrackerBoard] {
        try YouTrackFixtures.decode([YouTrackWire.Board].self, YouTrackFixtures.boards).map(YouTrackMapping.board)
    }

    private func snapshot() throws -> BoardSnapshot {
        let wire = try YouTrackFixtures.decode([YouTrackWire.Board].self, YouTrackFixtures.boards)[0]
        let sprint = try YouTrackFixtures.decode(YouTrackWire.Sprint.self, YouTrackFixtures.sprint)
        return YouTrackMapping.snapshot(
            of: YouTrackMapping.board(wire),
            settings: wire.columnSettings,
            sprint: sprint
        )
    }

    @Test("A board says whether it has sprints and how its cards get onto it")
    func boardsAreRead() throws {
        let read = try boards()
        #expect(read.map(\.name) == ["Website", "Apps kanban"])
        #expect(read[0].usesSprints)
        #expect(read[0].addsCardsByHand)
        #expect(read[0].currentSprintID == "109-8")
        #expect(read[0].projects == [TrackerProject(id: "0-3", key: "WEB", name: "Website")])
        #expect(read[0].openSprints(including: nil).map(\.name) == ["Sprint 3"])
        #expect(read[0].openSprints(including: "109-7").map(\.name) == ["Sprint 2", "Sprint 3"])
        #expect(!read[1].usesSprints)
        #expect(!read[1].addsCardsByHand)
        #expect(read[1].currentSprintID == nil)
    }

    @Test("A board says which field colours its cards, and only when a field does")
    func colorField() throws {
        let read = try boards()
        #expect(read[0].colorField == "Priority")
        #expect(read[1].colorField == nil)
    }

    @Test("A person's picture is kept as the tracker wrote it")
    func avatars() throws {
        #expect(try snapshot().cards[0].assignee?.avatar == "/hub/api/rest/avatar/abc?s=48")
        #expect(try snapshot().cards[0].assignee?.user?.avatar == "/hub/api/rest/avatar/abc?s=48")
    }

    @Test("An issue's files are read, and a removed one is not among them")
    func attachments() throws {
        let issue = YouTrackMapping.issue(try YouTrackFixtures.decode(YouTrackWire.Issue.self, YouTrackFixtures.issue))
        #expect(issue.attachments.map(\.name) == ["Screenshot 2026-09-23 at 13.13.59.png", "notes.pdf"])
        #expect(issue.attachments[0].isImage)
        #expect(!issue.attachments[1].isImage)
        #expect(issue.attachment(named: "Screenshot%202026-09-23%20at%2013.13.59.png")?.id == "74-1")
        #expect(issue.attachment(named: "Screenshot 2026-09-23 at 13.13.59.png")?.id == "74-1")
        #expect(issue.attachment(named: "old.log") == nil)
    }

    @Test("A board without a current sprint shows its newest open one")
    func sprintToShow() throws {
        let read = try boards()
        #expect(YouTrackTracker.sprintToShow(on: read[0]) == "109-8")
        #expect(YouTrackTracker.sprintToShow(on: read[1]) == "109-20")
        #expect(YouTrackTracker.sprintToShow(on: TrackerBoard(id: "x", name: "Empty")) == nil)
    }

    @Test("Columns come left to right, merged ones holding every value")
    func columnsInOrder() throws {
        let board = try snapshot()
        #expect(board.columnField == "State")
        #expect(board.columns.map(\.title) == ["Open", "In Progress", "Done"])
        #expect(board.columns[1].limit == 3)
        #expect(board.columns[2].values == ["Fixed", "Verified"])
        #expect(board.columns[2].isResolved)
    }

    @Test("A card is in the column its value names, and in none when no column holds it")
    func cardsFindTheirColumns() throws {
        let board = try snapshot()
        #expect(board.cards.map(\.key) == ["WEB-342", "WEB-343", "WEB-344"])
        #expect(board.cards(in: board.columns[1]).map(\.key) == ["WEB-342"])
        #expect(board.cards(in: board.columns[2]).map(\.key) == ["WEB-343"])
        #expect(board.column(of: board.cards[2]) == nil)
    }

    @Test("Values are shown in the tracker's translation and written by their own name")
    func localizedNames() throws {
        let card = try snapshot().cards[0]
        let state = try #require(card.field(named: "State")?.values.first)
        #expect(state.name == "In Progress")
        #expect(state.title == "В работе")
        #expect(state.color == TrackerColor(background: "#fed74a", foreground: "#444"))
        // A `null` translation is no translation.
        #expect(card.field(named: "Priority")?.values.first?.title == "Major")
    }

    @Test("Each kind of value lands where its kind puts it")
    func valuesByKind() throws {
        let card = try snapshot().cards[0]
        #expect(card.assignee?.login == "jane")
        #expect(card.assignee?.title == "Jane Doe")
        #expect(card.field(named: "Estimation")?.text == "2h 30m")
        #expect(card.field(named: "Due Date")?.date == Date(timeIntervalSince1970: 1_542_582_000))
        #expect(card.field(named: "Fix versions")?.values.map(\.name) == ["1.0", "1.1"])
        #expect(card.field(named: "Fix versions")?.allowsSeveral == true)
        #expect(card.tags == [TrackerTag(name: "frontend", color: TrackerColor(background: "#e5f6ff", foreground: "#0070b8"))])
        #expect(!card.isResolved)
        #expect(try snapshot().cards[1].isResolved)
        #expect(try snapshot().cards[1].assignee == nil)
    }

    @Test("Placing a card moves it before the tracker answers")
    func placing() throws {
        var board = try snapshot()
        let card = board.cards[0]
        board.place(card, in: board.columns[0])
        #expect(board.cards(in: board.columns[0]).map(\.key) == ["WEB-342"])
        #expect(board.cards[0].field(named: "State")?.values.first?.name == "Open")
        // The other fields are left alone.
        #expect(board.cards[0].assignee?.login == "jane")
    }

    @Test("A card without the board's field is given it, of the kind the others have")
    func placingWithoutTheField() throws {
        var board = try snapshot()
        board.cards[2].fields = []
        board.place(board.cards[2], in: board.columns[0])
        let field = try #require(board.cards[2].field(named: "State"))
        #expect(field.wireType == "StateIssueCustomField")
        #expect(board.column(of: board.cards[2])?.id == "c1")
    }

    @Test("An issue read in full knows what each field could be")
    func optionsAreRead() throws {
        let issue = YouTrackMapping.issue(try YouTrackFixtures.decode(YouTrackWire.Issue.self, YouTrackFixtures.issue))
        #expect(issue.description == "Steps:\n1. Log in\n2. See nothing")
        #expect(issue.reporter == TrackerUser(id: "1-3", login: "max", name: "max"))
        #expect(issue.updater == TrackerUser(id: "1-4", login: "jane", name: "Jane Doe"))

        let priority = try #require(issue.field(named: "Priority"))
        #expect(priority.options.map(\.title) == ["Critical", "Major", "Низкий"])
        #expect(priority.options.map(\.name) == ["Critical", "Major", "Minor"])
        #expect(!priority.canBeEmpty)
        #expect(priority.isEditable)

        let assignee = try #require(issue.field(named: "Assignee"))
        #expect(assignee.values.isEmpty)
        #expect(assignee.emptyText == "Unassigned")
        #expect(assignee.options.map(\.title) == ["Jane Doe", "max"])
        #expect(assignee.options.map(\.login) == ["jane", "max"])

        let spent = try #require(issue.field(named: "Spent time"))
        #expect(spent.text == "1h 35m")
        #expect(!spent.isEditable)
        #expect(issue.field(named: "Notes")?.text == "Seen on Safari only")
        #expect(issue.field(named: "Story points")?.text == "5")
    }

    @Test("An issue put back on a board carries no lists of options")
    func issueAsCard() throws {
        let issue = YouTrackMapping.issue(try YouTrackFixtures.decode(YouTrackWire.Issue.self, YouTrackFixtures.issue))
        let card = issue.card
        #expect(card.key == "WEB-342")
        #expect(card.fields.allSatisfy { $0.options.isEmpty })
        #expect(card.field(named: "Priority")?.values.first?.name == "Major")
    }

    @Test("Comments and time are read, missing authors and all")
    func conversationAndTime() throws {
        let comments = try YouTrackFixtures.decode([YouTrackWire.Comment].self, YouTrackFixtures.comments)
            .map(YouTrackMapping.comment)
        #expect(comments.map(\.text) == ["Second", "First"])
        #expect(comments[1].author == nil)

        let work = try YouTrackFixtures.decode([YouTrackWire.WorkItem].self, YouTrackFixtures.workItems)
            .map(YouTrackMapping.workItem)
        #expect(work.map(\.minutes) == [30, 65])
        #expect(work[0].type == TrackerWorkType(id: "65-0", name: "Development"))
        #expect(work[1].text == "")
    }

    @Test("A project that does not track time has no kinds of work")
    func workTypes() throws {
        let off = try YouTrackFixtures.decode(
            YouTrackWire.TimeTrackingSettings.self,
            #"{"enabled": false, "workItemTypes": [{"id": "65-0", "name": "Development"}]}"#
        )
        #expect(YouTrackMapping.workTypes(off).isEmpty)
        let on = try YouTrackFixtures.decode(
            YouTrackWire.TimeTrackingSettings.self,
            #"{"enabled": true, "workItemTypes": [{"id": "65-0", "name": "Development"}]}"#
        )
        #expect(YouTrackMapping.workTypes(on) == [TrackerWorkType(id: "65-0", name: "Development")])
    }
}

@Suite("YouTrack's refusals")
struct YouTrackFailureTests {
    private func failure(_ status: Int, _ body: String = "", location: String? = nil, write: Bool = false) -> TrackerError {
        YouTrackMapping.failure(status: status, body: Data(body.utf8), location: location, isWrite: write)
    }

    @Test("Each status says what went wrong")
    func statuses() {
        #expect(failure(401).kind == .unauthorized)
        #expect(failure(403).kind == .forbidden)
        #expect(failure(404).kind == .notFound)
        #expect(failure(429).kind == .rateLimited)
        #expect(failure(400).kind == .rejected)
        #expect(failure(302, location: "https://elsewhere.example/").kind == .redirected(to: "https://elsewhere.example/"))
    }

    @Test("A server failure during a write leaves the write in doubt")
    func writesInDoubt() {
        #expect(failure(503).kind == .serverFailure(status: 503))
        #expect(failure(503).isTransient)
        #expect(failure(500, write: true).kind == .uncertain)
        #expect(!failure(500, write: true).isTransient)
    }

    @Test("What YouTrack said is kept, on one line")
    func messages() {
        let said = failure(400, #"{"error": "bad_request", "error_description": "Unknown workflow\n  transition"}"#)
        #expect(said.message == "Unknown workflow transition")
        #expect(failure(400, #"{"error": "bad_request"}"#).message == "bad_request")
        #expect(failure(400, "<html>nope</html>").message == nil)
    }
}
