import Foundation
import RelayProtocol

/// Which way a split divides its space.
enum PaneAxis: String, Codable, Hashable, Sendable {
    /// Side by side.
    case horizontal
    /// One above the other.
    case vertical
}

/// A split of two panes.
struct PaneSplit: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var axis: PaneAxis
    var first: PaneNode
    var second: PaneNode
    /// Share of the space given to the first pane, clamped away from zero so a
    /// pane can never be dragged out of existence.
    var fraction: Double

    init(id: UUID = UUID(), axis: PaneAxis, first: PaneNode, second: PaneNode, fraction: Double = 0.5) {
        self.id = id
        self.axis = axis
        self.first = first
        self.second = second
        self.fraction = fraction
    }
}

/// The arrangement of terminals in the main area.
///
/// A tree rather than a list of columns: splitting a pane that is itself half of
/// a split has to nest, and anything flatter turns the second split into a
/// special case.
indirect enum PaneNode: Codable, Hashable, Sendable {
    case session(SessionID)
    case split(PaneSplit)
}

enum PaneLayout {
    /// Never let a pane be dragged to nothing; it becomes impossible to get
    /// back without knowing it is still there.
    static let minimumFraction = 0.15
    static let maximumFraction = 0.85

    // MARK: - Reading

    static func sessions(in node: PaneNode) -> [SessionID] {
        switch node {
        case let .session(id): [id]
        case let .split(split): sessions(in: split.first) + sessions(in: split.second)
        }
    }

    static func contains(_ id: SessionID, in node: PaneNode) -> Bool {
        sessions(in: node).contains(id)
    }

    // MARK: - Writing

    /// Splits the pane showing `target`, putting `newSession` beside it.
    static func split(
        _ node: PaneNode,
        target: SessionID,
        with newSession: SessionID,
        axis: PaneAxis
    ) -> PaneNode {
        switch node {
        case let .session(id):
            guard id == target else { return node }
            return .split(PaneSplit(axis: axis, first: .session(id), second: .session(newSession)))
        case let .split(split):
            var updated = split
            updated.first = self.split(split.first, target: target, with: newSession, axis: axis)
            updated.second = self.split(split.second, target: target, with: newSession, axis: axis)
            return .split(updated)
        }
    }

    /// Swaps whichever pane shows `target` for one showing `replacement`.
    static func replacing(_ target: SessionID, with replacement: SessionID, in node: PaneNode) -> PaneNode {
        switch node {
        case let .session(id):
            return .session(id == target ? replacement : id)
        case let .split(split):
            var updated = split
            updated.first = replacing(target, with: replacement, in: split.first)
            updated.second = replacing(target, with: replacement, in: split.second)
            return .split(updated)
        }
    }

    /// Removes a pane, collapsing the split that held it.
    ///
    /// Returns nil when nothing is left, which is how the caller learns the
    /// project has no panes rather than an empty split.
    static func removing(_ target: SessionID, from node: PaneNode) -> PaneNode? {
        switch node {
        case let .session(id):
            return id == target ? nil : node
        case let .split(split):
            let first = removing(target, from: split.first)
            let second = removing(target, from: split.second)
            switch (first, second) {
            case (nil, nil): return nil
            case let (value?, nil): return value
            case let (nil, value?): return value
            case let (first?, second?):
                var updated = split
                updated.first = first
                updated.second = second
                return .split(updated)
            }
        }
    }

    /// Drops panes whose session the daemon no longer knows about.
    static func pruning(_ node: PaneNode, keeping known: Set<SessionID>) -> PaneNode? {
        switch node {
        case let .session(id):
            return known.contains(id) ? node : nil
        case let .split(split):
            let first = pruning(split.first, keeping: known)
            let second = pruning(split.second, keeping: known)
            switch (first, second) {
            case (nil, nil): return nil
            case let (value?, nil): return value
            case let (nil, value?): return value
            case let (first?, second?):
                var updated = split
                updated.first = first
                updated.second = second
                return .split(updated)
            }
        }
    }

    static func setting(fraction: Double, forSplit id: UUID, in node: PaneNode) -> PaneNode {
        switch node {
        case .session:
            return node
        case let .split(split):
            var updated = split
            if split.id == id {
                updated.fraction = min(max(fraction, minimumFraction), maximumFraction)
            }
            updated.first = setting(fraction: fraction, forSplit: id, in: split.first)
            updated.second = setting(fraction: fraction, forSplit: id, in: split.second)
            return .split(updated)
        }
    }

    /// The pane after `current`, for cycling focus with the keyboard.
    static func session(after current: SessionID, in node: PaneNode) -> SessionID? {
        let ordered = sessions(in: node)
        guard ordered.count > 1, let index = ordered.firstIndex(of: current) else { return ordered.first }
        return ordered[(index + 1) % ordered.count]
    }
}
