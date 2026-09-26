import Foundation
import Testing

@testable import RelayTracker

@Suite("YouTrack addresses")
struct YouTrackAddressTests {
    @Test("What people paste becomes the instance's own address", arguments: [
        ("https://studio.youtrack.cloud", "https://studio.youtrack.cloud"),
        ("studio.youtrack.cloud", "https://studio.youtrack.cloud"),
        ("https://studio.youtrack.cloud/", "https://studio.youtrack.cloud"),
        ("https://studio.youtrack.cloud/api", "https://studio.youtrack.cloud"),
        ("https://studio.youtrack.cloud/api/", "https://studio.youtrack.cloud"),
        ("https://studio.youtrack.cloud/issue/WEB-342", "https://studio.youtrack.cloud"),
        ("https://studio.youtrack.cloud/agiles/108-4/current", "https://studio.youtrack.cloud"),
        ("https://studio.youtrack.cloud/dashboard?id=1#top", "https://studio.youtrack.cloud"),
        ("https://tracker.example.com/youtrack/issues", "https://tracker.example.com/youtrack"),
        ("HTTPS://Tracker.Example.com/youtrack/", "https://Tracker.Example.com/youtrack"),
        ("http://localhost:8080", "http://localhost:8080"),
    ])
    func normalised(typed: String, expected: String) {
        #expect(YouTrackConnection.address(from: typed)?.absoluteString == expected)
    }

    @Test("A token is never sent in the clear, nor beside a password", arguments: [
        "", "   ", "http://studio.youtrack.cloud", "ftp://studio.youtrack.cloud",
        "https://user:secret@studio.youtrack.cloud", "https://",
    ])
    func refused(typed: String) {
        #expect(YouTrackConnection.address(from: typed) == nil)
    }
}

@Suite("YouTrack requests")
struct YouTrackRequestTests {
    private let connection = YouTrackConnection(
        baseURL: URL(string: "https://tracker.example.com/youtrack")!,
        token: "perm:abc"
    )

    private func body(_ request: YouTrackRequest) throws -> [String: Any] {
        let data = try #require(request.body)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func query(_ request: YouTrackRequest, _ name: String) -> String? {
        request.query.first { $0.name == name }?.value
    }

    @Test("The API is below the instance's own path, with the token as a bearer")
    func addressesAndAuthorises() throws {
        let request = YouTrackAPI.currentUser().urlRequest(for: connection, timeout: 5)
        let url = try #require(request.url)
        #expect(url.path == "/youtrack/api/users/me")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer perm:abc")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.httpMethod == "GET")
        #expect(request.timeoutInterval == 5)
    }

    @Test("A field list survives the query string intact")
    func fieldsAreNotMangled() throws {
        let request = YouTrackAPI.issue("WEB-342").urlRequest(for: connection, timeout: 5)
        let components = try #require(URLComponents(url: request.url!, resolvingAgainstBaseURL: false))
        let fields = try #require(components.queryItems?.first { $0.name == "fields" }?.value)
        #expect(fields == YouTrackAPI.issueFields)
        #expect(fields.contains("customFields(name,$type,"))
    }

    @Test("Lists ask for more than YouTrack's default of forty-two")
    func listsAreNotCutShort() {
        #expect(query(YouTrackAPI.boards(), "$top") == YouTrackAPI.listLimit)
        #expect(query(YouTrackAPI.comments(on: "WEB-1"), "$top") == YouTrackAPI.listLimit)
        #expect(query(YouTrackAPI.workItems(on: "WEB-1"), "$top") == YouTrackAPI.listLimit)
    }

    @Test("An identifier is one path segment, whatever is in it")
    func escapesSegments() {
        #expect(YouTrackAPI.issue("WEB-342").path == "issues/WEB-342")
        #expect(YouTrackAPI.sprint("109-8", of: "108/4").path == "agiles/108%2F4/sprints/109-8")
    }

    @Test("Moving a card sets the board's field by name, with its kind repeated back")
    func moveBody() throws {
        let request = YouTrackAPI.setColumn(
            of: "WEB-342",
            field: "State",
            wireType: "StateIssueCustomField",
            value: "In Progress"
        )
        #expect(request.method == .post)
        #expect(request.path == "issues/WEB-342")
        let fields = try #require(try body(request)["customFields"] as? [[String: Any]])
        #expect(fields.count == 1)
        #expect(fields[0]["name"] as? String == "State")
        #expect(fields[0]["$type"] as? String == "StateIssueCustomField")
        #expect((fields[0]["value"] as? [String: String]) == ["name": "In Progress"])
    }

    @Test("A person is written by login, several values as a list, none as null")
    func fieldValues() throws {
        let assignee = TrackerField(name: "Assignee", kind: .user, wireType: "SingleUserIssueCustomField")
        let jane = FieldOption(id: "1-2", name: "jane", title: "Jane Doe", login: "jane")
        let written = YouTrackAPI.fieldJSON(FieldChange(field: assignee, values: [jane]))
        #expect((written["value"] as? [String: String]) == ["login": "jane"])

        let versions = TrackerField(
            name: "Fix versions",
            kind: .option,
            allowsSeveral: true,
            wireType: "MultiVersionIssueCustomField"
        )
        let several = YouTrackAPI.fieldJSON(FieldChange(field: versions, values: [
            FieldOption(id: "a", name: "1.0"), FieldOption(id: "b", name: "1.1"),
        ]))
        #expect((several["value"] as? [[String: String]]) == [["name": "1.0"], ["name": "1.1"]])

        let cleared = YouTrackAPI.fieldJSON(FieldChange(field: assignee, values: []))
        #expect(cleared["value"] is NSNull)
    }

