import AppKit
import SwiftUI

/// The pointer shapes the interface promises with.
///
/// A control that does nothing on hover and keeps the arrow looks like text
/// until you click it; a divider that can be dragged has to say so before the
/// drag, not during it.
///
/// Named by what the thing underneath does rather than by which glyph appears,
/// because the glyph is not ours to choose: macOS draws its own idea of "this
/// resizes a column", and it has changed what that looks like more than once.
public enum RelayPointer: Sendable {
    /// Anything that responds to a click.
    case clickable
    /// A caret goes here.
    case text
    /// A handle, before it is picked up.
    case draggable
    case resizesColumns
    case resizesRows
}

public extension View {
    /// - Parameter isActive: false leaves the arrow alone, which is what a
    ///   disabled control wants — it is not clickable, and saying it is would
    ///   be a lie the pointer tells before the click does nothing.
    func relayPointer(_ pointer: RelayPointer, isActive: Bool = true) -> some View {
        modifier(PointerShape(pointer: pointer, isActive: isActive, honoursEnabled: false))
    }

    /// The hand, for anything that responds to a click. A view that has been
    /// `.disabled(…)` keeps the arrow without being told twice.
    func clickable(_ isActive: Bool = true) -> some View {
        modifier(PointerShape(pointer: .clickable, isActive: isActive, honoursEnabled: true))
    }
}

/// Two implementations of one promise.
///
/// From macOS 15 SwiftUI states the pointer itself, which is the only version
/// that composes with SwiftUI's own layout and hit-testing: it follows the view
/// as it moves, scrolls and disappears, and it knows which of two overlapping
/// views is in front.
///
/// Before that there is only AppKit's cursor rectangle — a rectangle the window
/// keeps on a view's behalf, measured in that view's coordinates at the moment
/// it was registered, which is why it has to be invalidated by hand every time
/// the view is laid out. It is used on macOS 14 and nowhere else.
private struct PointerShape: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    let pointer: RelayPointer
    let isActive: Bool
    /// `clickable` is the one that follows `.disabled(…)`; an I-beam over a
    /// read-only field is still the truth.
    let honoursEnabled: Bool

    private var isShown: Bool { isActive && (isEnabled || !honoursEnabled) }

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.pointerStyle(isShown ? pointer.style : nil)
        } else {
            content.background(CursorArea(cursor: isShown ? pointer.cursor : nil))
        }
    }
}

private extension RelayPointer {
    @available(macOS 15.0, *)
    var style: PointerStyle {
        switch self {
        case .clickable: .link
        case .text: .horizontalText
        case .draggable: .grabIdle
        case .resizesColumns: .columnResize
        case .resizesRows: .rowResize
        }
    }

    var cursor: NSCursor {
        switch self {
        case .clickable: .pointingHand
        case .text: .iBeam
        case .draggable: .openHand
        case .resizesColumns: .resizeLeftRight
        case .resizesRows: .resizeUpDown
        }
    }
}

private struct CursorArea: NSViewRepresentable {
    let cursor: NSCursor?

    func makeNSView(context: Context) -> CursorRectView {
        let view = CursorRectView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ view: CursorRectView, context: Context) {
        view.cursor = cursor
    }
}

final class CursorRectView: NSView {
    var cursor: NSCursor? {
        didSet {
            guard cursor !== oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    /// Behind the content it describes, so it must never take the click it is
    /// advertising.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let cursor else { return }
        addCursorRect(bounds, cursor: cursor)
    }

    /// A SwiftUI view moves and resizes without the window being told, and a
    /// cursor rectangle measured against the old bounds points at where the
    /// control used to be.
    override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }
}
