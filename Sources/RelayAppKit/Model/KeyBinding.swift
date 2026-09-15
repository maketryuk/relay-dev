import Foundation
import SwiftUI

/// The modifier keys a binding requires.
struct KeyModifiers: OptionSet, Codable, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let control = KeyModifiers(rawValue: 1 << 0)
    static let option = KeyModifiers(rawValue: 1 << 1)
    static let shift = KeyModifiers(rawValue: 1 << 2)
    static let command = KeyModifiers(rawValue: 1 << 3)

    /// Apple orders modifier glyphs ⌃⌥⇧⌘ regardless of how they were typed.
    var displayString: String {
        var text = ""
        if contains(.control) { text += "⌃" }
        if contains(.option) { text += "⌥" }
        if contains(.shift) { text += "⇧" }
        if contains(.command) { text += "⌘" }
        return text
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.control) { result.insert(.control) }
        if contains(.option) { result.insert(.option) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.command) { result.insert(.command) }
        return result
    }
}

/// One keystroke.
///
/// Stored as a lowercase key name plus modifiers rather than as a formatted
/// string, so the display form can change without invalidating what the user
/// configured.
struct KeyBinding: Codable, Hashable, Sendable {
    var key: String
    var modifiers: KeyModifiers

    init(_ key: String, _ modifiers: KeyModifiers) {
        self.key = key.lowercased()
        self.modifiers = modifiers
    }

    /// Named keys that have a glyph instead of a letter.
    private static let glyphs: [String: String] = [
        "return": "↩", "tab": "⇥", "space": "␣", "delete": "⌫", "escape": "⎋",
        "up": "↑", "down": "↓", "left": "←", "right": "→",
        "[": "[", "]": "]", ",": ",", ".": ".", "/": "/", "\\": "\\", "`": "`",
    ]

    var displayString: String {
        modifiers.displayString + (Self.glyphs[key] ?? key.uppercased())
    }

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "return": .return
        case "tab": .tab
        case "space": .space
        case "delete": .delete
        case "escape": .escape
        case "up": .upArrow
        case "down": .downArrow
        case "left": .leftArrow
        case "right": .rightArrow
        default:
            key.count == 1 ? KeyEquivalent(Character(key)) : nil
        }
    }

    var keyboardShortcut: KeyboardShortcut? {
        guard let keyEquivalent else { return nil }
        return KeyboardShortcut(keyEquivalent, modifiers: modifiers.eventModifiers)
    }

    /// A binding with no modifier at all would swallow ordinary typing in the
    /// terminal, so the recorder refuses those.
    var isUsable: Bool {
        guard keyEquivalent != nil else { return false }
        if modifiers.isEmpty { return false }
        // Shift alone is just capitalisation.
        if modifiers == .shift { return false }
        return true
    }
}
