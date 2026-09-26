import Foundation
import Testing

@testable import RelayTracker

/// Canned answers by path, and a record of what was asked.
///
/// The one stand-in in these tests, for the one thing they cannot have: a
/// YouTrack. Everything either side of it is the real code.
private final class CannedTransport: TrackerTransport, @unchecked Sendable {
    struct Answer {
        var status: Int
        var body: String
    }

    private let lock = NSLock()
    private var answers: [String: [Answer]]
    private(set) var sent: [URLRequest] = []

    init(_ answers: [String: [Answer]]) {
        self.answers = answers
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let key = "\(request.httpMethod ?? "GET") \(request.url!.path)"
        let answer: Answer? = lock.withLock {
            sent.append(request)
            guard var queue = answers[key], !queue.isEmpty else { return nil }
            let first = queue.removeFirst()
            // The last answer stands for every request after it.
            answers[key] = queue.isEmpty ? [first] : queue
            return first
        }
        guard let answer else { throw URLError(.cannotConnectToHost) }
        let response = HTTPURLResponse(url: request.url!, statusCode: answer.status, httpVersion: nil, headerFields: nil)!
        return (Data(answer.body.utf8), response)
    }

    var paths: [String] {
        lock.withLock { sent.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" } }
    }
}

@Suite("Talking to YouTrack")
struct YouTrackTrackerTests {
    private func tracker(_ answers: [String: [CannedTransport.Answer]]) -> (YouTrackTracker, CannedTransport) {
        let transport = CannedTransport(answers)
        let tracker = YouTrackTracker(
            connection: YouTrackConnection(baseURL: URL(string: "https://studio.youtrack.cloud")!, token: "perm:x"),
            transport: transport
        )
        return (tracker, transport)
    }

    private static let movedCard = """
    {"id": "2-35", "idReadable": "WEB-342", "summary": "Login", "project": {"id": "0-3", "shortName": "WEB"},
     "customFields": [{"name": "State", "$type": "StateIssueCustomField", "value": {"name": "Open"}}]}
    """

    @Test("A board is read with its columns and the cards of the sprint it shows")
    func readsABoard() async throws {
        let website = try #require(YouTrackFixtures.boards.firstJSONObject)
        let (tracker, transport) = tracker([
            "GET /api/agiles": [.init(status: 200, body: YouTrackFixtures.boards)],
            "GET /api/agiles/108-4": [.init(status: 200, body: website)],
            "GET /api/agiles/108-4/sprints/109-8": [.init(status: 200, body: YouTrackFixtures.sprint)],
        ])
        let board = try await tracker.boards()[1]
        #expect(board.name == "Website")
        let snapshot = try await tracker.snapshot(of: board, sprint: nil)
        #expect(snapshot.sprint?.name == "Sprint 3")
        #expect(snapshot.columns.count == 3)
        #expect(snapshot.cards.count == 3)
        #expect(transport.paths == ["GET /api/agiles", "GET /api/agiles/108-4", "GET /api/agiles/108-4/sprints/109-8"])
    }

    @Test("A move names the field with the kind the card has it as")
    func movesACard() async throws {
        let (tracker, transport) = tracker([
            "POST /api/issues/WEB-342": [.init(status: 200, body: Self.movedCard)],
        ])
        let card = TrackerCard(
            id: "2-35",
            key: "WEB-342",
            summary: "Login",
            project: TrackerProject(id: "0-3", key: "WEB", name: "Website"),
            fields: [TrackerField(name: "State", kind: .option, wireType: "SingleEnumIssueCustomField")]
        )
        let column = BoardColumn(id: "c1", title: "Open", values: ["Open"])
        let snapshot = BoardSnapshot(board: TrackerBoard(id: "b", name: "B"), columnField: "State", columns: [column], cards: [card])

        let moved = try await tracker.move(card, to: column, on: snapshot)
        #expect(moved.field(named: "State")?.values.first?.name == "Open")

        let sent = try #require(transport.sent.first?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        let field = try #require((body["customFields"] as? [[String: Any]])?.first)
        #expect(field["$type"] as? String == "SingleEnumIssueCustomField")
    }

