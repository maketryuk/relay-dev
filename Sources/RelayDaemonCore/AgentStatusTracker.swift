import Foundation
import RelayProtocol

/// What an agent's terminal title says it is doing.
enum AgentTitleActivity: Equatable {
    case working
    case idle
    case waiting
}

/// Reads the state an agent announces in its terminal title.
///
/// Claude Code puts `✳` before its title when it is waiting for a prompt and
/// a spinner frame there while it works; Codex draws a Braille spinner; Gemini
/// has a glyph for each state. These are the agents' own words, where the text
/// on screen is only something to guess from. A title with none of them is not
/// an agent's, and says nothing.
enum AgentTitle {
    static func classify(_ title: String) -> AgentTitleActivity? {
        guard let first = title.unicodeScalars.first else { return nil }
        switch first {
        case "✳", "◇": return .idle
        case "◐", "◑", "◒", "◓", "✦", "⏲": return .working
        case "✋": return .waiting
        default: break
        }
        if (0x2800 ... 0x28FF).contains(first.value) { return .working }
        if title.range(of: "action required", options: .caseInsensitive) != nil { return .waiting }
        return nil
    }
}

/// The status an agent's own signals give it, when they give one.
///
/// Its hooks come first: the agent reports every prompt, tool call, permission
/// prompt and end of turn itself, and that is not an inference. The title
/// comes second, for an agent whose hooks are not installed or have gone quiet.
/// Neither is a reading of the screen, which is what the adapters did: a
/// spinner line left behind in the scrollback kept a finished agent "working",
/// and a sentence ending in a question mark made one "wait".
///
/// A value type with the clock passed in, so every rule can be exercised
/// without an agent.
struct AgentStatusTracker {
    /// A hook older than this is no longer believed over the title. Long
    /// enough for any tool call.
    static let hookFreshness: TimeInterval = 30 * 60
    /// A spinner that has not moved for this long has stopped, whatever frame
    /// it stopped on — Codex can leave one behind.
    static let staleSpinner: TimeInterval = 3
    /// How long the idle mark must stay up after the last hook said "working"
    /// before the turn counts as interrupted. No hook fires when the person
    /// cancels one, and the mark is how the agent says it gave up.
    static let idleTitleHold: TimeInterval = 1.5
    /// How long an answer to a prompt waits for a hook to say what came of it
    /// before the title is asked instead.
    static let answerGrace: TimeInterval = 1

    enum HookState: Equatable {
        case working
        case waiting(Wait)
        case finished
        case idle
    }

    struct Wait: Equatable {
        enum Kind: Equatable {
            /// Permission to run a tool. Held until that tool runs: an agent
            /// running several tools at once reports the others meanwhile.
            case permission
            /// A question put to the person, which only an answer ends.
            case question
        }

        var kind: Kind
        var toolName: String?
        var toolUseID: String?
    }

    private(set) var hookState: HookState?
    private var hookAt: Date?
    /// Claude asks for permission without saying which call it is about, and
    /// names it only in the `PreToolUse` before and the `PostToolUse` after.
    private var lastToolCall: (name: String, id: String)?
    /// A key that answers a prompt or cancels a turn, and when it was pressed.
    private var releasedAt: Date?

    private var title: AgentTitleActivity?
    private var titleAt: Date?
    private var titleChangedAt: Date?
    /// Whether the title has shown work since the agent last sat down, which is
    /// what makes its return to idle a finished turn rather than a start.
    private var titleShowedWork = false

    /// Whether anything the agent said is still in force.
    func isAuthoritative(now: Date) -> Bool {
        isHookFresh(now: now) || title != nil
    }

    // MARK: - Hooks

    mutating func apply(_ event: AgentHookEvent, at now: Date) {
        if event.subagentID != nil {
            // A subagent works inside the main agent's turn, which says so
            // itself. What it can change is a wait: starting one when it needs
            // the person, and ending the one it started.
            if let wait = Self.wait(for: event) {
                record(.waiting(wait), at: now)
            } else if case let .waiting(wait) = hookState, Self.ends(wait, event) {
                record(.working, at: now)
            }
            return
        }

        switch event.name {
        case "SessionStart":
            // A compaction restarts the session in the middle of a turn.
            guard ["startup", "resume", "clear"].contains(event.source ?? "") else { return }
            lastToolCall = nil
            titleShowedWork = false
            record(.idle, at: now)

        case "SessionEnd":
            hookState = nil
            hookAt = nil
            releasedAt = nil

        case "UserPromptSubmit":
            record(.working, at: now)

        case "PreToolUse":
            if let wait = Self.wait(for: event), wait.kind == .question {
                record(.waiting(wait), at: now)
                return
            }
            if let name = event.toolName, let id = event.toolUseID { lastToolCall = (name, id) }
            resume(after: event, at: now)

        case "PermissionRequest":
            guard var wait = Self.wait(for: event) else { return }
            if wait.toolUseID == nil, let call = lastToolCall, call.name == wait.toolName {
                wait.toolUseID = call.id
            }
            record(.waiting(wait), at: now)

        case "PostToolUse", "PostToolUseFailure":
            resume(after: event, at: now)

        case "Stop", "StopFailure":
            record(.finished, at: now)

        default:
            break
        }
    }

