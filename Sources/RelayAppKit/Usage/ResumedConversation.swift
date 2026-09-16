import Foundation
import RelayProtocol

/// The conversation a session was started to pick back up, when it was one.
///
/// Resuming is the one case where an agent's transcript is older than the
/// session reading it: `claude --resume` appends to the file the earlier
/// conversation left behind. Matching on when a file appeared therefore finds
/// nothing at all, and the pane with the most history behind it is the one that
/// would show no context figure.
enum ResumedConversation {
    /// Both CLIs take the identifier as the argument after the word that asks
    /// for a resume; `--continue` and `--last` name no conversation, and the
    /// honest answer there is that the command does not say which one it is.
    static func identifier(in command: [String], kind: SessionKind) -> String? {
        let keywords: Set<String> = switch kind {
        case .claude: ["--resume", "-r"]
        case .codex: ["resume"]
        default: []
        }
        guard !keywords.isEmpty else { return nil }

        for (index, argument) in command.enumerated() where keywords.contains(argument) {
            guard let candidate = command[safe: index + 1], !candidate.hasPrefix("-") else { continue }
            return candidate
        }
        return nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
