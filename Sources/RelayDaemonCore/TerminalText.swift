import Foundation

/// Helpers for turning raw PTY bytes into text that heuristics can match on.
public enum TerminalText {
    /// Strips CSI/OSC/charset escape sequences and carriage-return overdraw so
    /// pattern matching sees roughly what the user sees.
    public static func plainText(from data: Data) -> String {
        let source = String(decoding: data, as: UTF8.self)
        var output = String()
        output.reserveCapacity(source.count)

        var iterator = source.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        while let scalar = pending ?? iterator.next() {
            pending = nil
            guard scalar == "\u{1B}" else {
                output.unicodeScalars.append(scalar)
                continue
            }
            guard let next = iterator.next() else { break }
            switch next {
            case "[":
                // CSI: parameters/intermediates until a final byte in @–~.
                while let parameter = iterator.next() {
                    if parameter.value >= 0x40, parameter.value <= 0x7E { break }
                }
            case "]":
                // OSC: terminated by BEL or ST.
                var previous: Unicode.Scalar = " "
                while let parameter = iterator.next() {
                    if parameter == "\u{07}" { break }
                    if previous == "\u{1B}", parameter == "\\" { break }
                    previous = parameter
                }
            case "(", ")", "#", "%":
                _ = iterator.next()
            default:
                if next == "\u{1B}" { pending = next }
            }
        }

        return collapseCarriageReturns(output)
    }

    /// A spinner repaints the same line with `\r`; only the last paint matters.
    private static func collapseCarriageReturns(_ text: String) -> String {
        text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.split(separator: "\r", omittingEmptySubsequences: false).last.map(String.init) ?? "" }
            .joined(separator: "\n")
    }

    /// Last `limit` characters, which is all any heuristic needs.
    public static func tail(of text: String, limit: Int = 2000) -> String {
        guard text.count > limit else { return text }
        return String(text.suffix(limit))
    }

    /// Last non-empty line, trimmed — the usual place a prompt lives.
    public static func lastMeaningfulLine(of text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}
