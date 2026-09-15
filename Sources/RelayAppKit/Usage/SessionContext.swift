import Foundation
import RelayProtocol
import RelayUI

/// A part of what is sitting in an agent's context window.
///
/// Only the divisions the agents actually report. Claude Code's own `/context`
/// also breaks the window down by MCP tools, rules and messages; none of that
/// reaches disk, and inventing it from the size of a server's tool schemas would
/// be a guess wearing the clothes of a measurement.
struct ContextSlice: Equatable, Identifiable, Sendable {
    enum Kind: String, Sendable {
        /// Read back from the prompt cache — the bulk of a long conversation.
        case cached
        /// Written to the cache on this turn.
        case newlyCached
        /// Sent fresh, paying full price.
        case fresh
        case output
        case reasoning
    }

    var kind: Kind
    var tokens: Int

    var id: String { kind.rawValue }

    @MainActor
    var name: String {
        switch kind {
        case .cached: relayLocalized("Cached")
        case .newlyCached: relayLocalized("Newly cached")
        case .fresh: relayLocalized("Fresh")
        case .output: relayLocalized("Output")
        case .reasoning: relayLocalized("Reasoning")
        }
    }
}

/// How full one session's context window is.
struct SessionContext: Equatable, Sendable {
    /// What was in the window on the last turn.
    var tokens: Int
    var window: Int?
    /// True when the provider stated the window rather than Relay inferring it.
    var isWindowDeclared: Bool
    var model: String?
    var slices: [ContextSlice]
    /// When the agent last wrote this down.
    var measuredAt: Date?

    var fraction: Double? {
        guard let window, window > 0 else { return nil }
        return min(Double(tokens) / Double(window), 1)
    }

    var percent: Int? {
        fraction.map { Int(($0 * 100).rounded()) }
    }
}

/// Works out how large a context window is when nobody says.
///
/// Codex states its window outright. Claude Code does not record one anywhere,
/// and the transcript names the model without the suffix that distinguishes the
/// long-context variant — so the window has to be inferred, and the one thing
/// that can be relied on is that a window cannot be smaller than what has
/// already been put in it.
enum ContextWindow {
    /// The sizes Relay knows about, smallest first.
    static let known = [200_000, 1_000_000]

    static func resolve(observed: Int, declared: Int?) -> Int? {
        if let declared, declared > 0 { return declared }
        guard observed > 0 else { return nil }
        return known.first { $0 >= observed } ?? known.last
    }
}

/// Short forms for numbers that are always large: `813K`, `1.2M`.
enum TokenFormatting {
    static func short(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000...:
            let millions = Double(tokens) / 1_000_000
            return String(format: millions < 10 ? "%.1fM" : "%.0fM", millions)
        case 1_000...:
            return "\(tokens / 1_000)K"
        default:
            return "\(tokens)"
        }
    }
}
