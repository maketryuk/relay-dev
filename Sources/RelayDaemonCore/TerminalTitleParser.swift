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

    /// Feeds raw output and returns the most recent title it completed, if any.
    public mutating func consume(_ data: Data) -> String? {
        var latest: String?

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
                    latest = title(from: buffer) ?? latest
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
                    latest = title(from: buffer) ?? latest
                    state = .normal
                } else {
                    // A stray escape inside the payload.
                    buffer.append(0x1B)
                    buffer.append(byte)
                    state = .sequence
                }
            }
        }

        return latest
    }

    /// `Ps ; text`, where 0, 1 and 2 all set a title of some kind.
    private func title(from payload: [UInt8]) -> String? {
        guard let separator = payload.firstIndex(of: 0x3B) else { return nil }
        let code = String(decoding: payload[payload.startIndex ..< separator], as: UTF8.self)
        guard ["0", "1", "2"].contains(code) else { return nil }

        let text = String(decoding: payload[payload.index(after: separator)...], as: UTF8.self)
        return Self.sanitise(text)
    }

    /// Strips control characters and rejects titles that carry no information.
    static func sanitise(_ raw: String) -> String? {
        let cleaned = raw
            .unicodeScalars
            .filter { !$0.properties.isDefaultIgnorableCodePoint && ($0.value >= 0x20 || $0 == " ") }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return nil }
        guard cleaned.count <= maximumTitleLength else {
            return String(cleaned.prefix(maximumTitleLength)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return cleaned
    }
}
