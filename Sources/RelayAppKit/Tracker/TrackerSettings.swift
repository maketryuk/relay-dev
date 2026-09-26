import Foundation
import RelayTracker

/// How Relay reaches the issue tracker, as the workspace file keeps it.
///
/// The token is not here: it is in the keychain, where a file copied off the
/// machine or pasted into a bug report cannot take it along.
struct TrackerSettings: Codable, Equatable {
    /// Which tracker, or nil for none — the whole feature switched off.
    var kind: TrackerKind?
    /// The instance's address, as `YouTrackConnection.address` normalised it.
    var address: String
    /// Who the token was last seen to belong to. Shown before the tracker has
    /// been asked again, which it is not at launch: a request per launch for a
    /// name already known is a request nobody needed.
    var user: TrackerUser?
    /// The board each project shows, by project identifier.
    var boards: [String: String]
    /// Where each tracker project's issues were last handed, by the tracker's
    /// project identifier: the Relay project they were started in. A board can
    /// hold several codebases' issues — a site's and an app's — and the one an
    /// issue belongs in is the one it went to last time.
    var destinations: [String: String]
    /// How each board is laid out here — columns merged and hidden — by board
    /// identifier. Absent is as the tracker lays it out.
    var layouts: [String: BoardLayout]
    /// The one timer, kept across a relaunch because the work it is timing
    /// does not stop when the app does.
    var timer: TrackerTimer?

    init(
        kind: TrackerKind? = nil,
        address: String = "",
        user: TrackerUser? = nil,
        boards: [String: String] = [:],
        destinations: [String: String] = [:],
        layouts: [String: BoardLayout] = [:],
        timer: TrackerTimer? = nil
    ) {
        self.kind = kind
        self.address = address
        self.user = user
        self.boards = boards
        self.destinations = destinations
        self.layouts = layouts
        self.timer = timer
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // A tracker this build does not know is no tracker, rather than a
        // workspace that fails to open.
        kind = try? container.decodeIfPresent(TrackerKind.self, forKey: .kind)
        address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        user = try? container.decodeIfPresent(TrackerUser.self, forKey: .user)
        boards = try container.decodeIfPresent([String: String].self, forKey: .boards) ?? [:]
        destinations = (try? container.decodeIfPresent([String: String].self, forKey: .destinations)) ?? [:]
        layouts = (try? container.decodeIfPresent([String: BoardLayout].self, forKey: .layouts)) ?? [:]
        timer = try? container.decodeIfPresent(TrackerTimer.self, forKey: .timer)
    }
}

/// Time being measured against one issue.
///
/// Paused rather than stopped when it is stopped: the time is still owed to the
/// issue until it has been logged or thrown away, and a timer that forgot it
/// on a misclick would be one nobody trusted.
struct TrackerTimer: Codable, Equatable {
    var key: String
    var summary: String
    /// The issue's project, for the kinds of work time can be logged as.
    var project: TrackerProject?
    /// When it was last started; nil while it is paused.
    var startedAt: Date?
    /// What it measured before it was last started.
    var accumulated: TimeInterval

    init(key: String, summary: String, project: TrackerProject?, startedAt: Date?, accumulated: TimeInterval = 0) {
        self.key = key
        self.summary = summary
        self.project = project
        self.startedAt = startedAt
        self.accumulated = accumulated
    }

    var isRunning: Bool { startedAt != nil }

    func elapsed(at now: Date) -> TimeInterval {
        // A clock set back while the app was closed must not make time negative.
        accumulated + max(0, startedAt.map { now.timeIntervalSince($0) } ?? 0)
    }

    mutating func pause(at now: Date) {
        guard startedAt != nil else { return }
        accumulated = elapsed(at: now)
        startedAt = nil
    }

    mutating func resume(at now: Date) {
        guard startedAt == nil else { return }
        startedAt = now
    }
}
