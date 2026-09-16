import AppKit
import SwiftTerm

/// SwiftTerm's view with the two things Relay has to decide for itself.
///
/// The renderer, which SwiftTerm leaves on the CPU unless asked; and the
/// newline an agent expects from `⇧↩`, which no terminal sends on its own.
/// Everything else the class does is SwiftTerm's.
final class RelayTerminalView: TerminalView {
    /// Whether to draw on the GPU. Off is always available and always correct,
    /// so a machine that cannot manage it loses speed rather than the terminal.
    var prefersAcceleratedRendering = true {
        didSet {
            guard prefersAcceleratedRendering != oldValue else { return }
            applyRenderer()
        }
    }

    /// Set once the GPU path has refused, so a view that cannot use it does not
    /// try again on every window change for the rest of the session.
    private var isAccelerationUnavailable = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        Self.startWatchingKeys()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        Self.startWatchingKeys()
    }

    /// A CAMetalLayer binds to a window's surface, so there has to be a window
    /// before the renderer can be swapped in.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyRenderer()
    }

    private func applyRenderer() {
        guard window != nil, !isAccelerationUnavailable else { return }
        let wanted = prefersAcceleratedRendering
        guard wanted != isUsingMetalRenderer else { return }
        do {
            try setUseMetal(wanted)
        } catch {
            isAccelerationUnavailable = true
            NSLog("Relay: GPU terminal rendering is unavailable (\(error)); drawing on the CPU instead")
        }
    }

    /// Watches for the one keystroke Relay has to answer before the terminal
    /// does, for the lifetime of the application.
    ///
    /// Nothing closer to the view will do. SwiftTerm's `keyDown` is `public`
    /// rather than `open`, so it cannot be overridden; and AppKit offers a
    /// keystroke to the view hierarchy as a *key equivalent* only when it
    /// carries ⌘ — `⇧↩` goes straight to the first responder, where SwiftTerm
    /// turns it into a bare carriage return before anything of ours runs. A
    /// local monitor sees the event as it leaves the queue, which is the last
    /// moment at which there is anything to decide.
    private static var keyMonitor: Any?

    private static func startWatchingKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // The closure is delivered on the main thread but is not typed as
            // isolated, and `NSEvent` is not Sendable — so the hop is asserted
            // rather than captured, as the window drag monitor does.
            assert(Thread.isMainThread)
            return MainActor.assumeIsolated { answered(event) } ? nil : event
        }
    }

    /// Whether the terminal being typed into took the keystroke for itself.
    private static func answered(_ event: NSEvent) -> Bool {
        let window = event.window ?? NSApp.keyWindow
        guard let view = window?.firstResponder as? RelayTerminalView else { return false }
        return view.handleSoftNewline(for: event)
    }

    /// Whether this view answered the keystroke itself.
    ///
    /// The first-responder check is what keeps a window of several panes from
    /// sending one `⇧↩` from each of them.
    func handleSoftNewline(for event: NSEvent) -> Bool {
        guard window?.firstResponder === self, sendsSoftNewline(for: event) else { return false }
        terminalDelegate?.send(source: self, data: Self.escapeReturn[...])
        return true
    }

    /// `ESC CR`, which is what `⌥↩` has always sent and what both agents read as
    /// "another line, do not send this yet".
    private static let escapeReturn: [UInt8] = [0x1B, 0x0D]

    /// Whether `⇧↩` should mean a newline rather than a submitted prompt.
    ///
    /// A terminal sends a bare `CR` for Return whatever is held down with it, so
    /// an agent cannot tell the two apart and takes every one of them as "send".
    /// iTerm2 and VS Code are configured out of this by hand — `/terminal-setup`
    /// writes exactly the sequence above into their key maps — and asking
    /// someone to configure their terminal is not something an app that *is*
    /// the terminal can do.
    ///
    /// Left alone once the program has negotiated the Kitty keyboard protocol:
    /// it is then being told about the Shift outright, and inventing a second
    /// meaning would deliver one keystroke twice.
    private func sendsSoftNewline(for event: NSEvent) -> Bool {
        guard getTerminal().keyboardEnhancementFlags.isEmpty else { return false }
        guard event.keyCode == Self.returnKeyCode || event.keyCode == Self.keypadEnterKeyCode else { return false }
        let flags = event.modifierFlags
        guard flags.contains(.shift) else { return false }
        return !flags.contains(.command) && !flags.contains(.control) && !flags.contains(.option)
    }

    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
}
