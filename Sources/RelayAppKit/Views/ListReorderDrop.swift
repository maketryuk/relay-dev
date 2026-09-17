import RelayProtocol
import RelayUI
import SwiftUI

/// Reports which side of a row the drag is on, and lands it there.
///
/// A delegate rather than `dropDestination` for the reason the pane drop uses
/// one: only `dropUpdated` says where the pointer is while it moves, and
/// without that the line showing where the row will land could not be drawn.
private struct ReorderDropDelegate: DropDelegate {
    let size: CGSize
    let isDragging: () -> Bool
    let onSideChanged: (RowDropSide?) -> Void
    let onDrop: (RowDropSide) -> Void

    func validateDrop(info _: DropInfo) -> Bool {
        isDragging()
    }

    func dropEntered(info: DropInfo) {
        guard isDragging() else { return }
        onSideChanged(ListReordering.side(at: info.location, in: size))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard isDragging() else { return DropProposal(operation: .cancel) }
        onSideChanged(ListReordering.side(at: info.location, in: size))
        return DropProposal(operation: .move)
    }

    func dropExited(info _: DropInfo) {
        onSideChanged(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard isDragging() else { return false }
        let side = ListReordering.side(at: info.location, in: size)
        onSideChanged(nil)
        onDrop(side)
        return true
    }
}

/// A row that a dragged sibling can be dropped above or below.
private struct ReorderTarget: ViewModifier {
    let isDragging: () -> Bool
    let onDrop: (RowDropSide) -> Void

    @State private var size: CGSize = .zero
    @State private var side: RowDropSide?

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { size = proxy.size }
                        .onChange(of: proxy.size) { _, updated in size = updated }
                }
            }
            .overlay(alignment: side == .before ? .top : .bottom) { indicator }
            .onDrop(
                of: [.text],
                delegate: ReorderDropDelegate(
                    size: size,
                    isDragging: isDragging,
                    onSideChanged: { side = $0 },
                    onDrop: onDrop
                )
            )
    }

    /// A line, not a highlight: the question the gesture asks is *where in the
    /// order*, and a filled row answers "this one" instead.
    @ViewBuilder
    private var indicator: some View {
        if side != nil {
            Capsule()
                .fill(Theme.Palette.accent)
                .frame(height: 2)
                .allowsHitTesting(false)
        }
    }
}

extension View {
    /// Accepts a dragged session from the same project, reordering the sidebar.
    func sessionReorderTarget(_ target: SessionID, model: AppModel) -> some View {
        modifier(ReorderTarget(
            isDragging: { model.draggingSessionID != nil && model.draggingSessionID != target },
            onDrop: { side in
                guard let moved = model.draggingSessionID else { return }
                model.moveSession(moved, beside: target, side: side)
            }
        ))
    }

    /// Accepts a dragged project, reordering the rail.
    func projectReorderTarget(_ target: ProjectID, model: AppModel) -> some View {
        modifier(ReorderTarget(
            isDragging: { model.draggingProjectID != nil && model.draggingProjectID != target },
            onDrop: { side in
                guard let moved = model.draggingProjectID else { return }
                model.moveProject(moved, beside: target, side: side)
            }
        ))
    }

    /// Marks a tile as a handle for dragging a project into place.
    ///
    /// The payload is the identifier, but the rows read the model instead:
    /// `onDrag` fires as the drag begins, while an item provider only resolves
    /// on drop — long after the line showing where it will land was needed.
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