    @Test("An edit sends only what changed")
    func updateBody() throws {
        let summaryOnly = try body(YouTrackAPI.update("WEB-1", with: IssueChange(summary: "New title")))
        #expect(summaryOnly.keys.sorted() == ["summary"])

        let priority = TrackerField(name: "Priority", kind: .option, wireType: "SingleEnumIssueCustomField")
        let everything = try body(YouTrackAPI.update("WEB-1", with: IssueChange(
            summary: "T",
            description: "D",
            fields: [FieldChange(field: priority, values: [FieldOption(id: "p", name: "Major")])]
        )))
        #expect(everything.keys.sorted() == ["customFields", "description", "summary"])
    }

    @Test("Time is logged in minutes on a day given in milliseconds")
    func workBody() throws {
        let day = Date(timeIntervalSince1970: 1_539_000_000)
        let written = try body(YouTrackAPI.logWork(
            WorkEntry(minutes: 95, date: day, text: "Reviewed", typeID: "65-0"),
            on: "WEB-1"
        ))
        #expect((written["duration"] as? [String: Int]) == ["minutes": 95])
        #expect((written["date"] as? NSNumber)?.int64Value == 1_539_000_000_000)
        #expect(written["text"] as? String == "Reviewed")
        #expect((written["type"] as? [String: String]) == ["id": "65-0"])

        let untyped = try body(YouTrackAPI.logWork(WorkEntry(minutes: 5, date: day), on: "WEB-1"))
        #expect(untyped["type"] == nil)
    }

    @Test("A comment is corrected by writing its text, and deleted by marking it so")
    func commentChanges() throws {
        let edit = YouTrackAPI.updateComment("4-1", text: "Fixed", on: "WEB-1")
        #expect(edit.method == .post)
        #expect(edit.path == "issues/WEB-1/comments/4-1")
        #expect(try body(edit) as? [String: String] == ["text": "Fixed"])

        // Marked, not erased: YouTrack's own delete leaves it restorable, and
        // a `DELETE` of a comment removes it from the database for good.
        let removal = YouTrackAPI.deleteComment("4-1", on: "WEB-1")
        #expect(removal.method == .post)
        #expect(removal.path == "issues/WEB-1/comments/4-1")
        #expect(try body(removal)["deleted"] as? Bool == true)
    }

    @Test("Correcting time writes every part of it, a kind taken away as none")
    func workChanges() throws {
        let day = Date(timeIntervalSince1970: 1_539_000_000)
        let edit = YouTrackAPI.updateWork("w1", with: WorkEntry(minutes: 45, date: day, text: "Less"), on: "WEB-1")
        #expect(edit.method == .post)
        #expect(edit.path == "issues/WEB-1/timeTracking/workItems/w1")
        let written = try body(edit)
        #expect((written["duration"] as? [String: Int]) == ["minutes": 45])
        #expect(written["type"] is NSNull)

        let typed = try body(YouTrackAPI.updateWork("w1", with: WorkEntry(minutes: 45, date: day, typeID: "65-1"), on: "WEB-1"))
        #expect((typed["type"] as? [String: String]) == ["id": "65-1"])

        let removal = YouTrackAPI.deleteWork("w1", on: "WEB-1")
        #expect(removal.method == .delete)
        #expect(removal.isWrite)
        #expect(removal.path == "issues/WEB-1/timeTracking/workItems/w1")
        #expect(removal.body == nil)
    }

    @Test("A new issue names its project by the tracker's identifier, not its key")
    func createBody() throws {
        let project = TrackerProject(id: "0-3", key: "WEB", name: "Website")
        let written = try body(YouTrackAPI.create(IssueDraft(project: project, summary: "S", description: "D")))
        #expect((written["project"] as? [String: String]) == ["id": "0-3"])
        #expect(written["summary"] as? String == "S")
    }

    @Test("A command names a value with spaces in braces, and drops braces from it")
    func commandQueries() {
        #expect(YouTrackAPI.commandQuery(field: "State", value: "In Progress") == "State {In Progress}")
        #expect(YouTrackAPI.commandQuery(field: "Kanban State", value: "Done") == "Kanban State {Done}")
        #expect(YouTrackAPI.commandQuery(field: "State", value: "Odd {name}") == "State {Odd name}")
    }

    @Test("Field kinds are read off the type YouTrack names", arguments: [
        ("StateIssueCustomField", FieldKind.option, false),
        ("StateMachineIssueCustomField", .option, false),
        ("SingleEnumIssueCustomField", .option, false),
        ("MultiEnumIssueCustomField", .option, true),
        ("SingleOwnedIssueCustomField", .option, false),
        ("MultiVersionIssueCustomField", .option, true),
        ("SingleUserIssueCustomField", .user, false),
        ("MultiUserIssueCustomField", .user, true),
        ("PeriodIssueCustomField", .period, false),
        ("DateIssueCustomField", .date, false),
        ("TextIssueCustomField", .text, false),
        ("SimpleIssueCustomField", .other, false),
    ])
    func kinds(wireType: String, kind: FieldKind, several: Bool) {
        #expect(YouTrackAPI.kind(of: wireType) == kind)
        #expect(YouTrackAPI.allowsSeveral(wireType) == several)
    }
}
