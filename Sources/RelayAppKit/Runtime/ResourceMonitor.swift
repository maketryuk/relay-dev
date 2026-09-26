import AppKit
import Foundation
import Observation
import RelayProtocol
import RelayUI

/// What a group of processes is using now.
struct ResourceUsage: Equatable, Sendable {
    /// Percent of one core, the way Activity Monitor counts it: a process busy
    /// on two cores is at 200%. Nil until there have been two readings to
    /// compare.
    var cpu: Double?
    var footprint: UInt64
    var processes: Int

    /// The CPU spent between two readings of one group, over the time between
    /// them.
    ///
    /// Nil when the readings cannot be compared honestly. A process that left
    /// the tree — reparented to launchd by a `nohup` — takes its time with it
    /// and the total goes down; one that joins it carrying its whole lifetime
    /// — the daemon reaped by the window after a changeover — makes it jump by
    /// more than every core could have spent. Either way the difference is
    /// bookkeeping rather than work, and the monitor keeps the figure it had.
    static func between(
        _ earlier: GroupCost?,
        _ later: GroupCost,
        over elapsed: UInt64,
        cores: Int
    ) -> ResourceUsage {
        var usage = ResourceUsage(cpu: nil, footprint: later.footprint, processes: later.processes)
        guard let earlier, elapsed > 0, later.cpu >= earlier.cpu else { return usage }
        let spent = Double(later.cpu - earlier.cpu)
        guard spent <= Double(elapsed) * Double(max(cores, 1)) * 1.05 else { return usage }
        usage.cpu = spent / Double(elapsed) * 100
        return usage
    }

    /// Everything added up. The CPU is nil only when none of it is known yet,
    /// so that one session just started does not blank the total.
    static func total(_ usages: some Collection<ResourceUsage>) -> ResourceUsage {
        let known = usages.compactMap(\.cpu)
        return ResourceUsage(
            cpu: known.isEmpty ? nil : known.reduce(0, +),
            footprint: usages.reduce(0) { $0 &+ $1.footprint },
            processes: usages.reduce(0) { $0 + $1.processes }
        )
    }
}

/// The processes to measure, as the model knows them.
struct ResourceRoots: Sendable {
    /// Each live session by the process it started.
    var sessions: [SessionID: Int32] = [:]
    /// The daemon at the other end of the socket.
    var daemon: Int32?
}

/// Keeps the status bar's CPU and memory figures current.
///
/// Measured in the window rather than in the daemon: the window already knows
/// every session's process, both run as the same user, and reading the kernel
/// needs nothing the daemon has. So nothing crosses the socket, and a daemon
/// inherited from the previous build is measured the same as a new one.
///
/// Cheap by construction — syscalls, never a fork — and cheaper by schedule:
/// every few seconds while the bar is all that shows, more often while the
/// popover is open, and not at all while the window cannot be seen.
@MainActor
@Observable
final class ResourceMonitor {
    /// Often enough for a bar to follow a build, and averaged over enough
    /// time that it does not flicker between two numbers.
    static let glanceInterval: Duration = .seconds(5)
    /// While the popover is open: someone is looking for the one to close.
    static let watchedInterval: Duration = .seconds(2)
    /// A first reading has nothing to compare with, so the second follows it
    /// quickly rather than leaving CPU blank for a whole interval.
    static let settlingInterval: Duration = .seconds(1)

    private(set) var sessions: [SessionID: ResourceUsage] = [:]
    private(set) var relay: ResourceUsage?

    /// Asked at every reading, so a session started a moment ago is in the
    /// next one without anybody having to say so.
    @ObservationIgnored var roots: @MainActor () -> ResourceRoots = { ResourceRoots() }

    @ObservationIgnored private var isWatched = false
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var previous: ResourceSurvey?
    @ObservationIgnored private var occlusionObserver: NSObjectProtocol?

    /// Every live session together.
    var total: ResourceUsage {
        ResourceUsage.total(sessions.values)
    }

    /// The sessions and Relay itself: what the whole of it costs the Mac,
    /// which with no session open is the window and the daemon alone.
    var overall: ResourceUsage {
        ResourceUsage.total(Array(sessions.values) + (relay.map { [$0] } ?? []))
    }

    func start() {
        guard task == nil else { return }
        schedule()
        // Readings stop while the window is hidden; coming back should not mean
        // looking at figures from before it was hidden for a whole interval.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.task != nil, Self.isVisible else { return }
                self.schedule()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        previous = nil
        sessions = [:]
        relay = nil
    }

    /// Set while the popover is open. Reads at once, since whatever is
    /// showing is up to an interval old.
    func setWatched(_ watched: Bool) {
        guard watched != isWatched else { return }
        isWatched = watched
        if task != nil { schedule() }
    }

