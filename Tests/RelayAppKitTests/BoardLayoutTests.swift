import Foundation
import RelayTracker
import Testing

@testable import RelayAppKit

@Suite("A board laid out here")
struct BoardLayoutTests {
    private let open = BoardColumn(id: "c1", title: "Open", values: ["Open"], limit: 10)
    private let progress = BoardColumn(id: "c2", title: "In Progress", values: ["In Progress"], limit: 3)
    private let review = BoardColumn(id: "c3", title: "Review", values: ["Review"])
    private let done = BoardColumn(id: "c4", title: "Done", values: ["Done", "Won't fix"], isResolved: true)

    private var columns: [BoardColumn] { [open, progress, review, done] }

    private func lane(_ columns: BoardColumn..., in layout: BoardLayout) -> BoardLane {
        layout.lanes(of: self.columns).first { $0.columns == columns }!
    }

    private func titles(_ layout: BoardLayout, of columns: [BoardColumn]? = nil) -> [String] {
        layout.lanes(of: columns ?? self.columns).filter(layout.shows).map(\.title)
    }

    @Test("Laid out as the tracker has it, every column is its own, in its place and on show")
    func untouched() {
        let layout = BoardLayout()
        #expect(layout.isEmpty)
        #expect(titles(layout) == ["Open", "In Progress", "Review", "Done"])
    }

    // MARK: - Order

    @Test("A column dragged elsewhere lands on the side of the one it was dropped on")
    func moving() {
        var layout = BoardLayout()
        layout.move(lane(done, in: layout), beside: lane(open, in: layout), side: .before, in: columns)
        #expect(titles(layout) == ["Done", "Open", "In Progress", "Review"])
        layout.move(lane(open, in: layout), beside: lane(review, in: layout), side: .after, in: columns)
        #expect(titles(layout) == ["Done", "In Progress", "Review", "Open"])
    }

    @Test("Dragged back into the tracker's order, the layout is the tracker's again")
    func movingBack() {
        var layout = BoardLayout()
        layout.move(lane(done, in: layout), beside: lane(open, in: layout), side: .before, in: columns)
        #expect(!layout.isEmpty)
        layout.move(lane(done, in: layout), beside: lane(review, in: layout), side: .after, in: columns)
        #expect(layout.isEmpty)
    }

    @Test("A merged column moves whole, and a column the board gains goes after the one the board puts it after")
    func movingMergedAndNewColumns() {
        var layout = BoardLayout()
        layout.merge(lane(review, in: layout), into: lane(progress, in: layout), in: columns)
        layout.move(lane(progress, review, in: layout), beside: lane(open, in: layout), side: .before, in: columns)
        #expect(titles(layout) == ["In Progress, Review", "Open", "Done"])

        let blocked = BoardColumn(id: "c5", title: "Blocked", values: ["Blocked"])
        let backlog = BoardColumn(id: "c0", title: "Backlog", values: ["Backlog"])
        let grown = [backlog, open, blocked, progress, review, done]
        #expect(titles(layout, of: grown) == ["Backlog", "In Progress, Review", "Open", "Blocked", "Done"])
    }

    // MARK: - Merging

    @Test("A column merged into another joins it where that one stands, and a drop still goes where it went")
    func merging() {
        var layout = BoardLayout()
        layout.merge(lane(open, in: layout), into: lane(review, in: layout), in: columns)
        #expect(titles(layout) == ["In Progress", "Review, Open", "Done"])

        let merged = lane(review, open, in: layout)
        #expect(merged.isMerged)
        #expect(merged.destination == review)
    }

    @Test("Merging into a merged column makes one column, not two overlapping ones")
    func mergingAgain() {
        var layout = BoardLayout()
        layout.merge(lane(review, in: layout), into: lane(progress, in: layout), in: columns)
        layout.merge(lane(done, in: layout), into: lane(progress, review, in: layout), in: columns)
        #expect(titles(layout) == ["Open", "In Progress, Review, Done"])
        #expect(layout.merged.count == 1)
    }

    @Test("One column taken out of a merged one stands just after what is left of it")
    func detaching() {
        var layout = BoardLayout()
        layout.merge(lane(done, in: layout), into: lane(open, in: layout), in: columns)
        layout.merge(lane(review, in: layout), into: lane(open, done, in: layout), in: columns)
        #expect(titles(layout) == ["Open, Done, Review", "In Progress"])

        layout.detach(done, in: columns)
        #expect(titles(layout) == ["Open, Review", "Done", "In Progress"])

        layout.detach(review, in: columns)
        #expect(titles(layout) == ["Open", "Review", "Done", "In Progress"])
        #expect(layout.merged.isEmpty)
    }

    @Test("Splitting a merged column gives each of its columns its own place, side by side")
    func splitting() {
        var layout = BoardLayout()
        layout.merge(lane(review, in: layout), into: lane(progress, in: layout), in: columns)
        layout.split(lane(progress, review, in: layout))
        #expect(titles(layout) == ["Open", "In Progress", "Review", "Done"])
        #expect(layout.isEmpty)
    }

