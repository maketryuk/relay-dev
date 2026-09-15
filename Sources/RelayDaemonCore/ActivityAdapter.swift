import Foundation
import RelayProtocol

/// What a session looks like once its output has gone quiet.
public enum QuietVerdict: Sendable {
    case waitingForUser
    case completed
    case idle
}

/// Per-CLI interpretation of terminal activity.
///
/// Adapters are advisory only: a wrong verdict changes a status dot, never the
/// behaviour of the session itself.
public protocol ActivityAdapter: Sendable {
    /// - Parameters:
    ///   - tail: recent output with escape sequences stripped.
    ///   - producedOutput: whether the process wrote anything since the user
    ///     last sent input. Distinguishes "finished a task" from "sitting idle".
    func verdict(tail: String, producedOutput: Bool) -> QuietVerdict

    /// Whether the tail shows the agent working *now*.
    ///
    /// Agents say so themselves — every one of them offers a way to interrupt
    /// while it is busy — and asking the screen is worth more than any amount
    /// of inference from the timing and volume of bytes, which is how a slowly
    /// redrawing spinner came to read as an idle session.
    func isBusy(tail: String) -> Bool
}

public extension ActivityAdapter {
    func isBusy(tail _: String) -> Bool { false }
}

public enum ActivityAdapters {
    public static func adapter(for kind: SessionKind) -> any ActivityAdapter {
        switch kind {
        case .shell, .ssh, .custom: ShellActivityAdapter()
        case .claude, .codex, .gemini, .opencode: AgentActivityAdapter()
        }
    }

    /// Prompts that mean "the process will not continue until you answer".
    static let universalPromptPatterns: [String] = [
        "(y/n)", "[y/n]", "(yes/no)", "[yes/no]", "(y/n/a)",
        "password:", "passphrase", "are you sure",
        "press enter to continue", "press any key",
        "do you want to", "would you like to",
        "overwrite?", "continue?", "proceed?",
        "? (use arrow keys)", "select an option",
        "please confirm", "confirmation required",
    ]
}

public struct ShellActivityAdapter: ActivityAdapter {
    public init() {}

    public func verdict(tail: String, producedOutput: Bool) -> QuietVerdict {
        let lowered = tail.lowercased()
        if ActivityAdapters.universalPromptPatterns.contains(where: { lowered.contains($0) }) {
            return .waitingForUser
        }
        let lastLine = TerminalText.lastMeaningfulLine(of: tail)
        if looksLikeShellPrompt(lastLine) {
            return producedOutput ? .completed : .idle
        }
        return .idle
    }

    /// Bare prompts end in one of these. Themed prompts (oh-my-zsh, starship,
    /// powerlevel10k) instead *begin* with a glyph and end with git decoration
    /// such as `git:(main)`, so both ends are checked. The leading set is kept
    /// deliberately narrow: ordinary output lines rarely start with these, while
    /// a line starting with `$` or `>` is common in logs and documentation.
    private func looksLikeShellPrompt(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, let first = trimmed.first else { return false }
        return "$%#>❯➜»".contains(last) || "❯➜»".contains(first)
    }
}

public struct AgentActivityAdapter: ActivityAdapter {
    public init() {}

    /// Interactive choice UI rendered by Claude Code, Codex and friends.
    private static let choicePatterns: [String] = [
        "❯ 1.", "❯ 1)", "1. yes", "2. no",
        "y/n", "allow this", "allow tool", "approve",
        "do you want", "should i", "confirm",
        "waiting for your", "awaiting input",
        "[y] yes", "(a)lways",
    ]

    /// What an agent shows while it is working. Every one of them offers a way
    /// out of a running turn, and says so on the same line as the spinner.
    private static let busyPatterns: [String] = [
        "esc to interrupt",
        "ctrl+c to stop",
        "press esc to stop",
        "interrupting…",
    ]

    /// Idle input boxes: the agent finished and is offering the next prompt.
    private static let inputBoxPatterns: [String] = [
        "│ >", "| >", "> ", "❯", "try \"", "/help for help",
        "press up to", "shift+tab", "esc to clear",
    ]

    public func isBusy(tail: String) -> Bool {
        let lowered = tail.lowercased()
        // A choice on screen outranks a spinner behind it: the agent may still
        // be rendering, but it is not going anywhere until it is answered.
        guard !Self.choicePatterns.contains(where: { lowered.contains($0) }) else { return false }
        return Self.busyPatterns.contains { lowered.contains($0) }
    }

    public func verdict(tail: String, producedOutput: Bool) -> QuietVerdict {
        let lowered = tail.lowercased()
        if Self.choicePatterns.contains(where: { lowered.contains($0) }) {
            return .waitingForUser
        }
        if ActivityAdapters.universalPromptPatterns.contains(where: { lowered.contains($0) }) {
            return .waitingForUser
        }
        if producedOutput {
            return .completed
        }
        if Self.inputBoxPatterns.contains(where: { lowered.contains($0) }) {
            return .idle
        }
        return .idle
    }
}
