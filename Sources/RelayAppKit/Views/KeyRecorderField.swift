import AppKit
import RelayUI
import SwiftUI

/// Captures a single keystroke and reports it as a `KeyBinding`.
struct KeyRecorderField: View {
    let binding: KeyBinding?
    let isDefault: Bool
    let conflictsWith: [RelayCommand]
    let onRecord: (KeyBinding?) -> Void
    let onReset: () -> Void

    @State private var isRecording = false
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: Theme.Spacing.xsmall) {
            recorder
            if !isDefault {
                IconButton(systemImage: "arrow.uturn.backward", help: "Restore default", size: 18) {
                    isRecording = false
                    onReset()
                }
            }
        }
    }

    private var recorder: some View {
        ZStack {
            if isRecording {
                KeyCaptureRepresentable { captured in
                    isRecording = false
                    onRecord(captured)
                }
                .frame(width: 0, height: 0)
            }

            Text(labelText)
                .font(.system(size: 11.5, weight: .medium, design: isRecording ? .default : .monospaced))
                .foregroundStyle(labelColor)
                .frame(minWidth: 82)
                .padding(.horizontal, Theme.Spacing.small)
                .padding(.vertical, 5)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { isRecording.toggle() }
        .help(conflictsWith.isEmpty ? "" : "Also used by \(conflictsWith.map(\.title).joined(separator: ", "))")
    }

    private var labelText: String {
        if isRecording { return "Press keys…" }
        return binding?.displayString ?? "Not set"
    }

    private var labelColor: Color {
        if isRecording { return Theme.Palette.accent }
        if binding == nil { return Theme.Palette.textTertiary }
        return conflictsWith.isEmpty ? Theme.Palette.textPrimary : Theme.Palette.statusWaiting
    }

    private var background: Color {
        if isRecording { return Theme.Palette.accentMuted }
        return isHovering ? Theme.Palette.surfaceHover : Theme.Palette.surface
    }

    private var borderColor: Color {
        if isRecording { return Theme.Palette.accent }
        return conflictsWith.isEmpty ? Theme.Palette.border : Theme.Palette.statusWaiting.opacity(0.6)
    }
}

/// AppKit key capture: SwiftUI has no way to observe a raw key event without
/// also consuming it as text input.
private struct KeyCaptureRepresentable: NSViewRepresentable {
    let onCapture: (KeyBinding?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = CaptureView()
        view.onCapture = onCapture
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CaptureView)?.onCapture = onCapture
    }

    final class CaptureView: NSView {
        var onCapture: ((KeyBinding?) -> Void)?
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                // Escape cancels, delete clears the binding entirely.
                if event.keyCode == 53 {
                    self.onCapture?(nil)
                    return nil
                }
                guard let binding = KeyBinding(event: event) else { return nil }
                guard binding.isUsable else { return nil }
                self.onCapture?(binding)
                return nil
            }
        }

        private func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

extension KeyBinding {
    /// Builds a binding from a raw key event.
    init?(event: NSEvent) {
        var modifiers: KeyModifiers = []
        if event.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if event.modifierFlags.contains(.option) { modifiers.insert(.option) }
        if event.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if event.modifierFlags.contains(.command) { modifiers.insert(.command) }

        if let named = Self.name(forKeyCode: event.keyCode) {
            self.init(named, modifiers)
            return
        }
        // `charactersIgnoringModifiers` keeps the physical key rather than what
        // Option turned it into, so ⌥⌘R stays "r" and not "®".
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              let first = characters.first,
              !first.isWhitespace || first == " "
        else { return nil }
        self.init(String(first), modifiers)
    }

    private static func name(forKeyCode keyCode: UInt16) -> String? {
        switch keyCode {
        case 36, 76: "return"
        case 48: "tab"
        case 49: "space"
        case 51: "delete"
        case 53: "escape"
        case 123: "left"
        case 124: "right"
        case 125: "down"
        case 126: "up"
        default: nil
        }
    }
}
