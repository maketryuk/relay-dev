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
/// stay behind this one class — swapping SwiftTerm for libghostty later means
/// rewriting this file and nothing else.
@MainActor
final class TerminalSurface: NSObject, @preconcurrency TerminalViewDelegate {
    let sessionID: SessionID
    let terminalView: TerminalView

    private weak var client: DaemonClient?
    private var pendingOutput = Data()
    private var isFlushScheduled = false

    init(sessionID: SessionID, client: DaemonClient) {
        self.sessionID = sessionID
        self.client = client
        terminalView = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 480))
        super.init()

        terminalView.terminalDelegate = self
        terminalView.allowMouseReporting = true
        terminalView.optionAsMetaKey = true
        applyAppearance()
    }

    private func applyAppearance() {
        terminalView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
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
        terminalView.window?.makeFirstResponder(terminalView)
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
