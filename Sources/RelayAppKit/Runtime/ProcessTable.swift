import Darwin
import Foundation
import RelayProtocol

/// What one process has cost so far, as the kernel counts it.
struct ProcessCost: Equatable, Sendable {
    /// CPU the process has spent itself, in nanoseconds.
    var ownCPU: UInt64
    /// CPU spent by every child it has waited for, and by theirs in turn.
    ///
    /// This is what lets a tree be measured by the processes alive in it. A
    /// compiler that ran for two seconds and exited between two readings is
    /// gone from the table, and its two seconds are here, on the `make` that
    /// reaped it — so a build made of short processes reads as the build it is
    /// rather than as an idle shell. An `exec` starts the count again, which a
    /// reading sees as time leaving the tree and does not mistake for work.
    var reapedCPU: UInt64
    /// What Activity Monitor calls a process's memory. Resident size counts a
    /// shared library once for every process that maps it, and added up over a
    /// tree of node processes it gives a figure nobody recognises.
    var footprint: UInt64
}

/// Where costs are read from: the kernel, or a table a test wrote.
protocol ProcessTable {
    func children(of pid: Int32) -> [Int32]
    func cost(of pid: Int32) -> ProcessCost?
}

/// The kernel's own table, through `libproc`: a syscall or two a process and
/// no forks, which is what makes reading it every few seconds free.
struct KernelProcessTable: ProcessTable {
    /// `rusage_info` counts time in Mach ticks, which are nanoseconds on Intel
    /// and 125/3 of one on Apple silicon.
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    func children(of pid: Int32) -> [Int32] {
        var capacity = 64
        while true {
            var buffer = [Int32](repeating: 0, count: capacity)
            let count = buffer.withUnsafeMutableBytes { raw in
                Int(proc_listchildpids(pid, raw.baseAddress, Int32(raw.count)))
            }
            guard count > 0 else { return [] }
            // A full buffer may have been cut short, so it is asked again with
            // room to spare — up to a point, since no shell has sixteen
            // thousand children and a runaway fork loop is not worth chasing.
            if count < capacity || capacity >= 16_384 {
                return Array(buffer.prefix(min(count, capacity)))
            }
            capacity *= 4
        }
    }

    func cost(of pid: Int32) -> ProcessCost? {
        var info = rusage_info_v2()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        // Gone since it was listed, or somebody else's: `sudo` in a terminal
        // starts a process this user may not read.
        guard result == 0 else { return nil }
        return ProcessCost(
            ownCPU: Self.nanoseconds(info.ri_user_time &+ info.ri_system_time),
            reapedCPU: Self.nanoseconds(info.ri_child_user_time &+ info.ri_child_system_time),
            footprint: info.ri_phys_footprint
        )
    }

    /// Split so that a process that has run for months cannot overflow on the
    /// way to being converted.
    private static func nanoseconds(_ ticks: UInt64) -> UInt64 {
        ticks / timebase.denom * timebase.numer + ticks % timebase.denom * timebase.numer / timebase.denom
    }
}

/// What a set of processes has cost between them.
struct GroupCost: Equatable, Sendable {
    /// Every member's own CPU and that of every child it has reaped, in
    /// nanoseconds. Only ever compared with an earlier reading of the same
    /// group: on its own it is the lifetime of whatever the group has run.
    var cpu: UInt64
    var footprint: UInt64
    var processes: Int

    static let zero = GroupCost(cpu: 0, footprint: 0, processes: 0)
}

enum ProcessTree {
    /// Every process under `roots`, the roots among them, without going below
    /// any of `boundaries` — which are left out themselves.
    ///
    /// The tree is the unit rather than the process Relay started, because
    /// that process is a shell: what is costing anything is the node a package
    /// manager forked two levels below it.
    static func members(
        under roots: [Int32],
        stoppingAt boundaries: Set<Int32> = [],
        in table: some ProcessTable
    ) -> [Int32] {
        var result: [Int32] = []
        var seen = Set<Int32>()
        var queue = roots
        while let pid = queue.popLast() {
            // Seen once is enough, and the guard is what stops a pid reused
            // between two reads from turning the tree into a loop.
            guard pid > 1, !boundaries.contains(pid), seen.insert(pid).inserted else { continue }
            result.append(pid)
            queue.append(contentsOf: table.children(of: pid))
        }
        return result
    }

    /// What the processes cost together.
    ///
    /// `ownTimeOnly` names processes whose reaped children are somebody
    /// else's: the daemon reaps every session that ends, and counting that
    /// time would make closing a session look like Relay spending a session's
    /// whole lifetime in a moment.
    static func cost(
        of members: [Int32],
        ownTimeOnly: Set<Int32> = [],
        in table: some ProcessTable
    ) -> GroupCost {
        var total = GroupCost.zero
        for pid in members {
            guard let cost = table.cost(of: pid) else { continue }
            total.cpu &+= cost.ownCPU &+ (ownTimeOnly.contains(pid) ? 0 : cost.reapedCPU)
            total.footprint &+= cost.footprint
            total.processes += 1
        }
        return total
    }
}

/// One reading of every session and of Relay itself.
struct ResourceSurvey: Sendable {
    struct Measured: Equatable, Sendable {
        /// The process the session started, so that a reading is only ever
        /// compared with one of the same process.
        var root: Int32
        var cost: GroupCost
    }

    var sessions: [SessionID: Measured]
    var relay: GroupCost
    /// When it was taken, in nanoseconds of uptime: the clock CPU time is
    /// spent against, since neither moves while the Mac is asleep.
    var takenAt: UInt64

    /// Reads every session's tree, and then Relay's own: the window, what it
    /// started — the browser's helpers, a linter kept warm — and the daemon,
    /// less the sessions that hang from it.
    static func take(
        sessions roots: [SessionID: Int32],
        app: Int32,
        daemon: Int32?,
        table: some ProcessTable,
        at time: UInt64
    ) -> ResourceSurvey {
        var sessions: [SessionID: Measured] = [:]
        for (id, root) in roots {
            let members = ProcessTree.members(under: [root], in: table)
            sessions[id] = Measured(root: root, cost: ProcessTree.cost(of: members, in: table))
        }

        let relayMembers = ProcessTree.members(
            under: [app] + (daemon.map { [$0] } ?? []),
            stoppingAt: Set(roots.values),
            in: table
        )
        let relay = ProcessTree.cost(
            of: relayMembers,
            ownTimeOnly: daemon.map { [$0] } ?? [],
            in: table
        )
        return ResourceSurvey(sessions: sessions, relay: relay, takenAt: time)
    }
}
