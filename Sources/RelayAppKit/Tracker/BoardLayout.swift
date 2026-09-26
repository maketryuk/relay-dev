import Foundation
import RelayTracker

/// How a board is laid out in this window: the order its columns stand in,
/// which of them are shown as one, and which are not shown at all.
///
/// Kept by Relay rather than written to the board. A board's columns are the
/// team's — merging two in the tracker's settings merges them for everyone,
/// and reordering them there reorders a set of values other projects share —
/// while this is one person's way of reading it. It is also the same for any
/// tracker, since it only ever names the board's own columns.
struct BoardLayout: Codable, Equatable {
    /// The board's columns in the order they are shown, by identifier. Empty
    /// is the board's own order.
    var order: [String]
    /// Columns shown as one, each group by the board's identifiers for them.
    var merged: [[String]]
    /// Columns not shown, by identifier. A column the board gains later is not
    /// in here, so it turns up rather than going unseen.
    var hidden: Set<String>

    init(order: [String] = [], merged: [[String]] = [], hidden: Set<String> = []) {
        self.order = order
        self.merged = merged
        self.hidden = hidden
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        order = (try? container.decodeIfPresent([String].self, forKey: .order)) ?? []
        merged = (try? container.decodeIfPresent([[String]].self, forKey: .merged)) ?? []
        hidden = (try? container.decodeIfPresent(Set<String>.self, forKey: .hidden)) ?? []
    }

    /// The board as the tracker lays it out.
    var isEmpty: Bool { order.isEmpty && merged.isEmpty && hidden.isEmpty }

    // MARK: - Reading

