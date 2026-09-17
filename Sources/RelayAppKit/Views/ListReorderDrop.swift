import RelayProtocol
import RelayUI
import SwiftUI

/// Reports where in a list the drag currently is, and moves the row there.
///
/// A delegate rather than `dropDestination` for the reason the pane drop uses
/// one: only `dropUpdated` says where the pointer is while it moves, and that
/// is the whole gesture here — the row is put in place as it is dragged past,
/// not when the mouse is let go.
private struct ReorderDropDelegate: DropDelegate {
    let size: CGSize
    let isDragging: () -> Bool
    let onMove: (RowDropSide) -> Void
    let onFinish: () -> Void

    func validateDrop(info _: DropInfo) -> Bool {
        isDragging()
    }

    func dropEntered(info: DropInfo) {
        guard isDragging() else { return }
        onMove(ListReordering.side(at: info.location, in: size))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isDragging() else { return DropProposal(operation: .cancel) }
        onMove(ListReordering.side(at: info.location, in: size))
        return DropProposal(operation: .move)
    }

    func performDrop(info _: DropInfo) -> Bool {
        guard isDragging() else { return false }
        onFinish()
        return true
    }
}

/// A row a dragged sibling can be moved past.
private struct ReorderTarget: ViewModifier {
    let isDragging: () -> Bool
    let onMove: (RowDropSide) -> Void
    let onFinish: () -> Void

    @State private var size: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { size = proxy.size }
                        .onChange(of: proxy.size) { _, updated in size = updated }
                }
            }
            .onDrop(
                of: [.text],
                delegate: ReorderDropDelegate(
                    size: size,
                    isDragging: isDragging,
                    onMove: onMove,
                    onFinish: onFinish
                )
            )
    }
}

extension View {
    /// Accepts a dragged session from the same project, reordering the sidebar.
    ///
    /// The list is rearranged while the pointer moves rather than on release.
    /// A line showing where the row *would* land, and then a wait for the drag
    /// session to wind itself up before it did, read as a lag of a second or
    /// two — and the answer to "where will this go" is best given by putting
    /// it there.
    func sessionReorderTarget(_ target: SessionID, model: AppModel) -> some View {
        modifier(ReorderTarget(
            isDragging: { model.draggingSessionID != nil && model.draggingSessionID != target },
            onMove: { side in
                guard let moved = model.draggingSessionID else { return }
                model.moveSession(moved, beside: target, side: side)
            },
            onFinish: { model.endRowDrag() }
        ))
    }

    /// Accepts a dragged project, reordering the rail.
    func projectReorderTarget(_ target: ProjectID, model: AppModel) -> some View {
        modifier(ReorderTarget(
            isDragging: { model.draggingProjectID != nil && model.draggingProjectID != target },
            onMove: { side in
                guard let moved = model.draggingProjectID else { return }
                model.moveProject(moved, beside: target, side: side)
            },
            onFinish: { model.endRowDrag() }
        ))
    }

    /// Marks a tile as a handle for dragging a project into place.
    ///
    /// The payload is the identifier, but the rows read the model instead:
    /// `onDrag` fires as the drag begins, while an item provider only resolves
    /// on drop — long after the row needed to move.
    func projectDragSource(_ projectID: ProjectID, model: AppModel) -> some View {
        onDrag {
            // Only one thing is ever in flight, and the drop targets ask the
            // model which: a leftover session identifier would let a project
            // dropped on a pane move a terminal instead.
            model.draggingSessionID = nil
            model.draggingProjectID = projectID
            return NSItemProvider(object: projectID.rawValue as NSString)
        }
    }
}
