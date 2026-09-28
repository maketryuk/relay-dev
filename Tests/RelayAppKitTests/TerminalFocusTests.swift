import AppKit
import SwiftTerm
import Testing

@testable import RelayAppKit

@Suite("Terminal focus")
@MainActor
struct TerminalFocusTests {
    /// Delivered to the view the click lands on, as the window would deliver
    /// it: a window in a test never becomes key, and a window that is not key
    /// keeps its first click to itself.
    private func click(at point: NSPoint, in window: NSWindow) throws {
        let target = try #require(window.contentView?.hitTest(point))
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type,
                location: point,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            ))
            type == .leftMouseDown ? target.mouseDown(with: event) : target.mouseUp(with: event)
        }
    }

    @Test("A click on the terminal takes the keyboard from the file beside it", arguments: [true, false])
    func clickTakesTheKeyboard(onTheGPU: Bool) throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let terminal = RelayTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        terminal.prefersAcceleratedRendering = onTheGPU
        let delegate = RecordingDelegate()
        terminal.terminalDelegate = delegate
        let file = NSTextView(frame: NSRect(x: 400, y: 0, width: 400, height: 400))
        window.contentView?.addSubview(terminal)
        window.contentView?.addSubview(file)
        window.makeFirstResponder(file)

        // On the GPU the click lands on SwiftTerm's Metal view, which takes no
        // keyboard, rather than on the terminal; on a Mac without one it lands
        // on the terminal itself. Either way the terminal is what was clicked.
        try click(at: NSPoint(x: 100, y: 100), in: window)
        #expect(window.firstResponder === terminal)
    }
}
