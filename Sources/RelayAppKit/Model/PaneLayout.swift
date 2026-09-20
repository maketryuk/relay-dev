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

/// Where a dragged session lands relative to the pane it was dropped on.
///
/// Four edges and a middle, the arrangement every editor uses, because the
/// gesture has to say *where* as well as *what* — dropping on the right half
/// and on the left half are different requests.
enum PaneDropEdge: Hashable, Sendable {
    case leading
    case trailing
    case top
    case bottom
    /// Take the pane over instead of dividing it.
    case replace

    var axis: PaneAxis? {
        switch self {
        case .leading, .trailing: .horizontal
        case .top, .bottom: .vertical
        case .replace: nil
        }
    }

    /// True when the newcomer takes the first half of the new split.
    var insertsBefore: Bool {
        switch self {
        case .leading, .top: true
        case .trailing, .bottom, .replace: false
        }
    }
}

/// What a pane is showing.
///
/// A session or a file, because those are the two things worth putting side by
/// side: the agent working and the file it is working on.
enum PaneItem: Codable, Hashable, Sendable {
    case session(SessionID)
    /// An absolute path. Relative would have to be resolved against a project
    /// that the layout does not carry, and a file open from outside the
    /// project — a log, a config in the home directory — would have no way to
    /// be named at all.
    case file(String)

    /// Whether two panes show the same sort of thing. A terminal replaces a
    /// terminal; it does not replace the file being read beside it.
    func isSameKind(as other: PaneItem) -> Bool {
        switch (self, other) {
        case (.session, .session), (.file, .file): true
        default: false
        }
    }
}

/// The arrangement of panes in the main area.
///
/// A tree rather than a list of columns: splitting a pane that is itself half of
/// a split has to nest, and anything flatter turns the second split into a
/// special case.
///
/// `file` was added after `session` and deliberately as a third case rather
/// than by folding both into one: the encoded form of the first two is what
/// every saved workspace on disk already contains, and a workspace that stops
/// opening is a day's arrangement of panes lost.
indirect enum PaneNode: Codable, Hashable, Sendable {
    case session(SessionID)
    case file(String)
    case split(PaneSplit)
}

extension PaneNode {
    /// What this node shows, or nil when it is a split rather than a leaf.
    var item: PaneItem? {
        switch self {
        case let .session(id): .session(id)
        case let .file(path): .file(path)
        case .split: nil
        }
    }

    init(_ item: PaneItem) {
        switch item {
        case let .session(id): self = .session(id)
        case let .file(path): self = .file(path)
        }
    }
}

enum PaneLayout {
    /// Never let a pane be dragged to nothing; it becomes impossible to get
    /// back without knowing it is still there.
    static let minimumFraction = 0.15
    static let maximumFraction = 0.85

    // MARK: - Reading

    static func items(in node: PaneNode) -> [PaneItem] {
        switch node {
        case let .session(id): [.session(id)]
        case let .file(path): [.file(path)]
        case let .split(split): items(in: split.first) + items(in: split.second)
        }
    }

    static func sessions(in node: PaneNode) -> [SessionID] {
        items(in: node).compactMap {
            if case let .session(id) = $0 { return id }
            return nil
        }
    }

    static func files(in node: PaneNode) -> [String] {
        items(in: node).compactMap {
            if case let .file(path) = $0 { return path }
            return nil
        }
    }

    static func contains(_ item: PaneItem, in node: PaneNode) -> Bool {
        items(in: node).contains(item)
    }

    static func contains(_ id: SessionID, in node: PaneNode) -> Bool {
        contains(.session(id), in: node)
    }

    // MARK: - Writing

    /// Splits the pane showing `target`, putting `arriving` beside it.
    static func split(
        _ node: PaneNode,
        target: PaneItem,
        with arriving: PaneItem,
        axis: PaneAxis,
        insertingBefore: Bool = false
    ) -> PaneNode {
        switch node {
        case .session, .file:
            guard node.item == target else { return node }
            let existing = node
            let newcomer = PaneNode(arriving)
            return .split(PaneSplit(
                axis: axis,
                first: insertingBefore ? newcomer : existing,
                second: insertingBefore ? existing : newcomer
            ))
        case let .split(split):
            var updated = split
            updated.first = self.split(
                split.first,
                target: target,
                with: arriving,
                axis: axis,
                insertingBefore: insertingBefore
            )
            updated.second = self.split(
                split.second,
                target: target,
                with: arriving,
                axis: axis,
                insertingBefore: insertingBefore
            )
            return .split(updated)
        }
    }

    static func split(
        _ node: PaneNode,
        target: SessionID,
        with newSession: SessionID,
        axis: PaneAxis,
        insertingBefore: Bool = false
    ) -> PaneNode {
        split(
            node,
            target: .session(target),
            with: .session(newSession),
            axis: axis,
            insertingBefore: insertingBefore
        )
    }