    @Test("A refused token is not asked about again")
    func refusalIsNotRetried() async {
        let (tracker, transport) = tracker([
            "GET /api/users/me": [.init(status: 401, body: #"{"error": "Unauthorized"}"#)],
        ])
        await #expect(throws: TrackerError(.unauthorized, message: "Unauthorized")) {
            try await tracker.currentUser()
        }
        #expect(transport.sent.count == 1)
    }

    @Test("A write the server failed is reported as in doubt, and sent once")
    func writeIsSentOnce() async {
        let (tracker, transport) = tracker([
            "POST /api/issues/WEB-1/comments": [.init(status: 502, body: "")],
        ])
        await #expect(throws: TrackerError(.uncertain)) {
            try await tracker.addComment("Hello", on: "WEB-1")
        }
        #expect(transport.sent.count == 1)
    }

    @Test("A write that never reached the server is not in doubt")
    func unreachableWriteIsNotInDoubt() async {
        let (tracker, _) = tracker([:])
        await #expect(throws: TrackerError(.unreachable)) {
            try await tracker.addComment("Hello", on: "WEB-1")
        }
    }

    @Test("A page that is not the API is said to be one")
    func loginPageIsNotTheAPI() async {
        let (tracker, _) = tracker([
            "GET /api/users/me": [.init(status: 200, body: "<html><body>Log in</body></html>")],
        ])
        await #expect(throws: TrackerError(.notTheAPI)) {
            try await tracker.currentUser()
        }
    }

    @Test("A new card lands in its column, and on a board filled by hand is put on it")
    func createsIntoAColumn() async throws {
        let created = """
        {"id": "2-99", "idReadable": "WEB-400", "summary": "New", "project": {"id": "0-3", "shortName": "WEB"},
         "customFields": [{"name": "State", "$type": "StateIssueCustomField", "value": {"name": "Submitted"}}]}
        """
        let moved = """
        {"id": "2-99", "idReadable": "WEB-400", "summary": "New", "project": {"id": "0-3", "shortName": "WEB"},
         "customFields": [{"name": "State", "$type": "StateIssueCustomField", "value": {"name": "In Progress"}}]}
        """
        let (tracker, transport) = tracker([
            "POST /api/issues": [.init(status: 200, body: created)],
            "POST /api/issues/WEB-400": [.init(status: 200, body: moved)],
            "POST /api/agiles/108-4/sprints/109-8/issues": [.init(status: 200, body: #"{"id": "2-99"}"#)],
        ])
        let column = BoardColumn(id: "c2", title: "In Progress", values: ["In Progress"])
        let snapshot = BoardSnapshot(
            board: TrackerBoard(id: "108-4", name: "Website", addsCardsByHand: true),
            sprint: TrackerSprint(id: "109-8", name: "Sprint 3"),
            columnField: "State",
            columns: [BoardColumn(id: "c1", title: "Open", values: ["Open"]), column]
        )
        let project = TrackerProject(id: "0-3", key: "WEB", name: "Website")

        let made = try await tracker.create(IssueDraft(project: project, summary: "New"), in: column, on: snapshot)
        #expect(made.card.key == "WEB-400")
        #expect(made.misplaced == nil)
        #expect(snapshot.column(of: made.card)?.id == "c2")
        // Onto the board before into the column: a card in the wrong column
        // is found, and one off the board is not.
        #expect(transport.paths == [
            "POST /api/issues",
            "POST /api/agiles/108-4/sprints/109-8/issues",
            "POST /api/issues/WEB-400",
        ])
    }

    @Test("An issue made and then refused its column is made, and says so")
    func createdButMisplaced() async throws {
        let created = """
        {"id": "2-99", "idReadable": "WEB-400", "summary": "New", "project": {"id": "0-3", "shortName": "WEB"},
         "customFields": [{"name": "State", "$type": "StateIssueCustomField", "value": {"name": "Submitted"}}]}
        """
        let (tracker, transport) = tracker([
            "POST /api/issues": [.init(status: 200, body: created)],
            "POST /api/issues/WEB-400": [.init(status: 400, body: #"{"error_description": "Workflow says no"}"#)],
        ])
        let column = BoardColumn(id: "c2", title: "In Progress", values: ["In Progress"])
        let snapshot = BoardSnapshot(
            board: TrackerBoard(id: "108-4", name: "Website"),
            columnField: "State",
            columns: [column]
        )
        let project = TrackerProject(id: "0-3", key: "WEB", name: "Website")

        let made = try await tracker.create(IssueDraft(project: project, summary: "New"), in: column, on: snapshot)
        #expect(made.card.key == "WEB-400")
        #expect(made.misplaced == TrackerError(.rejected, message: "Workflow says no"))
        #expect(transport.paths.filter { $0 == "POST /api/issues" }.count == 1)
    }

    @Test("A state a state machine governs is moved by command, and the card read again")
    func stateMachineMove() async throws {
        let (tracker, transport) = tracker([
            "POST /api/commands": [.init(status: 200, body: #"{"id": "cmd"}"#)],
            "GET /api/issues/WEB-342": [.init(status: 200, body: Self.movedCard)],
        ])
        let card = TrackerCard(
            id: "2-35",
            key: "WEB-342",
            summary: "Login",
            project: TrackerProject(id: "0-3", key: "WEB", name: "Website"),
            fields: [TrackerField(name: "State", kind: .option, wireType: "StateMachineIssueCustomField")]
        )
        let column = BoardColumn(id: "c2", title: "In Progress", values: ["In Progress"])
        let snapshot = BoardSnapshot(board: TrackerBoard(id: "b", name: "B"), columnField: "State", columns: [column], cards: [card])

        _ = try await tracker.move(card, to: column, on: snapshot)
        #expect(transport.paths == ["POST /api/commands", "GET /api/issues/WEB-342"])
        let body = try #require(try JSONSerialization.jsonObject(with: transport.sent[0].httpBody!) as? [String: Any])
        #expect(body["query"] as? String == "State {In Progress}")
        #expect((body["issues"] as? [[String: String]]) == [["idReadable": "WEB-342"]])
    }

    @Test("An edit writes ordinary fields at once and a state machine's by command")
    func editSplitsTransitions() async throws {
        let (tracker, transport) = tracker([
            "POST /api/issues/WEB-342": [.init(status: 200, body: Self.movedCard)],
            "POST /api/commands": [.init(status: 200, body: #"{"id": "cmd"}"#)],
            "GET /api/issues/WEB-342": [.init(status: 200, body: Self.movedCard)],
        ])
        let state = TrackerField(name: "State", kind: .option, wireType: "StateMachineIssueCustomField")
        let priority = TrackerField(name: "Priority", kind: .option, wireType: "SingleEnumIssueCustomField")
        _ = try await tracker.update("WEB-342", with: IssueChange(fields: [
            FieldChange(field: state, values: [FieldOption(id: "s", name: "Fixed")]),
            FieldChange(field: priority, values: [FieldOption(id: "p", name: "Major")]),
        ]))
        #expect(transport.paths == ["POST /api/issues/WEB-342", "POST /api/commands", "GET /api/issues/WEB-342"])
        let direct = try #require(try JSONSerialization.jsonObject(with: transport.sent[0].httpBody!) as? [String: Any])
        let written = try #require(direct["customFields"] as? [[String: Any]])
        #expect(written.map { $0["name"] as? String } == ["Priority"])
    }

    @Test("An account that may not read time settings logs time without kinds")
    func workTypesWhenForbidden() async throws {
        let (tracker, _) = tracker([
            "GET /api/admin/projects/0-3/timeTrackingSettings": [.init(status: 403, body: "")],
        ])
        let types = try await tracker.workTypes(in: TrackerProject(id: "0-3", key: "WEB", name: "Website"))
        #expect(types.isEmpty)
    }

    @Test("A link the tracker wrote from its root is the host's, and an address stays itself")
    func resolvesLinks() {
        let cloud = URL(string: "https://studio.youtrack.cloud")!
        let underPath = URL(string: "https://tracker.example.com/youtrack")!
        #expect(YouTrackTracker.resolve("/api/files/74-1?sign=a&updated=1", against: cloud)?.absoluteString
            == "https://studio.youtrack.cloud/api/files/74-1?sign=a&updated=1")
        #expect(YouTrackTracker.resolve("/youtrack/api/files/1?sign=a", against: underPath)?.absoluteString
            == "https://tracker.example.com/youtrack/api/files/1?sign=a")
        #expect(YouTrackTracker.resolve("api/files/1", against: underPath)?.absoluteString
            == "https://tracker.example.com/youtrack/api/files/1")
        #expect(YouTrackTracker.resolve("https://cdn.example/a.png", against: cloud)?.absoluteString
            == "https://cdn.example/a.png")
        #expect(YouTrackTracker.resolve("/api/files/a b.png", against: cloud)?.absoluteString
            == "https://studio.youtrack.cloud/api/files/a%20b.png")
        #expect(YouTrackTracker.resolve("/api/files/a%20b.png", against: cloud)?.absoluteString
            == "https://studio.youtrack.cloud/api/files/a%20b.png")
        #expect(YouTrackTracker.resolve("  ", against: cloud) == nil)
    }

    @Test("The token goes with a request to the tracker's own host, and nowhere else")
    func tokenStaysHome() async throws {
        let (tracker, transport) = tracker([
            "GET /hub/api/rest/avatar/abc": [.init(status: 200, body: "png")],
            "GET /a.png": [.init(status: 200, body: "png")],
        ])
        _ = try await tracker.contents(of: URL(string: "https://studio.youtrack.cloud/hub/api/rest/avatar/abc?s=48")!)
        _ = try await tracker.contents(of: URL(string: "https://cdn.example/a.png")!)
        #expect(transport.sent[0].value(forHTTPHeaderField: "Authorization") == "Bearer perm:x")
        #expect(transport.sent[1].value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test("A comment deleted in YouTrack is not part of the conversation")
    func deletedCommentsAreLeftOut() async throws {
        let (tracker, _) = tracker([
            "GET /api/issues/WEB-1/comments": [.init(status: 200, body: """
            [{"id": "4-1", "text": "Kept", "created": 1, "deleted": false},
             {"id": "4-2", "text": "Gone", "created": 2, "deleted": true}]
            """)],
        ])
        #expect(try await tracker.comments(on: "WEB-1").map(\.text) == ["Kept"])
    }

    @Test("Time taken off an issue answers with nothing, and that is success")
    func deletingTime() async throws {
        let (tracker, transport) = tracker([
            "DELETE /api/issues/WEB-1/timeTracking/workItems/w1": [.init(status: 200, body: "")],
        ])
        try await tracker.deleteWork("w1", on: "WEB-1")
        #expect(transport.sent.first?.httpMethod == "DELETE")
    }

    @Test("An issue's page is at /issue/ under the instance")
    func webAddress() {
        let (tracker, _) = tracker([:])
        #expect(tracker.webURL(for: "WEB-342").absoluteString == "https://studio.youtrack.cloud/issue/WEB-342")
    }
}

private extension String {
    /// The first object of a JSON array, written back out.
    var firstJSONObject: String? {
        guard let array = try? JSONSerialization.jsonObject(with: Data(utf8)) as? [Any],
              let first = array.first,
              let data = try? JSONSerialization.data(withJSONObject: first)
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
