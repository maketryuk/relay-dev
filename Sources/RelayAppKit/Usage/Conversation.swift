import Foundation
import RelayProtocol

/// A past conversation with an agent, wherever it was started.
///
/// Relay's own history only ever knew about sessions Relay ran, which is a
/// strange thing to tell someone who also uses the same CLI from a terminal.
/// These come from the transcripts the agents keep, so the list is the same one
/// their own `/resume` offers.
struct Conversation: Identifiable, Equatable, Sendable {
    /// The identifier the CLI resumes by.
    var id: String
    var kind: SessionKind
    var title: String
    /// The last thing the user said, when the transcript records it.
    var lastPrompt: String?
    var branch: String?
    var updatedAt: Date

    /// What to run to pick the conversation back up.
    var resumeCommand: [String] {
        switch kind {
        case .codex: ["codex", "resume", id]
        default: ["claude", "--resume", id]
        }
    }

    /// The name a resumed session takes in the sidebar.
    var sessionName: String {
        title.isEmpty ? kind.displayName : title
    }
}

enum ConversationSorting {
    /// Newest first: the one you want is almost always the one you just left.
    static func byRecency(_ conversations: [Conversation]) -> [Conversation] {
        conversations.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Trims a prompt to something a row can hold without losing the sense of
    /// it — a first line is nearly always the request.
    static func summary(of prompt: String, limit: Int = 120) -> String {
        let firstLine = prompt
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? prompt
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
