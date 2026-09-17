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
        guard let height = frames[drag.id]?.height else { return 0 }

        let gap = height + spacing
        if drag.targetIndex > drag.sourceIndex, index > drag.sourceIndex, index <= drag.targetIndex {
            return -gap
        }
        if drag.targetIndex < drag.sourceIndex, index >= drag.targetIndex, index < drag.sourceIndex {
            return gap
        }
        return 0
    }

    /// Where the row would land: whichever row's middle the held one is
    /// nearest to, which is the rule that makes the swap happen as the two
    /// pass each other.
    private func target(for id: ID, sourceIndex: Int, translation: CGFloat) -> Int {
        guard let frame = frames[id] else { return sourceIndex }
        let centre = frame.midY + translation

        let distances = ids.enumerated().compactMap { index, candidate in
            frames[candidate].map { (index: index, distance: abs($0.midY - centre)) }
        }
        return distances.min { $0.distance < $1.distance }?.index ?? sourceIndex
    }

    // MARK: - The gesture

    private func gesture(for id: ID) -> some Gesture {
        // Simultaneous and with a few points of slack, so a row still answers
        // clicks: selecting a session and dragging it are the same press until
        // the pointer moves.
        DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
            .onChanged { value in
                guard let sourceIndex = ids.firstIndex(of: id) else { return }
                let translation = value.translation.height
                drag = Drag(
                    id: id,
                    translation: translation,
                    sourceIndex: sourceIndex,
                    targetIndex: target(for: id, sourceIndex: sourceIndex, translation: translation)
                )
            }
            .onEnded { _ in commit() }
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
