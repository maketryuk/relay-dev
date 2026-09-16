import AppKit
import SwiftUI

/// The pointer shapes the interface promises with.
///
/// A control that does nothing on hover and keeps the arrow looks like text
/// until you click it; a divider that can be dragged has to say so before the
/// drag, not during it.
///
/// Built on AppKit's cursor rectangles rather than on `NSCursor.push()` in an
/// `onHover`: a push has to be balanced by exactly one pop, and a view that
/// disappears, scrolls away or never sees the exit event leaves the whole
/// window holding the wrong cursor. A cursor rectangle is state the window
/// rebuilds for itself, so the worst a mistake can do is show the arrow.
public extension View {
    /// - Parameter isActive: false leaves the arrow alone, which is what a
    ///   disabled control wants — it is not clickable, and saying it is would
    ///   be a lie the pointer tells before the click does nothing.
    func relayCursor(_ cursor: NSCursor, isActive: Bool = true) -> some View {
        background(CursorArea(cursor: isActive ? cursor : nil))
    }

    /// The hand, for anything that responds to a click. A view that has been
    /// `.disabled(…)` keeps the arrow without being told twice.
    func clickable(_ isActive: Bool = true) -> some View {
        modifier(ClickableCursor(isActive: isActive))
    }
}

private struct ClickableCursor: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let isActive: Bool

    func body(content: Content) -> some View {
        content.relayCursor(.pointingHand, isActive: isActive && isEnabled)
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
