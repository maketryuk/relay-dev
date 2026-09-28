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
         "projectCustomField": {"field": {"localizedName": "Приоритет", "$type": "CustomField"},
           "canBeEmpty": false, "emptyFieldText": "No priority",
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
         "projectCustomField": {"field": {"localizedName": null, "$type": "CustomField"},
           "canBeEmpty": true, "$type": "PeriodProjectCustomField"}},
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

    /// One issue of a project, read for its fields as a new issue would have
    /// them: its own values beside the project's defaults, which are what
    /// counts. Shaped after a live answer, with names of its own.
    static let newIssueFields = """
    [
      {
        "id": "2-35",
        "customFields": [
          {"name": "State", "$type": "StateIssueCustomField",
           "value": {"id": "67-2", "name": "In Progress", "$type": "StateBundleElement"},
           "projectCustomField": {"field": {"localizedName": "Статус"}, "canBeEmpty": false, "emptyFieldText": "No state",
             "defaultValues": [{"id": "67-0", "name": "Open", "localizedName": "Открыта", "$type": "StateBundleElement"}],
             "bundle": {"values": [{"id": "67-0", "name": "Open", "localizedName": "Открыта"},
                                   {"id": "67-2", "name": "In Progress", "localizedName": "В работе"}]},
             "$type": "StateProjectCustomField"}},
          {"name": "Assignee", "$type": "SingleUserIssueCustomField",
           "value": {"id": "1-2", "login": "jane", "fullName": "Jane Doe", "$type": "User"},
           "projectCustomField": {"field": {"localizedName": "Исполнитель"}, "canBeEmpty": true, "emptyFieldText": "Unassigned",
             "defaultValues": [],
             "bundle": {"aggregatedUsers": [{"id": "1-2", "login": "jane", "fullName": "Jane Doe"},
                                            {"id": "1-3", "login": "max", "fullName": "Max Kay"}]},
             "$type": "UserProjectCustomField"}},
          {"name": "Участники", "$type": "MultiUserIssueCustomField",
           "value": [{"id": "1-3", "login": "max", "fullName": "Max Kay", "$type": "User"}],
           "projectCustomField": {"field": {}, "canBeEmpty": true, "emptyFieldText": "Нет: участники",
             "defaultValues": [{"id": "1-2", "login": "jane", "fullName": "Jane Doe", "$type": "User"}],
             "bundle": {"aggregatedUsers": [{"id": "1-2", "login": "jane", "fullName": "Jane Doe"}]},
             "$type": "UserProjectCustomField"}},
          {"name": "Due Date", "$type": "DateIssueCustomField", "value": 1542582000000,
           "projectCustomField": {"field": {"localizedName": "Срок"}, "canBeEmpty": true, "emptyFieldText": "Нет: срок",
             "$type": "SimpleProjectCustomField"}},
          {"name": "Estimation", "$type": "PeriodIssueCustomField",
           "value": {"minutes": 150, "presentation": "2h 30m", "$type": "PeriodValue"},
           "projectCustomField": {"field": {}, "canBeEmpty": true, "emptyFieldText": "?", "$type": "PeriodProjectCustomField"}},
          {"name": "Spent time", "$type": "PeriodIssueCustomField",
           "value": {"minutes": 95, "presentation": "1h 35m", "$type": "PeriodValue"},
           "projectCustomField": {"field": {}, "canBeEmpty": true, "emptyFieldText": "?", "$type": "PeriodProjectCustomField"}},
          {"name": "Priority", "$type": "SingleEnumIssueCustomField",
           "value": {"id": "65-1", "name": "Major", "$type": "EnumBundleElement"},
           "projectCustomField": {"field": {"localizedName": "Приоритет"}, "canBeEmpty": false, "emptyFieldText": "No priority",
             "defaultValues": [{"id": "65-2", "name": "Normal", "color": {"background": "#e5f6ff", "foreground": "#0070b8"},
                                "$type": "EnumBundleElement"}],
             "bundle": {"values": [{"id": "65-1", "name": "Major"}, {"id": "65-2", "name": "Normal"}]},
             "$type": "EnumProjectCustomField"}},
          {"name": "Notes", "$type": "TextIssueCustomField", "value": {"text": "Seen on Safari only", "$type": "TextFieldValue"},
           "projectCustomField": {"field": {}, "canBeEmpty": true, "$type": "TextProjectCustomField"}}
        ]
      }
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

    @Test("A working week is read with Sunday counted either first or last")
    func workSchedule() {
        let weekdays = YouTrackMapping.workSchedule(.init(minutesADay: 420, workDays: [1, 2, 3, 4, 5]))
        #expect(weekdays == TrackerWorkSchedule(minutesADay: 420, workdays: [2, 3, 4, 5, 6]))
        #expect(YouTrackMapping.workSchedule(.init(minutesADay: 480, workDays: [6, 7])).workdays == [7, 1])
        #expect(YouTrackMapping.workSchedule(.init(minutesADay: 480, workDays: [0])).workdays == [1])
        // Nothing said is the ordinary week, not a week with no work in it.
        #expect(YouTrackMapping.workSchedule(.init(minutesADay: nil, workDays: nil)) == .standard)
    }

    @Test("A line of a timesheet needs the issue it was recorded on")
    func timeEntry() throws {
        let decoder = JSONDecoder()
        let wire = try decoder.decode(YouTrackWire.WorkItem.self, from: Data("""
        {"id": "w1", "date": 1790596800000, "duration": {"minutes": 30},
         "issue": {"idReadable": "WEB-1", "summary": "Login", "project": {"id": "0-3", "shortName": "WEB"}}}
        """.utf8))
        let entry = try #require(YouTrackMapping.timeEntry(wire))
        #expect(entry.issueKey == "WEB-1")
        #expect(entry.summary == "Login")
        #expect(entry.project?.key == "WEB")
        #expect(entry.item.minutes == 30)

        let orphan = try decoder.decode(YouTrackWire.WorkItem.self, from: Data(#"{"id": "w2"}"#.utf8))
        #expect(YouTrackMapping.timeEntry(orphan) == nil)
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
        // Shown translated, found and written by its own name.
        #expect(priority.title == "Приоритет")
        #expect(try #require(issue.field(named: "Spent time")).title == "Spent time")
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

    @Test("A new issue's fields start as the project starts them, with nothing of the issue they were read off")
    func newIssueFields() throws {
        let issue = try YouTrackFixtures.decode([YouTrackWire.Issue].self, YouTrackFixtures.newIssueFields)[0]
        let settings = try YouTrackFixtures.decode(
            YouTrackWire.TimeTrackingSettings.self,
            #"{"enabled": true, "timeSpent": {"field": {"name": "Spent time"}}}"#
        )
        let fields = YouTrackMapping.newIssueFields(of: issue, timeTracking: settings)
        // In the project's order, which is the order the tracker's form shows.
        #expect(fields.map(\.name) == ["State", "Assignee", "Участники", "Due Date", "Estimation", "Priority", "Notes"])

        let state = try #require(fields.first { $0.name == "State" })
        #expect(state.values.map(\.name) == ["Open"])
        #expect(state.values.map(\.title) == ["Открыта"])
        #expect(state.options.map(\.name) == ["Open", "In Progress"])

        let assignee = try #require(fields.first { $0.name == "Assignee" })
        #expect(assignee.values.isEmpty)
        #expect(assignee.title == "Исполнитель")
        #expect(assignee.options.map(\.login) == ["jane", "max"])
        #expect(assignee.isEditable)

        let participants = try #require(fields.first { $0.name == "Участники" })
        #expect(participants.allowsSeveral)
        #expect(participants.values.map(\.login) == ["jane"])

        let due = try #require(fields.first { $0.name == "Due Date" })
        #expect(due.kind == .date)
        #expect(due.date == nil)
        #expect(due.title == "Срок")
        #expect(due.emptyText == "Нет: срок")

        let estimate = try #require(fields.first { $0.name == "Estimation" })
        #expect(estimate.text == nil)
        #expect(estimate.isEmpty)

        let priority = try #require(fields.first { $0.name == "Priority" })
        #expect(priority.values.map(\.name) == ["Normal"])
        #expect(priority.values.first?.color == TrackerColor(background: "#e5f6ff", foreground: "#0070b8"))
        #expect(!priority.canBeEmpty)

        #expect(fields.first { $0.name == "Notes" }?.text == nil)
    }

    @Test("A length of time is offered only when it is known not to be the one the tracker adds up")
    func newIssueLengths() throws {
        let issue = try YouTrackFixtures.decode([YouTrackWire.Issue].self, YouTrackFixtures.newIssueFields)[0]
        func lengths(_ settings: String?) throws -> [String] {
            let read = try settings.map { try YouTrackFixtures.decode(YouTrackWire.TimeTrackingSettings.self, $0) }
            return YouTrackMapping.newIssueFields(of: issue, timeTracking: read).filter { $0.kind == .period }.map(\.name)
        }
        #expect(try lengths(#"{"enabled": true, "timeSpent": {"field": {"name": "Spent time"}}}"#) == ["Estimation"])
        // Not adding anything up, the field is a length like any other.
        #expect(try lengths(#"{"enabled": false, "timeSpent": {"field": {"name": "Spent time"}}}"#) == ["Estimation", "Spent time"])
        #expect(try lengths(#"{"enabled": true}"#) == ["Estimation", "Spent time"])
        #expect(try lengths(nil).isEmpty)
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
