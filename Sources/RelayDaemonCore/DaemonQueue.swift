import Foundation

/// All daemon state lives on this single serial queue.
///
/// PTY reads, socket reads, timers and client writes are all dispatched here,
/// which gives us two properties we need: mutual exclusion without locks, and —
/// critically — strict FIFO ordering of terminal output chunks. An actor would
/// not guarantee the latter, because `Task` ordering is unspecified.
public enum DaemonQueue {
    /// Lets code detect whether it is already running on the daemon queue and
    /// avoid a self-deadlocking `sync`.
    public static let identityKey = DispatchSpecificKey<Bool>()

    public static let shared: DispatchQueue = {
        let queue = DispatchQueue(label: "studio.lince.relay.daemon", qos: .userInitiated)
        queue.setSpecific(key: identityKey, value: true)
        return queue
    }()

    /// Marks a call site that must already be running on `shared`.
    @inline(__always)
    public static func assertIsolated(_ function: StaticString = #function) {
        dispatchPrecondition(condition: .onQueue(shared))
    }
}
