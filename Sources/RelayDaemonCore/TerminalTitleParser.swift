import Foundation

/// Extracts the title a program sets with `OSC 0/1/2`.
///
/// This is how a terminal tab learns what it is running, and it is the answer to
/// naming sessions without asking a model anything: Claude Code, Codex and most
/// shells already announce what they are doing through this sequence. Relay just
/// has to listen.
///
/// Parsing is incremental because a PTY splits output at arbitrary byte
/// boundaries — a title can easily straddle two reads.
public struct TerminalTitleParser: Sendable {
    private enum State {
        case normal
        case escape
        case sequence
        case sequenceEscape
    }

    /// A runaway sequence must not grow without bound.
    private static let maximumLength = 1024
    /// Titles longer than this are decoration, not information.
    private static let maximumTitleLength = 96

    private var state: State = .normal
    private var buffer: [UInt8] = []

    public init() {}

    /// Feeds raw output and returns the most recent title it completed, if any,
    /// as a name: without its spinner frame, and short enough for a sidebar.
    public mutating func consume(_ data: Data) -> String? {
        consumeTitles(data).compactMap(Self.sanitise).last
    }

    /// Feeds raw output and returns every title it completed, as the program
    /// wrote them, spinner frame and all — which is where an agent says whether
    /// it is working.
    public mutating func consumeTitles(_ data: Data) -> [String] {
        var titles: [String] = []

        for byte in data {
            switch state {
            case .normal:
                if byte == 0x1B { state = .escape }

            case .escape:
                if byte == 0x5D {
                    state = .sequence
                    buffer.removeAll(keepingCapacity: true)
                } else if byte == 0x1B {
                    // Stay armed: two escapes in a row.
                } else {
                    state = .normal
                }

            case .sequence:
                if byte == 0x07 {
                    if let title = title(from: buffer) { titles.append(title) }
                    state = .normal
                } else if byte == 0x1B {
                    state = .sequenceEscape
                } else {
                    buffer.append(byte)
                    if buffer.count > Self.maximumLength {
                        state = .normal
                        buffer.removeAll(keepingCapacity: false)
                    }
                }

            case .sequenceEscape:
                if byte == 0x5C {
                    // String Terminator.
                    if let title = title(from: buffer) { titles.append(title) }
                    state = .normal
                } else {
                    // A stray escape inside the payload.
                    buffer.append(0x1B)
                    buffer.append(byte)
                    state = .sequence
                }
            }
        }

        return titles
    }

    /// `Ps ; text`, where 0, 1 and 2 all set a title of some kind. Control
    /// characters are dropped here, and nothing else.
    private func title(from payload: [UInt8]) -> String? {
        guard let separator = payload.firstIndex(of: 0x3B) else { return nil }
        let code = String(decoding: payload[payload.startIndex ..< separator], as: UTF8.self)
        guard ["0", "1", "2"].contains(code) else { return nil }

        let text = String(decoding: payload[payload.index(after: separator)...], as: UTF8.self)
        let printable = Self.printable(text)
        return printable.isEmpty ? nil : printable
    }

    private static func printable(_ raw: String) -> String {
        raw
            .unicodeScalars
            .filter { !$0.properties.isDefaultIgnorableCodePoint && ($0.value >= 0x20 || $0 == " ") }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The glyphs a CLI puts at the front of its title while it is thinking.
    ///
    /// Claude Code advances one of these with every frame of its spinner, so
    /// the title arrives ten times a second with a different first character —
    /// and the name of the session twitched wherever it was shown. What the
    /// session is doing is already said twice over by the status dot and the
    /// state line, so the frame carries nothing here that is not noise.
    static let spinnerScalars: Set<Unicode.Scalar> = [
        "·", "•", "∙", "*", "∗", "✢", "✳", "✶", "✷", "✻", "✽",
        "◐", "◓", "◑", "◒", "◜", "◝", "◞", "◟", "⏳", "⌛",
    ]

    /// Braille cells, which is what most other spinners are made of.
    private static func isBraille(_ scalar: Unicode.Scalar) -> Bool {
        (0x2800 ... 0x28FF).contains(Int(scalar.value))
    }

    /// Drops a leading spinner frame, and only a leading spinner frame.
    ///
    /// The space after it is what makes this safe: a frame is always followed
    /// by one, while a title that genuinely begins with such a character —
    /// `*.swift`, say — is not, and keeps it.
    static func strippingSpinner(_ title: String) -> String {
        var remainder = Substring(title)
        while let first = remainder.unicodeScalars.first,
              spinnerScalars.contains(first) || isBraille(first) {
            let afterGlyph = remainder.dropFirst()
            guard let next = afterGlyph.first, next.isWhitespace else { break }
            let rest = afterGlyph.drop(while: \.isWhitespace)
            guard !rest.isEmpty else { break }
            remainder = rest
        }
        return String(remainder)
    }

    /// Strips control characters and rejects titles that carry no information.
    static func sanitise(_ raw: String) -> String? {
        let cleaned = strippingSpinner(printable(raw))

        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count <= maximumTitleLength else {
            return String(cleaned.prefix(maximumTitleLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return cleaned
    }
}