    @Test("A merged column has a limit only when every column in it has one")
    func limits() {
        var layout = BoardLayout()
        layout.merge(lane(progress, in: layout), into: lane(open, in: layout), in: columns)
        #expect(lane(open, progress, in: layout).limit == 13)
        layout.merge(lane(review, in: layout), into: lane(open, progress, in: layout), in: columns)
        #expect(lane(open, progress, review, in: layout).limit == nil)
    }

    // MARK: - Hiding

    @Test("A hidden column is left off, merged ones whole, and one put back goes at the end")
    func hiding() {
        var layout = BoardLayout()
        layout.merge(lane(review, in: layout), into: lane(progress, in: layout), in: columns)
        layout.hide(lane(progress, review, in: layout))
        layout.hide(lane(open, in: layout))
        #expect(titles(layout) == ["Done"])

        layout.show(lane(open, in: layout), in: columns)
        layout.show(lane(progress, review, in: layout), in: columns)
        #expect(titles(layout) == ["Done", "Open", "In Progress, Review"])
    }

    @Test("A column the board gains later is shown, and one it loses takes only itself")
    func boardChanges() {
        var layout = BoardLayout()
        layout.merge(lane(done, in: layout), into: lane(review, in: layout), in: columns)
        layout.hide(lane(open, in: layout))

        let blocked = BoardColumn(id: "c5", title: "Blocked", values: ["Blocked"])
        #expect(titles(layout, of: [open, progress, blocked, done]) == ["In Progress", "Blocked", "Done"])
    }

    // MARK: - Cards and keeping

    @Test("A merged column holds the cards of each of its columns, in the board's order")
    func cards() {
        let project = TrackerProject(id: "0-1", key: "WEB", name: "Website")
        func card(_ key: String, _ state: String) -> TrackerCard {
            TrackerCard(
                id: key,
                key: key,
                summary: key,
                project: project,
                fields: [TrackerField(
                    name: "State",
                    kind: .option,
                    values: [FieldOption(id: state, name: state)],
                    wireType: "StateIssueCustomField"
                )]
            )
        }
        let snapshot = BoardSnapshot(
            board: TrackerBoard(id: "b", name: "Board"),
            columnField: "State",
            columns: columns,
            cards: [card("WEB-1", "Review"), card("WEB-2", "Open"), card("WEB-3", "In Progress"), card("WEB-4", "Won't fix")]
        )
        var layout = BoardLayout()
        layout.merge(lane(review, in: layout), into: lane(progress, in: layout), in: columns)
        let merged = lane(progress, review, in: layout)
        #expect(merged.cards(in: snapshot).map(\.key) == ["WEB-1", "WEB-3"])
        #expect(merged.holds(snapshot.column(of: card("WEB-1", "Review"))))
        #expect(!merged.holds(snapshot.column(of: card("WEB-2", "Open"))))
        #expect(lane(done, in: layout).cards(in: snapshot).map(\.key) == ["WEB-4"])
    }

    @Test("Layouts are kept in the workspace file, and one that cannot be read costs only itself")
    func persistence() throws {
        var layout = BoardLayout()
        layout.merge(lane(review, in: layout), into: lane(progress, in: layout), in: columns)
        layout.move(lane(done, in: layout), beside: lane(open, in: layout), side: .before, in: columns)
        layout.hide(lane(open, in: layout))
        let settings = TrackerSettings(kind: .youTrack, address: "https://yt.example", layouts: ["b1": layout])
        let read = try JSONDecoder().decode(TrackerSettings.self, from: JSONEncoder().encode(settings))
        #expect(read.layouts == ["b1": layout])

        let older = try JSONDecoder().decode(TrackerSettings.self, from: Data(#"{"address": "https://yt.example"}"#.utf8))
        #expect(older.layouts.isEmpty)

        let broken = try JSONDecoder().decode(
            TrackerSettings.self,
            from: Data(#"{"address": "https://yt.example", "boards": {"p1": "b1"}, "layouts": "not a map"}"#.utf8)
        )
        #expect(broken.layouts.isEmpty)
        #expect(broken.boards == ["p1": "b1"])
    }

    @Test("A layout put back as the tracker has it is forgotten, and no change is no write")
    @MainActor
    func controller() {
        let tracker = TrackerController()
        var writes = 0
        tracker.onChange = { writes += 1 }
        let layout = BoardLayout()

        tracker.changeLayout(of: "b1") { $0.hide(lane(done, in: layout)) }
        #expect(tracker.layout(of: "b1").hidden == ["c4"])
        #expect(writes == 1)

        tracker.changeLayout(of: "b1") { $0.hide(lane(done, in: layout)) }
        #expect(writes == 1)

        tracker.changeLayout(of: "b1") { $0.hidden = [] }
        #expect(tracker.settings.layouts["b1"] == nil)
        #expect(writes == 2)
    }
}
