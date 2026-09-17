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

/// What the user says their Claude sessions run with.
///
/// A setting, because nothing on disk answers it outright: Claude Code records
/// the model without the suffix that tells its long-context variant apart, so a
/// session on the 1M window is indistinguishable from one on 200K until more
/// than 200K has been put in it. Automatic is right for most people most of the
/// time and never claims a window larger than it can show was used; this is
/// here for the person who knows which one they picked.
enum ContextWindowPreference: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Inferred: whatever the evidence supports, never less than what has
    /// already been sent.
    case automatic
    case standard
    case long

    var id: String { rawValue }

    /// The window this says outright, or nil to work it out.
    var tokens: Int? {
        switch self {
        case .automatic: nil
        case .standard: 200_000
        case .long: ClaudeModelWindow.long
        }
    }

    @MainActor
    var displayName: String {
        switch self {
        case .automatic: relayLocalized("Automatic")
        case .standard: "200K"
        case .long: "1M"
        }
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

    /// Takes a wider window on evidence, never a narrower one.
    ///
    /// Evidence — which model the project last ran — can say that a window is
    /// larger than the smallest one that fits, and cannot say that it is
    /// smaller than what has already been put in it.
    static func widening(_ window: Int?, toAtLeast candidate: Int?) -> Int? {
        guard let candidate, candidate > 0 else { return window }
        guard let window else { return candidate }
        return max(window, candidate)
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