    /// The board's columns in the order they are shown. One the order does not
    /// name — added to the board since it was arranged — goes after the
    /// column the board puts it after, which is where the team meant it to be.
    func arranged(_ columns: [BoardColumn]) -> [BoardColumn] {
        guard !order.isEmpty else { return columns }
        let byID = Dictionary(columns.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var placed: Set<String> = []
        var result: [BoardColumn] = []
        for id in order {
            guard let column = byID[id], placed.insert(id).inserted else { continue }
            result.append(column)
        }
        for (index, column) in columns.enumerated() where !placed.contains(column.id) {
            let before = columns[..<index].last { placed.contains($0.id) }
            let position = before.flatMap { neighbour in result.firstIndex { $0.id == neighbour.id } }
            result.insert(column, at: position.map { $0 + 1 } ?? 0)
            placed.insert(column.id)
        }
        return result
    }

    /// The board's columns as they are shown, left to right, hidden ones
    /// included. A merged column stands where the first of its columns does.
    /// Identifiers the board no longer has are passed over: a column deleted
    /// in the tracker takes nothing with it but itself.
    func lanes(of columns: [BoardColumn]) -> [BoardLane] {
        var lanes: [BoardLane] = []
        var laneOfColumn: [String: Int] = [:]
        for column in arranged(columns) {
            if let group = merged.first(where: { $0.contains(column.id) }),
               let lane = group.lazy.compactMap({ laneOfColumn[$0] }).first {
                lanes[lane].columns.append(column)
                laneOfColumn[column.id] = lane
            } else {
                laneOfColumn[column.id] = lanes.count
                lanes.append(BoardLane(columns: [column]))
            }
        }
        return lanes
    }

    /// Whether the lane is on the board. A lane is hidden and shown whole, so
    /// one only some of whose columns are hidden — which nothing here makes —
    /// is shown rather than lost.
    func shows(_ lane: BoardLane) -> Bool {
        !lane.columns.allSatisfy { hidden.contains($0.id) }
    }

    // MARK: - Changing

    mutating func hide(_ lane: BoardLane) {
        hidden.formUnion(lane.columns.map(\.id))
    }

    /// Puts a hidden lane back, at the end, as adding a column to a board
    /// does: it is the place it is looked for, and it is dragged on from there.
    mutating func show(_ lane: BoardLane, in columns: [BoardColumn]) {
        let ids = lane.columns.map(\.id)
        hidden.subtract(ids)
        order = shownOrder(columns).filter { !ids.contains($0) } + ids
        settle(columns)
    }

    /// Takes a lane out and puts it back beside another.
    mutating func move(_ lane: BoardLane, beside target: BoardLane, side: RowDropSide, in columns: [BoardColumn]) {
        let lanes = lanes(of: columns)
        let ids = ListReordering.moving(lane.id, beside: target.id, side: side, in: lanes.map(\.id))
        let byID = Dictionary(lanes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        order = ids.compactMap { byID[$0] }.flatMap { $0.columns.map(\.id) }
        settle(columns)
    }

    /// Puts one lane's columns into another's, which stays where it stands and
    /// keeps its first column first — so a card dropped on it goes where it
    /// went before the merge.
    mutating func merge(_ lane: BoardLane, into target: BoardLane, in columns: [BoardColumn]) {
        guard lane.id != target.id else { return }
        let moving = lane.columns.map(\.id)
        // Read before the groups change: with the new one in place, the lanes
        // already stand where the leftmost of the two did.
        var ids = shownOrder(columns).filter { !moving.contains($0) }
        if let last = target.columns.last, let index = ids.firstIndex(of: last.id) {
            ids.insert(contentsOf: moving, at: index + 1)
            order = ids
        }

        let group = target.columns.map(\.id) + moving
        let involved = Set(group)
        merged.removeAll { !involved.isDisjoint(with: $0) }
        merged.append(group)
        hidden.subtract(group)
        settle(columns)
    }

    /// Takes one column out of the merged lane it is in, and stands it just
    /// after what is left of the lane.
    mutating func detach(_ column: BoardColumn, in columns: [BoardColumn]) {
        guard let index = merged.firstIndex(where: { $0.contains(column.id) }) else { return }
        let rest = merged[index].filter { $0 != column.id }
        var ids = shownOrder(columns).filter { $0 != column.id }
        if let last = ids.lastIndex(where: rest.contains) {
            ids.insert(column.id, at: last + 1)
            order = ids
        }
        merged[index] = rest
        settle(columns)
    }

    /// Gives each of a merged lane's columns its own place again, side by side
    /// where the lane stood.
    mutating func split(_ lane: BoardLane) {
        let involved = Set(lane.columns.map(\.id))
        merged.removeAll { !involved.isDisjoint(with: $0) }
    }

    /// Every column, lane by lane: the order the board is read in, with a
    /// merged lane's columns together however far apart they stood before.
    private func shownOrder(_ columns: [BoardColumn]) -> [String] {
        lanes(of: columns).flatMap { $0.columns.map(\.id) }
    }

    /// Forgets what the board no longer has and what says nothing the board
    /// does not already say, so a layout dragged back to the tracker's is the
    /// tracker's again rather than a copy of it that goes stale.
    private mutating func settle(_ columns: [BoardColumn]) {
        let present = Set(columns.map(\.id))
        merged = merged.map { $0.filter(present.contains) }.filter { $0.count > 1 }
        hidden = hidden.intersection(present)
        order = order.filter(present.contains)
        if order == columns.map(\.id) { order = [] }
    }
}

/// A column as the board shows it: one of the tracker's, or several merged.
struct BoardLane: Identifiable, Equatable {
    /// The tracker's columns in it, in the order they are shown. Never empty.
    var columns: [BoardColumn]

    var id: String { columns[0].id }

    var isMerged: Bool { columns.count > 1 }

    var title: String { columns.map(\.title).joined(separator: ", ") }

    /// Where a card dropped here or made here goes: the first column, as a
    /// column merged in the tracker's own settings takes its first value.
    var destination: BoardColumn { columns[0] }

    /// The limits added up, when every column has one; otherwise the lane has
    /// no limit, since one of its columns can hold any number.
    var limit: Int? {
        let limits = columns.compactMap(\.limit)
        return limits.count == columns.count ? limits.reduce(0, +) : nil
    }

    func holds(_ column: BoardColumn?) -> Bool {
        guard let column else { return false }
        return columns.contains { $0.id == column.id }
    }

    /// The lane's cards, in the order the board lists them.
    func cards(in snapshot: BoardSnapshot) -> [TrackerCard] {
        snapshot.cards.filter { holds(snapshot.column(of: $0)) }
    }
}
