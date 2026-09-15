import AppKit
import SwiftUI

/// Tracks the regions of each window that behave like a title bar.
///
/// The obvious implementation — an `NSView` that overrides `mouseDown` — is the
/// documented one and quietly does nothing here, because the click never
/// reaches it: SwiftUI hit-testing hands the event to whatever it drew on top,
/// and a hosting view is not obliged to forward it. Rather than fight that, the
/// regions register themselves and a single window-level event monitor decides,
/// before the view hierarchy ever sees the click, whether it landed in one.
///
/// The regions only ever cover empty chrome, so nothing is stolen from a button.
@MainActor
final class WindowDragRegions {
    static let shared = WindowDragRegions()

    private var views: [WeakViewBox] = []
    private var monitor: Any?

    private struct WeakViewBox {
        weak var view: NSView?
    }

    private init() {}

    func register(_ view: NSView) {
        installMonitorIfNeeded()
        views.removeAll { $0.view == nil }
        guard !views.contains(where: { $0.view === view }) else { return }
        views.append(WeakViewBox(view: view))
    }

    func unregister(_ view: NSView) {
        views.removeAll { $0.view == nil || $0.view === view }
    }

    private func installMonitorIfNeeded() {
        guard monitor == nil else { return }
        // The monitor closure is delivered on the main thread but is not typed
        // as isolated, and `NSEvent` is not Sendable — so the hop is asserted
        // rather than captured.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            assert(Thread.isMainThread)
            return MainActor.assumeIsolated { WindowDragRegions.shared.handle(event) } ? nil : event
        }
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window else { return false }
        guard hitsRegion(event, in: window) else { return false }

        if event.clickCount >= 2 {
            performSystemDoubleClickAction(on: window)
        } else {
            // `performDrag` runs its own event loop until mouse-up, which is
            // exactly the behaviour a title bar has.
            window.performDrag(with: event)
        }
        return true
    }

    private func hitsRegion(_ event: NSEvent, in window: NSWindow) -> Bool {
        // The traffic lights live in the same strip the rail reserves for them.
        // Swallowing their clicks would break closing the window, which is a
        // considerably worse outcome than a title bar that does not drag.
        guard !hitsWindowButton(event, in: window) else { return false }

        for box in views {
            guard let view = box.view, view.window === window, view.superview != nil else { continue }
            let point = view.convert(event.locationInWindow, from: nil)
            if view.bounds.contains(point) { return true }
        }
        return false
    }

    private func hitsWindowButton(_ event: NSEvent, in window: NSWindow) -> Bool {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), !button.isHidden else { continue }
            let point = button.convert(event.locationInWindow, from: nil)
            if button.bounds.insetBy(dx: -4, dy: -4).contains(point) { return true }
        }
        return false
    }

    /// Honours the user's "double-click a window's title bar to" setting rather
    /// than assuming they want zoom.
    private func performSystemDoubleClickAction(on window: NSWindow) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize":
            window.performMiniaturize(nil)
        case "None":
            break
        default:
            // "Maximize" and an unset preference both mean zoom.
            window.performZoom(nil)
        }
    }
}

/// A region that behaves like a title bar: drag to move, double-click to zoom.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragAreaView() }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        MainActor.assumeIsolated {
            WindowDragRegions.shared.unregister(nsView)
        }
    }

    final class DragAreaView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                WindowDragRegions.shared.unregister(self)
            } else {
                WindowDragRegions.shared.register(self)
            }
        }

        // Kept as a fallback for the case where the event does reach the view.
        override func mouseDown(with event: NSEvent) {
            guard let window else {
                super.mouseDown(with: event)
                return
            }
            if event.clickCount >= 2 {
                guard !window.styleMask.contains(.fullScreen) else { return }
                window.performZoom(nil)
            } else {
                window.performDrag(with: event)
            }
        }
    }
}

/// One-shot access to the hosting `NSWindow` for behaviour SwiftUI does not
/// expose.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension View {
    /// Makes an area drag and zoom the window.
    ///
    /// Only ever apply this to genuinely empty chrome. The window-level monitor
    /// consumes clicks inside a registered region before the view hierarchy
    /// sees them, so a region stretched across a whole header swallows the
    /// buttons sitting on it — which is exactly what happened when the sidebar
    /// header became one big drag area and its settings button started zooming
    /// the window.
    func windowDragArea() -> some View {
        background(WindowDragArea())
    }

    func configureWindow(_ configure: @escaping (NSWindow) -> Void) -> some View {
        background(WindowConfigurator(configure: configure))
    }
}
