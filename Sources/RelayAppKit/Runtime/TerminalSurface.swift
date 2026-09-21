import AppKit
import Foundation
import RelayProtocol
import RelayUI
import SwiftTerm

/// Owns one SwiftTerm renderer and wires it to a daemon session.
///
/// The renderer is the only piece of terminal machinery that lives in the GUI;
/// the PTY it mirrors belongs to the daemon. That split is what lets the window
/// close without killing anything, and it is why `TerminalEngine`-level details
/// stay behind this class and its view subclass — swapping SwiftTerm for
/// libghostty later means rewriting the two of them and nothing else.
/// The terminal text size, and what stepping it means.
///
/// Apart from the model so the arithmetic can be read and tested without an
/// application around it.
enum TerminalZoom {
    /// The size the terminal is read at until the user says otherwise.
    static let defaultSize: CGFloat = 13
    /// Small enough to fit a wide diff, large enough to read across the room.
    static let range: ClosedRange<CGFloat> = 8 ... 28

    static func stepped(_ size: CGFloat, by delta: CGFloat) -> CGFloat {
        clamped(size + delta)
    }

    static func clamped(_ size: CGFloat) -> CGFloat {
        min(max(size, range.lowerBound), range.upperBound)
    }

    /// Reads a size out of what someone typed, or nothing if it was not a size.
    ///
    /// Forgiving about the three things a person actually types: the unit they
    /// can see beside the field, the spaces around it, and a comma for the
    /// decimal point — which is what a Russian keyboard offers and what the
    /// window asks for in Russian. Out-of-range is answered rather than
    /// refused, since the intent of "40" is legible and rejecting it silently
    /// would look like the field is broken.
    static func parsed(_ text: String) -> CGFloat? {
        let digits = text.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." }
        guard let value = Double(digits), value > 0 else { return nil }
        return clamped(CGFloat(value))
    }
}

@MainActor
final class TerminalSurface: NSObject, @preconcurrency TerminalViewDelegate {
    let sessionID: SessionID
    let terminalView: RelayTerminalView

    /// Changing it re-flows the terminal, which resizes the PTY through the
    /// delegate the same way dragging the window does.
    var fontSize: CGFloat {
        didSet {
            guard fontSize != oldValue else { return }
            applyFont()
        }
    }

    var usesAcceleratedRendering: Bool {
        didSet { terminalView.prefersAcceleratedRendering = usesAcceleratedRendering }
    }

    /// What the renderer settled on, which is not always what was asked for.
    var isDrawingOnGPU: Bool { terminalView.isUsingMetalRenderer }

    private weak var client: DaemonClient?
    private var pendingOutput = Data()
    private var isFlushScheduled = false

    init(
        sessionID: SessionID,
        client: DaemonClient,
        fontSize: CGFloat = TerminalZoom.defaultSize,
        usesAcceleratedRendering: Bool = true
    ) {
        self.sessionID = sessionID
        self.client = client
        self.fontSize = fontSize
        self.usesAcceleratedRendering = usesAcceleratedRendering
        terminalView = RelayTerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        super.init()

        terminalView.terminalDelegate = self
        terminalView.allowMouseReporting = true
        terminalView.optionAsMetaKey = true
        terminalView.prefersAcceleratedRendering = usesAcceleratedRendering
        applyAppearance()
    }

    private func applyFont() {
        terminalView.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    private func applyAppearance() {
        applyFont()
        terminalView.nativeBackgroundColor = NSColor(srgbRed: 0x08 / 255, green: 0x09 / 255, blue: 0x0A / 255, alpha: 1)
        terminalView.nativeForegroundColor = NSColor(srgbRed: 0xE8 / 255, green: 0xEC / 255, blue: 0xEE / 255, alpha: 1)
        terminalView.caretColor = NSColor(srgbRed: 0x4C / 255, green: 0x8D / 255, blue: 1, alpha: 1)
        terminalView.selectedTextBackgroundColor = NSColor(srgbRed: 0x1B / 255, green: 0x2C / 255, blue: 0x4A / 255, alpha: 1)
        terminalView.installColors(Self.ansiPalette)
    }

    /// A restrained 16-colour set tuned for a near-black background: saturated
    /// enough for `ls` and diffs, never neon.
    private static let ansiPalette: [SwiftTerm.Color] = {
        func color(_ hex: UInt32) -> SwiftTerm.Color {
            SwiftTerm.Color(
                red: UInt16((hex >> 16) & 0xFF) * 257,
                green: UInt16((hex >> 8) & 0xFF) * 257,
                blue: UInt16(hex & 0xFF) * 257
            )
        }
        return [
            color(0x1C2023), color(0xF85149), color(0x3FB950), color(0xD29922),
            color(0x58A6FF), color(0xBC8CFF), color(0x39C5CF), color(0xB1BAC4),
            color(0x4D565E), color(0xFF7B72), color(0x56D364), color(0xE3B341),
            color(0x79C0FF), color(0xD2A8FF), color(0x56D4DD), color(0xE8ECEE),
        ]
    }()

    // MARK: - Output

    /// Coalesces bursts into one feed per runloop turn. A chatty agent can emit
    /// hundreds of small chunks a second; feeding each one separately would make
    /// the renderer, not the PTY, the bottleneck.
    func feed(_ data: Data) {
        pendingOutput.append(data)
        guard !isFlushScheduled else { return }
        isFlushScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isFlushScheduled = false
                guard !self.pendingOutput.isEmpty else { return }
                let chunk = [UInt8](self.pendingOutput)
                self.pendingOutput.removeAll(keepingCapacity: true)
                self.terminalView.feed(byteArray: chunk[...])
            }
        }
    }

    func focus() {
        guard let window = terminalView.window, window.firstResponder !== terminalView else { return }
        window.makeFirstResponder(terminalView)
    }

    /// Claims the keyboard only when nothing else in the window is taking text.
    ///
    /// For the implicit path: the focused pane asks for the keyboard on every
    /// redraw, and a redraw happens on every change to the model — which, with
    /// an agent writing output, is many times a second. Without this, renaming
    /// a project while a session runs is impossible, because the caret is
    /// pulled out of the field between one keystroke and the next.
    ///
    /// Clicking the terminal still works: that goes through `focus()`, which
    /// asks outright rather than as a side effect of drawing.
    func focusUnlessEditingElsewhere() {
        guard let responder = terminalView.window?.firstResponder else {
            focus()
            return
        }
        guard responder === terminalView || !(responder is any NSTextInputClient) else { return }
        focus()
    }

    // MARK: - TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        client?.post(.input(sessionID, Data(data)))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        client?.post(.resize(sessionID, columns: newCols, rows: newRows))
    }

    func setTerminalTitle(source: TerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link), url.scheme != nil else { return }
        NSWorkspace.shared.open(url)
    }

    func bell(source: TerminalView) {
        NSSound.beep()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(String(decoding: content, as: UTF8.self), forType: .string)
    }

    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string).map { Data($0.utf8) }
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
