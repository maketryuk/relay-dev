import Foundation
import RelayProtocol

/// What Relay is allowed to interrupt the user for.
struct NotificationSettings: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var waitingForInput: Bool
    var failures: Bool
    var completions: Bool
    /// Projects the user muted individually.
    var mutedProjectIDs: [String]

    init(
        isEnabled: Bool = true,
        waitingForInput: Bool = true,
        failures: Bool = true,
        completions: Bool = true,
        mutedProjectIDs: [String] = []
    ) {
        self.isEnabled = isEnabled
        self.waitingForInput = waitingForInput
        self.failures = failures
        self.completions = completions
        self.mutedProjectIDs = mutedProjectIDs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        waitingForInput = try container.decodeIfPresent(Bool.self, forKey: .waitingForInput) ?? true
        failures = try container.decodeIfPresent(Bool.self, forKey: .failures) ?? true
        completions = try container.decodeIfPresent(Bool.self, forKey: .completions) ?? true
        mutedProjectIDs = try container.decodeIfPresent([String].self, forKey: .mutedProjectIDs) ?? []
    }

    func isMuted(_ projectID: ProjectID) -> Bool {
        mutedProjectIDs.contains(projectID.rawValue)
    }

    mutating func toggleMute(_ projectID: ProjectID) {
        if let index = mutedProjectIDs.firstIndex(of: projectID.rawValue) {
            mutedProjectIDs.remove(at: index)
        } else {
            mutedProjectIDs.append(projectID.rawValue)
        }
    }
}

enum NotificationKind: String, Sendable {
    case waitingForInput
    case failed
    case finished
}

/// A notification Relay has decided is worth showing.
struct AttentionEvent: Sendable, Hashable {
    var kind: NotificationKind
    var sessionID: SessionID
    var title: String
    var body: String
}

/// Decides whether a status change deserves a macOS notification.
///
/// Kept free of UserNotifications so the policy — which is the part that gets
/// annoying when it is wrong — can be tested exhaustively.
enum NotificationPolicy {
    struct Context {
        var previous: RuntimeStatus
        var current: RuntimeStatus
        var session: SessionSnapshot
        var projectName: String
        /// True when this exact session is on screen in an active window; the
        /// user does not need telling about what they are already looking at.
        var isVisibleToUser: Bool
        var settings: NotificationSettings
    }

    static func event(for context: Context) -> AttentionEvent? {
        guard context.settings.isEnabled else { return nil }
        guard !context.settings.isMuted(context.session.projectID) else { return nil }
        // Only transitions are interesting; a repeated status is not news.
        guard context.previous != context.current else { return nil }
        guard !context.isVisibleToUser else { return nil }

        let session = context.session
        let label = "\(context.projectName) · \(session.name)"

        switch context.current {
        case .waiting:
            guard context.settings.waitingForInput else { return nil }
            return AttentionEvent(
                kind: .waitingForInput,
                sessionID: session.id,
                title: "\(session.name) needs you",
                body: "\(label) is waiting for input."
            )

        case .error:
            guard context.settings.failures else { return nil }
            let detail = session.exitCode.map { "exited with code \($0)" } ?? "reported an error"
            return AttentionEvent(
                kind: .failed,
                sessionID: session.id,
                title: "\(session.name) failed",
                body: "\(label) \(detail)."
            )

        case .finished:
            guard context.settings.completions else { return nil }
            // A shell returning to its prompt after `ls` is not an achievement.
            // Only agents and services get to announce completion, and only when
            // they were actually working.
            guard announcesCompletion(session), context.previous == .working else { return nil }
            return AttentionEvent(
                kind: .finished,
                sessionID: session.id,
                title: "\(session.name) finished",
                body: "\(label) completed its work."
            )

        default:
            return nil
        }
    }

    private static func announcesCompletion(_ session: SessionSnapshot) -> Bool {
        if session.role.isService { return true }
        switch session.kind {
        case .claude, .codex, .gemini, .opencode: return true
        case .shell, .ssh, .custom: return false
        }
    }
}
