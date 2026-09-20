import Foundation

/// Unified runtime state for every managed entity: sessions, services and
/// — through aggregation — whole projects.
///
/// The declaration order is the aggregation priority order defined in the
/// product spec: a single session waiting for input outranks everything else.
public enum RuntimeStatus: String, Codable, Sendable, CaseIterable {
    case waiting
    case error
    case working
    case starting
    case finished
    case idle
    case offline

    /// Lower value wins when several statuses are merged into one.
    public var priority: Int {
        switch self {
        case .waiting: 0
        case .error: 1
        case .working: 2
        case .starting: 3
        case .finished: 4
        case .idle: 5
        case .offline: 6
        }
    }

    /// Whether this is nothing worth marking on a project.
    ///
    /// A project is marked when something is happening in it. Idle is not
    /// something happening, and neither is a project with no sessions at all:
    /// a rail of grey dots says only that the projects exist, which their tiles
    /// already say, and the one dot that means "this one wants you" is lost
    /// among them.
    ///
    /// Switched over every case rather than defaulted, so a status added later
    /// has to answer this.
    public var isQuiet: Bool {
        switch self {
        case .idle, .offline: true
        case .waiting, .error, .working, .starting, .finished: false
        }
    }

    public var displayName: String {
        switch self {
        case .waiting: "Waiting for you"
        case .error: "Error"
        case .working: "Working"
        case .starting: "Starting"
        case .finished: "Finished"
        case .idle: "Idle"
        case .offline: "Offline"
        }
    }

    /// True while the underlying process is still alive.
    public var isLive: Bool {
        switch self {
        case .waiting, .working, .starting, .idle: true
        case .error, .finished, .offline: false
        }
    }

    public static func aggregate(_ statuses: some Sequence<RuntimeStatus>) -> RuntimeStatus {
        statuses.min(by: { $0.priority < $1.priority }) ?? .offline
    }
}