    /// Drops `moved` onto the pane showing `target`, beside it or in its place.
    ///
    /// The session is taken out of wherever it already was first, so dragging a
    /// pane across a split moves it rather than showing it twice.
    static func moving(
        _ moved: PaneItem,
        onto target: PaneItem,
        edge: PaneDropEdge,
        in node: PaneNode
    ) -> PaneNode {
        guard moved != target else { return node }
        let base = removing(moved, from: node) ?? PaneNode(target)
        guard contains(target, in: base) else { return PaneNode(moved) }

        guard let axis = edge.axis else {
            return replacing(target, with: moved, in: base)
        }
        return split(base, target: target, with: moved, axis: axis, insertingBefore: edge.insertsBefore)
    }

    static func moving(
        _ moved: SessionID,
        onto target: SessionID,
        edge: PaneDropEdge,
        in node: PaneNode
    ) -> PaneNode {
        moving(.session(moved), onto: .session(target), edge: edge, in: node)
    }

    /// Swaps whichever pane shows `target` for one showing `replacement`.
    static func replacing(_ target: PaneItem, with replacement: PaneItem, in node: PaneNode) -> PaneNode {
        switch node {
        case .session, .file:
            return node.item == target ? PaneNode(replacement) : node
        case let .split(split):
            var updated = split
            updated.first = replacing(target, with: replacement, in: split.first)
            updated.second = replacing(target, with: replacement, in: split.second)
            return .split(updated)
        }
    }

    static func replacing(_ target: SessionID, with replacement: SessionID, in node: PaneNode) -> PaneNode {
        replacing(.session(target), with: .session(replacement), in: node)
    }

    /// Removes a pane, collapsing the split that held it.
    ///
    /// Returns nil when nothing is left, which is how the caller learns the
    /// project has no panes rather than an empty split.
    static func removing(_ target: SessionID, from node: PaneNode) -> PaneNode? {
        removing(.session(target), from: node)
    }

    static func removing(_ target: PaneItem, from node: PaneNode) -> PaneNode? {
        switch node {
        case .session, .file:
            return node.item == target ? nil : node
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

    /// Drops panes whose session the daemon no longer knows about, and files
    /// that are no longer open.
    static func pruning(
        _ node: PaneNode,
        keeping known: Set<SessionID>,
        openFiles: Set<String> = []
    ) -> PaneNode? {
        switch node {
        case let .session(id):
            return known.contains(id) ? node : nil
        case let .file(path):
            return openFiles.contains(path) ? node : nil
        case let .split(split):
            let first = pruning(split.first, keeping: known, openFiles: openFiles)
            let second = pruning(split.second, keeping: known, openFiles: openFiles)
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
        case .session, .file:
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

    /// Where a newly selected session goes when it is not already on screen.
    ///
    /// The rule is "take over the pane being worked in", and the case that was
    /// missing is what happens when nothing on screen is a session at all.
    /// Replacing the whole arrangement — which is what used to happen — threw
    /// away a file that was open beside it: closing a terminal picked the next
    /// session, found no session pane to put it in, and swept the editor away
    /// with it.
    static func showing(_ item: PaneItem, in node: PaneNode?, focused: PaneItem?) -> PaneNode {
        guard let node else { return PaneNode(item) }
        guard !contains(item, in: node) else { return node }

        if let focused, contains(focused, in: node) {
            return replacing(focused, with: item, in: node)
        }
        // The pane being worked in has gone — the usual reason being that it
        // was just closed. Its nearest equivalent is the first pane of the same
        // kind, so a terminal replaces a terminal and leaves the editor alone.
        if let sameKind = items(in: node).first(where: { $0.isSameKind(as: item) }) {
            return replacing(sameKind, with: item, in: node)
        }
        // Nothing of its kind is on screen: it arrives beside what is there
        // rather than instead of it.
        guard let neighbour = items(in: node).first else { return PaneNode(item) }
        return split(node, target: neighbour, with: item, axis: .horizontal, insertingBefore: true)
    }

    /// The pane after `current`, for cycling focus with the keyboard.
    static func item(after current: PaneItem, in node: PaneNode) -> PaneItem? {
        let ordered = items(in: node)
        guard ordered.count > 1, let index = ordered.firstIndex(of: current) else { return ordered.first }
        return ordered[(index + 1) % ordered.count]
    }

    static func session(after current: SessionID, in node: PaneNode) -> SessionID? {
        let ordered = sessions(in: node)
        guard ordered.count > 1, let index = ordered.firstIndex(of: current) else { return ordered.first }
        return ordered[(index + 1) % ordered.count]
    }
}