    private func schedule() {
        task?.cancel()
        task = Task { [weak self] in
            var pause = Self.settlingInterval
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: pause)
                pause = self?.isWatched == true ? Self.watchedInterval : Self.glanceInterval
            }
        }
    }

    private static var isVisible: Bool {
        NSApp.occlusionState.contains(.visible)
    }

    func refresh() async {
        guard Self.isVisible else {
            // A difference taken across the time away would be an average of
            // it, shown as if it were now.
            previous = nil
            return
        }
        let roots = roots()
        let app = getpid()
        let now = DispatchTime.now().uptimeNanoseconds
        let survey = await Task.detached(priority: .utility) {
            ResourceSurvey.take(
                sessions: roots.sessions,
                app: app,
                daemon: roots.daemon,
                table: KernelProcessTable(),
                at: now
            )
        }.value
        guard !Task.isCancelled else { return }
        adopt(survey)
    }

    private func adopt(_ survey: ResourceSurvey) {
        let elapsed = previous.map { survey.takenAt &- $0.takenAt } ?? 0
        let cores = ProcessInfo.processInfo.activeProcessorCount

        var measured: [SessionID: ResourceUsage] = [:]
        for (id, reading) in survey.sessions {
            let earlier = previous?.sessions[id].flatMap { $0.root == reading.root ? $0.cost : nil }
            var usage = ResourceUsage.between(earlier, reading.cost, over: elapsed, cores: cores)
            if usage.cpu == nil, earlier != nil { usage.cpu = sessions[id]?.cpu }
            measured[id] = usage
        }
        var own = ResourceUsage.between(previous?.relay, survey.relay, over: elapsed, cores: cores)
        if own.cpu == nil, previous != nil { own.cpu = relay?.cpu }

        sessions = measured
        relay = own
        previous = survey
    }
}

/// How the figures are written, in the bar and in the popover alike.
@MainActor
enum ResourceFormatting {
    /// A decimal place where it tells two quiet sessions apart, none where it
    /// would only jitter.
    static func cpu(_ percent: Double?) -> String {
        guard let percent else { return "–" }
        if percent < 0.05 { return "0%" }
        if percent < 10 { return String(format: "%.1f%%", percent) }
        return String(format: "%.0f%%", percent)
    }

    /// In the binary units Activity Monitor uses, so the two agree.
    static func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes < 1_000 {
            return String(format: relayLocalized("%d MB"), Int(megabytes.rounded()))
        }
        return String(format: relayLocalized("%.1f GB"), megabytes / 1_024)
    }
}

/// What the popover's list is sorted by.
enum ResourceOrder: Sendable {
    case cpu
    case memory

    /// Compared in whole percents and whole megabytes, so that two idle shells
    /// at 0.2% and 0.3% do not trade places every time the figures are read.
    /// Nothing measured — a finished terminal — sorts below everything.
    private func weight(_ usage: ResourceUsage?) -> Double {
        guard let usage else { return -1 }
        switch self {
        case .cpu: return (usage.cpu ?? 0).rounded()
        case .memory: return Double(usage.footprint / 1_048_576)
        }
    }

    /// Heaviest first, finished last, and otherwise the order they came in.
    func sorted(_ sessions: [SessionSnapshot], usage: [SessionID: ResourceUsage]) -> [SessionSnapshot] {
        Self.heaviestFirst(sessions) { weight(usage[$0.id]) }
    }

    /// The sessions under their projects: the projects by what their
    /// sessions cost together, and each project's sessions the same way.
    func grouped(_ sessions: [SessionSnapshot], usage: [SessionID: ResourceUsage]) -> [ResourceGroup] {
        var projects: [ProjectID] = []
        var members: [ProjectID: [SessionSnapshot]] = [:]
        for session in sessions {
            if members[session.projectID] == nil { projects.append(session.projectID) }
            members[session.projectID, default: []].append(session)
        }
        let groups = projects.map { id -> ResourceGroup in
            let inside = members[id] ?? []
            let measured = inside.compactMap { usage[$0.id] }
            return ResourceGroup(
                projectID: id,
                sessions: sorted(inside, usage: usage),
                usage: measured.isEmpty ? nil : ResourceUsage.total(measured)
            )
        }
        return Self.heaviestFirst(groups) { weight($0.usage) }
    }

    private static func heaviestFirst<Element>(_ items: [Element], by weight: (Element) -> Double) -> [Element] {
        items.enumerated()
            .map { (offset: $0.offset, element: $0.element, weight: weight($0.element)) }
            .sorted { first, second in
                first.weight != second.weight ? first.weight > second.weight : first.offset < second.offset
            }
            .map(\.element)
    }
}

/// One project in the popover, with its sessions and what they cost together.
struct ResourceGroup: Equatable, Identifiable, Sendable {
    var projectID: ProjectID
    var sessions: [SessionSnapshot]
    /// Nil when nothing in it is running.
    var usage: ResourceUsage?

    var id: ProjectID { projectID }

    /// Fresh groups, put back in the order the rows were in before.
    ///
    /// The figures are read every two seconds, and a list sorted by them
    /// reorders as they change; a row that moves out from under the pointer is
    /// a cross pressed on the wrong session. So while the pointer is over the
    /// list the figures change and the rows stay where they are, with anything
    /// new added at the end of where it belongs.
    static func arranged(_ groups: [ResourceGroup], like previous: [ResourceGroup]) -> [ResourceGroup] {
        let projectRank = Dictionary(
            previous.enumerated().map { ($0.element.projectID, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        let sessionRank = Dictionary(
            previous.flatMap(\.sessions).enumerated().map { ($0.element.id, $0.offset) },
            uniquingKeysWith: { first, _ in first }
        )
        func kept<Element>(_ items: [Element], rank: (Element) -> Int?) -> [Element] {
            items.enumerated()
                .sorted { first, second in
                    let a = rank(first.element) ?? Int.max
                    let b = rank(second.element) ?? Int.max
                    return a != b ? a < b : first.offset < second.offset
                }
                .map(\.element)
        }
        return kept(groups) { projectRank[$0.projectID] }.map { group in
            var group = group
            group.sessions = kept(group.sessions) { sessionRank[$0.id] }
            return group
        }
    }
}