    /// A tool ran, or is about to: working again, unless what is being waited
    /// for is something else.
    private mutating func resume(after event: AgentHookEvent, at now: Date) {
        if case let .waiting(wait) = hookState, !Self.ends(wait, event) {
            // Still asking; but the agent is alive and talking.
            hookAt = now
            return
        }
        record(.working, at: now)
    }

    private static func ends(_ wait: Wait, _ event: AgentHookEvent) -> Bool {
        switch wait.kind {
        case .question:
            return event.name != "PreToolUse" && event.toolName == wait.toolName
        case .permission:
            if let id = wait.toolUseID { return event.toolUseID == id }
            return event.toolName == wait.toolName
        }
    }

    private static func wait(for event: AgentHookEvent) -> Wait? {
        let asks = isQuestion(event.toolName)
        switch event.name {
        case "PermissionRequest":
            return Wait(kind: asks ? .question : .permission, toolName: event.toolName, toolUseID: event.toolUseID)
        case "PreToolUse" where asks:
            return Wait(kind: .question, toolName: event.toolName, toolUseID: event.toolUseID)
        default:
            return nil
        }
    }

    /// Claude's `AskUserQuestion` and Codex's `request_user_input`: tools that
    /// are allowed to run and then block on a person.
    static func isQuestion(_ toolName: String?) -> Bool {
        let letters = (toolName ?? "").lowercased().filter { $0.isLetter || $0.isNumber }
        return letters == "askuserquestion" || letters == "requestuserinput"
    }

    private mutating func record(_ state: HookState, at now: Date) {
        hookState = state
        hookAt = now
        releasedAt = nil
    }

    private func isHookFresh(now: Date) -> Bool {
        guard hookState != nil, let hookAt else { return false }
        return now.timeIntervalSince(hookAt) < Self.hookFreshness
    }

    // MARK: - Title and keys

    mutating func noteTitle(_ raw: String, at now: Date) {
        let activity = AgentTitle.classify(raw)
        titleAt = now
        if activity != title {
            title = activity
            titleChangedAt = now
        }
        if activity == .working { titleShowedWork = true }
    }

    /// Keys that end a wait or a turn without the agent saying so: an answer
    /// chosen in a prompt, or a cancel. What came of it is left to the next
    /// hook, or to the title if none comes.
    mutating func noteInput(_ data: Data, at now: Date) {
        guard let state = hookState, isHookFresh(now: now) else { return }
        switch state {
        case .waiting where Self.answers.contains(data) || Self.cancels.contains(data):
            releasedAt = now
        case .working where Self.cancels.contains(data):
            releasedAt = now
        default:
            break
        }
    }

    private static let answers: Set<Data> = Set(
        ["\r", "\n", "\r\n", "\u{1B}[13u", "1", "2", "3", "4", "5", "6", "7", "8", "9"].map { Data($0.utf8) }
    )
    private static let cancels: Set<Data> = Set(["\u{1B}", "\u{03}"].map { Data($0.utf8) })

    /// The agent is gone and the shell has the terminal back.
    mutating func forgetAgent() {
        hookState = nil
        hookAt = nil
        releasedAt = nil
        lastToolCall = nil
        title = nil
        titleAt = nil
        titleChangedAt = nil
        titleShowedWork = false
    }

    var hasEvidence: Bool { hookState != nil || title != nil }

    // MARK: - Verdict

    func status(now: Date) -> RuntimeStatus? {
        guard let hookState, let hookAt, isHookFresh(now: now) else {
            return statusFromTitle(now: now, afterWork: .finished)
        }
        let released = releasedAt.map { now.timeIntervalSince($0) >= Self.answerGrace } ?? false

        switch hookState {
        case .waiting:
            return released ? statusFromTitle(now: now, afterWork: .idle) ?? .working : .waiting
        case .working:
            if released { return statusFromTitle(now: now, afterWork: .idle) ?? .idle }
            if title == .idle, let changed = titleChangedAt, changed > hookAt,
               now.timeIntervalSince(changed) >= Self.idleTitleHold {
                return .idle
            }
            return .working
        case .finished:
            return .finished
        case .idle:
            return .idle
        }
    }

    private func statusFromTitle(now: Date, afterWork: RuntimeStatus) -> RuntimeStatus? {
        guard let title else { return nil }
        switch title {
        case .working:
            let isMoving = titleAt.map { now.timeIntervalSince($0) < Self.staleSpinner } ?? false
            return isMoving ? .working : afterWork
        case .waiting:
            return .waiting
        case .idle:
            return titleShowedWork ? afterWork : .idle
        }
    }
}
