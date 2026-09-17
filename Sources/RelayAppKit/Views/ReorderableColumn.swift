import RelayUI
import SwiftUI

/// A column of rows that can be dragged into another order.
///
/// The gesture is the app's own, not AppKit's dragging session. That session
/// has to be started, handed a snapshot of the row to carry and wound up
/// again, and none of the drop delegate's callbacks arrive until it has —
/// which is where the second of lag came from, however the move was applied.
/// A `DragGesture` reports the pointer directly, so the row is under it on the
/// frame it moves.
///
/// The list itself does not change while the drag is happening: the row being
/// held is lifted and follows the pointer, and the others slide out of the way
/// to leave a gap where it will land. That keeps the measured positions valid
/// for the whole gesture — a list that rearranged as it was read would be
/// chasing its own tail — and it makes the arrangement on release exactly the
/// one that was on screen a moment before it.
struct ReorderableColumn<ID: Hashable, Row: View>: View {
    let ids: [ID]
    let spacing: CGFloat
    /// The name of the coordinate space the rows report in. Unique per list,
    /// since two of them are on screen at once.
    let space: String
    /// Called once, when the row is let go and the order has actually changed.
    let onMove: (_ moved: ID, _ target: ID, _ side: RowDropSide) -> Void
    @ViewBuilder let row: (ID) -> Row

    @State private var frames: [ID: CGRect] = [:]
    @State private var drag: Drag?

    private struct Drag: Equatable {
        var id: ID
        /// How far the pointer has moved since the press.
        var translation: CGFloat
        var sourceIndex: Int
        var targetIndex: Int
        /// The middles of every row, as they were when the row was taken hold
        /// of. A snapshot rather than a reading: the offsets move the rows
        /// while the drag is happening, so measuring them then would be
        /// measuring the drag's own output.
        var midpoints: [CGFloat]
        /// The held row's height, which is the size of the gap it leaves.
        var height: CGFloat
    }

    var body: some View {
        VStack(spacing: spacing) {
            ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                row(id)
                    .background { measure(id) }
                    .offset(y: offset(at: index, id: id))
                    .shadow(
                        color: .black.opacity(drag?.id == id ? 0.4 : 0),
                        radius: 10,
                        y: 4
                    )
                    // Above its neighbours while it is over them.
                    .zIndex(drag?.id == id ? 1 : 0)
                    // The row in hand follows the pointer exactly; the others
                    // make room, which is a movement worth easing.
                    .animation(drag?.id == id ? nil : .easeOut(duration: 0.14), value: drag?.targetIndex)
                    .simultaneousGesture(gesture(for: id))
            }
        }
        .coordinateSpace(name: space)
    }

    // MARK: - Geometry

    private func measure(_ id: ID) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .named(space))
            Color.clear
                .onAppear { frames[id] = frame }
                .onChange(of: frame) { _, updated in
                    // Frozen for the duration of a drag: the offsets move the
                    // rows, and reading those positions back as the rows'
                    // places would feed the gesture its own output.
                    guard drag == nil else { return }
                    frames[id] = updated
                }
        }
    }

    private func offset(at index: Int, id: ID) -> CGFloat {
        guard let drag else { return 0 }
        if drag.id == id { return drag.translation }

        let gap = drag.height + spacing
        if drag.targetIndex > drag.sourceIndex, index > drag.sourceIndex, index <= drag.targetIndex {
            return -gap
        }
        if drag.targetIndex < drag.sourceIndex, index >= drag.targetIndex, index < drag.sourceIndex {
            return gap
        }
        return 0
    }

    // MARK: - The gesture

    private func gesture(for id: ID) -> some Gesture {
        // Simultaneous and with a few points of slack, so a row still answers
        // clicks: selecting a session and dragging it are the same press until
        // the pointer moves.
        DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
            .onChanged { value in
                guard let current = begin(id) else { return }
                drag = Drag(
                    id: id,
                    translation: value.translation.height,
                    sourceIndex: current.sourceIndex,
                    targetIndex: ColumnReorder.targetIndex(
                        sourceIndex: current.sourceIndex,
                        pointer: value.location.y,
                        midpoints: current.midpoints
                    ),
                    midpoints: current.midpoints,
                    height: current.height
                )
            }
            .onEnded { _ in commit() }
    }

    /// The geometry this drag works from: the one already taken if it is
    /// underway, or a fresh snapshot if this is the press that starts it.
    private func begin(_ id: ID) -> (sourceIndex: Int, midpoints: [CGFloat], height: CGFloat)? {
        if let drag, drag.id == id {
            return (drag.sourceIndex, drag.midpoints, drag.height)
        }
        guard let sourceIndex = ids.firstIndex(of: id) else { return nil }
        // Every row, or none: a list half measured would put rows in an order
        // derived from zeroes.
        let rectangles = ids.compactMap { frames[$0] }
        guard rectangles.count == ids.count, let held = frames[id] else { return nil }
        return (sourceIndex, rectangles.map(\.midY), held.height)
    }

    private func commit() {
        guard let drag else { return }
        defer {
            // Cleared without animation and after the move: the list is
            // already in the arrangement the offsets were drawing, so there is
            // nothing to animate back.
            self.drag = nil
        }
        guard drag.targetIndex != drag.sourceIndex,
              ids.indices.contains(drag.targetIndex)
        else { return }
        onMove(
            drag.id,
            ids[drag.targetIndex],
            drag.targetIndex > drag.sourceIndex ? .after : .before
        )
    }
}

/// Where a held row lands.
///
/// Stated as "after every row whose middle the pointer has passed", which is
/// the rule that makes one row of travel move one place. Comparing the held
/// row's own centre against every centre *including its own* does not: its own
/// is the nearest one until the pointer has gone a whole row, and with three
/// rows that made the middle position unreachable from either end.
enum ColumnReorder {
    static func targetIndex(sourceIndex: Int, pointer: CGFloat, midpoints: [CGFloat]) -> Int {
        guard !midpoints.isEmpty else { return sourceIndex }
        var target = 0
        for (index, midpoint) in midpoints.enumerated() where index != sourceIndex && midpoint < pointer {
            target += 1
        }
        return min(target, midpoints.count - 1)
    }
}
