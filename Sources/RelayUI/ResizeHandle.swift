import AppKit
import SwiftUI

/// Where a divider lands for a given drag.
///
/// Pure arithmetic, kept out of the view so the two properties that matter can
/// be stated and tested: the divider tracks the pointer exactly, and asking
/// twice for the same drag gives the same answer. Both were broken in ways that
/// are easy to reintroduce — a divider that accumulates its own movement runs
/// away from the cursor.
public enum ResizeMath {
    /// The new length of the pane or sidebar being resized.
    ///
    /// Whole points, because a sub-point width re-lays-out a terminal for a
    /// change nobody can see.
    public static func length(
        from start: Double,
        translation: Double,
        limits: ClosedRange<Double>
    ) -> Double {
        let proposed = (start + translation).rounded()
        return min(max(proposed, limits.lowerBound), limits.upperBound)
    }

    /// The new share of a split, expressed the same way.
    ///
    /// Computed through points rather than directly in fractions so the divider
    /// lands on a pixel, which is where a terminal wants its edge.
    public static func fraction(
        from start: Double,
        translation: Double,
        total: Double,
        limits: ClosedRange<Double>
    ) -> Double {
        guard total > 0 else { return start }
        let proposed = ((start * total) + translation).rounded() / total
        return min(max(proposed, limits.lowerBound), limits.upperBound)
    }
}

/// The one draggable divider in the app.
///
/// A hairline until the pointer reaches it, then the accent; the resize cursor
/// comes from a cursor rectangle, which the window rebuilds for itself rather
/// than from a push that has to be balanced by exactly one pop. Every divider the user can move goes through this — the sidebars and
/// the splits were each drawing and handling their own, and only one of them
/// had a hover state.
///
/// Reports the drag as a cumulative translation and leaves the arithmetic to the
/// caller, who is the only one that knows what is being resized. Callers capture
/// their starting value in `onBegin`: adding the translation to a value that is
/// itself being updated compounds it, and the divider outruns the pointer.
public struct ResizeHandle: View {
    public enum Orientation {
        /// A vertical line; dragging moves it left and right.
        case vertical
        /// A horizontal line; dragging moves it up and down.
        case horizontal
    }

    /// Wider than the line it draws: one point is not a target.
    private static let hitSize: CGFloat = 10
    private static let lineSize: CGFloat = 1

    private let orientation: Orientation
    private let onBegin: () -> Void
    private let onDrag: (CGFloat) -> Void
    private let onEnd: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false

    public init(
        orientation: Orientation,
        onBegin: @escaping () -> Void = {},
        onDrag: @escaping (CGFloat) -> Void,
        onEnd: @escaping () -> Void = {}
    ) {
        self.orientation = orientation
        self.onBegin = onBegin
        self.onDrag = onDrag
        self.onEnd = onEnd
    }

    public var body: some View {
        Rectangle()
            .fill(isActive ? Theme.Palette.accent.opacity(0.55) : Theme.Palette.border)
            .frame(
                width: orientation == .vertical ? Self.lineSize : nil,
                height: orientation == .horizontal ? Self.lineSize : nil
            )
            .overlay { grabArea }
            .animation(.easeOut(duration: 0.12), value: isActive)
    }

    /// The colour must not flicker mid-drag when a fast pointer outruns the
    /// divider and leaves the strip.
    private var isActive: Bool { isDragging || isHovering }

    /// Deliberately an overlay: it reaches past the line into the panes either
    /// side without taking any space of its own, so turning a divider into a
    /// handle does not move anything.
    /// Only for holding the pointer through a drag; the shape on hover is the
    /// declared one.
    private var draggingCursor: NSCursor {
        orientation == .vertical ? .resizeLeftRight : .resizeUpDown
    }

    private var grabArea: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(
                width: orientation == .vertical ? Self.hitSize : nil,
                height: orientation == .horizontal ? Self.hitSize : nil
            )
            .relayPointer(orientation == .vertical ? .resizesColumns : .resizesRows)
            .onHover { isHovering = $0 }
            .gesture(
                // Measured against the window, never against this view. In the
                // local space the handle moves with the pointer, so the pointer
                // appears not to have moved, the divider is put back where it
                // started, and the next event moves it again — the whole thing
                // oscillates instead of dragging.
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onBegin()
                        }
                        // Cursor rectangles are only consulted while the mouse
                        // is up, so a pointer that outruns the divider mid-drag
                        // reverts to the arrow. Setting it per event costs
                        // nothing and needs no undoing: the next move over the
                        // window restores whatever the rectangles say.
                        draggingCursor.set()
                        onDrag(orientation == .vertical ? value.translation.width : value.translation.height)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEnd()
                    }
            )
    }

}
