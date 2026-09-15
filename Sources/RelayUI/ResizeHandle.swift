import AppKit
import SwiftUI

/// The one draggable divider in the app.
///
/// A hairline until the pointer reaches it, then the accent and a resize
/// cursor. Every divider the user can move goes through this — the sidebars and
/// the splits were each drawing and handling their own, and only one of them
/// had a hover state.
///
/// Reports the drag as a cumulative translation and leaves the arithmetic to the
/// caller, who is the only one that knows what is being resized. Callers capture
/// their starting value in `onBegin`: adding the translation to a value that is
/// itself being updated compounds it, and the divider runs away from the
/// pointer.
public struct ResizeHandle: View {
    public enum Orientation {
        /// A vertical line; dragging moves it left and right.
        case vertical
        /// A horizontal line; dragging moves it up and down.
        case horizontal
    }

    /// Wider than the line it draws: one point is not a target.
    private static let hitSize: CGFloat = 9
    private static let lineSize: CGFloat = 1

    private let orientation: Orientation
    private let onBegin: () -> Void
    private let onDrag: (CGFloat) -> Void
    private let onEnd: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var hasPushedCursor = false

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

    private var isActive: Bool { isHovering || isDragging }

    /// Deliberately an overlay: it reaches past the line into the panes either
    /// side without taking any space of its own, so turning a divider into a
    /// handle does not move anything.
    private var grabArea: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle())
            .frame(
                width: orientation == .vertical ? Self.hitSize : nil,
                height: orientation == .horizontal ? Self.hitSize : nil
            )
            .onHover(perform: updateCursor)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onBegin()
                        }
                        onDrag(orientation == .vertical ? value.translation.width : value.translation.height)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEnd()
                        if !isHovering { releaseCursor() }
                    }
            )
    }

    private func updateCursor(_ hovering: Bool) {
        isHovering = hovering
        if hovering {
            guard !hasPushedCursor else { return }
            hasPushedCursor = true
            (orientation == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        } else if !isDragging {
            releaseCursor()
        }
    }

    /// Guarded, because popping a cursor that was never pushed unbalances the
    /// stack for everything else in the window.
    private func releaseCursor() {
        guard hasPushedCursor else { return }
        hasPushedCursor = false
        NSCursor.pop()
    }
}
