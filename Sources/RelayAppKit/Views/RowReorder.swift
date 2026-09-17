import RelayProtocol
import RelayUI
import SwiftUI

/// Where each row of a list is, so a drag can be answered without asking the
/// system anything.
///
/// A plain reference box rather than observed state: nothing draws from it, it
/// is read inside a gesture handler, and publishing it would invalidate the
/// list on every frame of the layout it describes.
@MainActor
final class RowFrames {
    private var frames: [String: CGRect] = [:]

    func set(_ frame: CGRect, for id: String) {
        frames[id] = frame
    }

    func forget(_ id: String) {
        frames.removeValue(forKey: id)
    }

    /// The row under a point, with the rectangle it occupies.
    func row(at point: CGPoint) -> (id: String, frame: CGRect)? {
        frames.first { $0.value.contains(point) }.map { ($0.key, $0.value) }
    }
}

/// Reordering by dragging, done entirely inside the app.
///
/// Not `onDrag`/`onDrop`: those hand the gesture to AppKit's dragging session,
/// which has to be started, given a snapshot to carry and wound up again — and
/// none of the drop delegate's callbacks arrive until it has. However the move
/// itself was applied, the gesture read as a lag of a second or so, which is
/// not what dragging a row is like in any other application. A `DragGesture`
/// reports the pointer directly, so the list answers on the same frame the
/// pointer moves.
///
/// What is given up is dragging a row *out* of its list and onto something
/// else, since nothing outside the app knows this gesture is happening. The
/// pane header keeps `onDrag` for exactly that reason: moving a terminal
/// between panes crosses views, and reordering does not.
private struct ReorderRow: ViewModifier {
    let id: String
    let space: String
    let frames: RowFrames
    let onDrag: (CGPoint) -> Void
    let onEnd: () -> Void

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    let frame = proxy.frame(in: .named(space))
                    Color.clear
                        .onAppear { frames.set(frame, for: id) }
                        .onChange(of: frame) { _, updated in frames.set(updated, for: id) }
                        .onDisappear { frames.forget(id) }
                }
            }
            // Simultaneous, so a click still selects: the gesture needs a few
            // points of movement before it is a drag at all, and a row answers
            // taps as well.
            .simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .named(space))
                    .onChanged { onDrag($0.location) }
                    .onEnded { _ in onEnd() }
            )
    }
}

extension View {
    /// Marks a row as draggable within its list.
    func reorderRow(
        id: String,
        in space: String,
        frames: RowFrames,
        onDrag: @escaping (CGPoint) -> Void,
        onEnd: @escaping () -> Void
    ) -> some View {
        modifier(ReorderRow(id: id, space: space, frames: frames, onDrag: onDrag, onEnd: onEnd))
    }

    /// The list the rows report their positions in.
    func reorderSpace(_ space: String) -> some View {
        coordinateSpace(name: space)
    }
}

/// What a list does with a pointer that is dragging one of its rows.
enum RowReorder {
    static let sessionSpace = "relay.sessions"
    static let projectSpace = "relay.projects"

    /// Moves the dragged session to wherever the pointer is.
    @MainActor
    static func session(
        _ dragged: SessionID,
        to point: CGPoint,
        frames: RowFrames,
        model: AppModel
    ) {
        model.draggingSessionID = dragged
        guard let row = frames.row(at: point), row.id != dragged.rawValue else { return }
        model.moveSession(
            dragged,
            beside: SessionID(rawValue: row.id),
            side: ListReordering.side(at: point.y - row.frame.minY, in: row.frame.height)
        )
    }

    @MainActor
    static func project(
        _ dragged: ProjectID,
        to point: CGPoint,
        frames: RowFrames,
        model: AppModel
    ) {
        model.draggingProjectID = dragged
        guard let row = frames.row(at: point), row.id != dragged.rawValue else { return }
        model.moveProject(
            dragged,
            beside: ProjectID(rawValue: row.id),
            side: ListReordering.side(at: point.y - row.frame.minY, in: row.frame.height)
        )
    }
}
