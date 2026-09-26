import Darwin
import Foundation
import RelayProtocol
import Testing

@testable import RelayAppKit

@Suite("What the sessions cost the Mac")
struct ResourceMonitorTests {
    /// A process table written out by hand.
    private struct Table: ProcessTable {
        var tree: [Int32: [Int32]] = [:]
        var costs: [Int32: ProcessCost] = [:]

        func children(of pid: Int32) -> [Int32] { tree[pid] ?? [] }
        func cost(of pid: Int32) -> ProcessCost? { costs[pid] }
    }

    private static func cost(own: UInt64, reaped: UInt64 = 0, footprint: UInt64 = 0) -> ProcessCost {
        ProcessCost(ownCPU: own, reapedCPU: reaped, footprint: footprint)
    }

    private static let second: UInt64 = 1_000_000_000
    private static let shell = SessionID(rawValue: "shell")
    private static let agent = SessionID(rawValue: "agent")

    // MARK: - Trees

    @Test("A session is measured by everything under the process it started")
    func wholeTree() {
        // zsh → npm → two node processes: the shell costs nothing, and the
        // figure worth having is two levels below it.
        let table = Table(
            tree: [10: [11], 11: [12, 13]],
            costs: [
                10: Self.cost(own: 1, reaped: 2, footprint: 1),
                11: Self.cost(own: 3, footprint: 10),
                12: Self.cost(own: 100, footprint: 200),
                13: Self.cost(own: 50, reaped: 7, footprint: 300),
            ]
        )
        let survey = ResourceSurvey.take(sessions: [Self.shell: 10], app: 1_000, daemon: nil, table: table, at: 0)
        #expect(survey.sessions[Self.shell] == .init(
            root: 10,
            cost: GroupCost(cpu: 163, footprint: 511, processes: 4)
        ))
    }

    @Test("Relay's own share leaves out the sessions hanging from the daemon")
    func relayLeavesSessionsOut() {
        // The window started a browser helper and the daemon; the daemon holds
        // two sessions and is running `lsof` for the ports window.
        let table = Table(
            tree: [1_000: [1_001, 2_000], 2_000: [10, 20, 2_001], 20: [21]],
            costs: [
                1_000: Self.cost(own: 5, reaped: 1, footprint: 100),
                1_001: Self.cost(own: 7, footprint: 50),
                // What the daemon has reaped is every session that has ended.
                2_000: Self.cost(own: 2, reaped: 9_999, footprint: 20),
                2_001: Self.cost(own: 3, footprint: 5),
                10: Self.cost(own: 40, footprint: 400),
                20: Self.cost(own: 60, footprint: 600),
                21: Self.cost(own: 80, footprint: 800),
            ]
        )
        let survey = ResourceSurvey.take(
            sessions: [Self.shell: 10, Self.agent: 20],
            app: 1_000,
            daemon: 2_000,
            table: table,
            at: 0
        )
        #expect(survey.relay == GroupCost(cpu: 18, footprint: 175, processes: 4))
        #expect(survey.sessions[Self.agent]?.cost == GroupCost(cpu: 140, footprint: 1_400, processes: 2))
    }

    @Test("A process listed twice is counted once")
    func loopsEnd() {
        // A pid reused between two reads can make a process its own
        // grandparent; the walk has to end all the same.
        let table = Table(
            tree: [10: [11], 11: [10, 12]],
            costs: [10: Self.cost(own: 1), 11: Self.cost(own: 1), 12: Self.cost(own: 1)]
        )
        #expect(ProcessTree.members(under: [10], in: table).sorted() == [10, 11, 12])
    }

    @Test("A process that cannot be read is left out rather than guessed")
    func unreadableIsSkipped() {
        // `sudo` in a terminal: listed as a child, not this user's to read.
        let table = Table(tree: [10: [11]], costs: [10: Self.cost(own: 4, footprint: 8)])
        #expect(ProcessTree.cost(of: [10, 11], in: table) == GroupCost(cpu: 4, footprint: 8, processes: 1))
    }

    // MARK: - CPU

    @Test("CPU is the time spent between two readings over the time between them")
    func cpuBetweenReadings() {
        let earlier = GroupCost(cpu: 1 * Self.second, footprint: 0, processes: 1)
        let half = GroupCost(cpu: earlier.cpu + Self.second / 2, footprint: 64, processes: 2)
        #expect(ResourceUsage.between(earlier, half, over: Self.second, cores: 8)
            == ResourceUsage(cpu: 50, footprint: 64, processes: 2))

        // Busy on two cores is 200%, the way Activity Monitor counts it.
        let two = GroupCost(cpu: earlier.cpu + 2 * Self.second, footprint: 0, processes: 2)
        #expect(ResourceUsage.between(earlier, two, over: Self.second, cores: 8).cpu == 200)
    }

    @Test("A first reading has memory and no CPU")
    func firstReading() {
        let usage = ResourceUsage.between(nil, GroupCost(cpu: 5 * Self.second, footprint: 128, processes: 3), over: 0, cores: 8)
        #expect(usage == ResourceUsage(cpu: nil, footprint: 128, processes: 3))
    }

    @Test("Time that leaves the tree or joins it is not taken for work")
    func bookkeepingIsNotWork() {
        let earlier = GroupCost(cpu: 10 * Self.second, footprint: 0, processes: 2)
        // A process reparented to launchd took its time with it.
        let left = GroupCost(cpu: 4 * Self.second, footprint: 0, processes: 1)
        #expect(ResourceUsage.between(earlier, left, over: Self.second, cores: 8).cpu == nil)
        // The daemon, reaped by the window, brought its whole lifetime along:
        // more than eight cores could spend in a second.
        let joined = GroupCost(cpu: earlier.cpu + 30 * Self.second, footprint: 0, processes: 3)
        #expect(ResourceUsage.between(earlier, joined, over: Self.second, cores: 8).cpu == nil)
    }

    @Test("A total counts what is known and does not wait for the rest")
    func totals() {
        let total = ResourceUsage.total([
            ResourceUsage(cpu: 12, footprint: 100, processes: 2),
            ResourceUsage(cpu: nil, footprint: 50, processes: 1),
            ResourceUsage(cpu: 3, footprint: 25, processes: 1),
        ])
        #expect(total == ResourceUsage(cpu: 15, footprint: 175, processes: 4))
        #expect(ResourceUsage.total([ResourceUsage(cpu: nil, footprint: 1, processes: 1)]).cpu == nil)
    }

    // MARK: - The list

    @Test("Heaviest first, finished last, and otherwise in the order given")
    func ordering() {
        let sessions = ["a", "b", "c", "d"].map { Self.snapshot($0, exited: $0 == "c") }
        let usage: [SessionID: ResourceUsage] = [
            SessionID(rawValue: "a"): Self.usage(cpu: 0.2, megabytes: 300),
            SessionID(rawValue: "b"): Self.usage(cpu: 0.3, megabytes: 900),
            SessionID(rawValue: "d"): Self.usage(cpu: 40, megabytes: 300),
        ]
        #expect(ResourceOrder.memory.sorted(sessions, usage: usage).map(\.id.rawValue) == ["b", "a", "d", "c"])
        // 0.2% and 0.3% are both nothing, and swapping them every two seconds
        // would move a row out from under the pointer for no reason.
        #expect(ResourceOrder.cpu.sorted(sessions, usage: usage).map(\.id.rawValue) == ["d", "a", "b", "c"])
    }

    @Test("Projects are sorted by what their sessions cost together, and their sessions within them")
    func grouping() {
        let sessions = [
            Self.snapshot("relay-shell", project: "relay"),
            Self.snapshot("shop-agent", project: "shop"),
            Self.snapshot("relay-agent", project: "relay"),
            Self.snapshot("notes-done", project: "notes", exited: true),
            Self.snapshot("shop-dev", project: "shop"),
        ]
        let usage: [SessionID: ResourceUsage] = [
            SessionID(rawValue: "relay-shell"): Self.usage(cpu: 0, megabytes: 4),
            SessionID(rawValue: "relay-agent"): Self.usage(cpu: 1, megabytes: 190),
            SessionID(rawValue: "shop-agent"): Self.usage(cpu: 2, megabytes: 150),
            SessionID(rawValue: "shop-dev"): Self.usage(cpu: 30, megabytes: 400),
        ]
        let byMemory = ResourceOrder.memory.grouped(sessions, usage: usage)
        #expect(byMemory.map(\.projectID.rawValue) == ["shop", "relay", "notes"])
        #expect(byMemory.map { $0.sessions.map(\.id.rawValue) } == [
            ["shop-dev", "shop-agent"],
            ["relay-agent", "relay-shell"],
            ["notes-done"],
        ])
        #expect(byMemory[0].usage == ResourceUsage(cpu: 32, footprint: 550 * 1_048_576, processes: 2))
        // A project where nothing runs has nothing to add up.
        #expect(byMemory[2].usage == nil)
    }

    @Test("Under the pointer the rows stay where they were, and newcomers go last")
    func frozenOrder() {
        let sessions = [
            Self.snapshot("a1", project: "a"),
            Self.snapshot("a2", project: "a"),
            Self.snapshot("b1", project: "b"),
        ]
        let before = ResourceOrder.memory.grouped(sessions, usage: [
            SessionID(rawValue: "a1"): Self.usage(cpu: 0, megabytes: 500),
            SessionID(rawValue: "a2"): Self.usage(cpu: 0, megabytes: 100),
            SessionID(rawValue: "b1"): Self.usage(cpu: 0, megabytes: 50),
        ])
        // The figures turn over, and a session and a project appear.
        let after = ResourceOrder.memory.grouped(sessions + [
            Self.snapshot("a3", project: "a"),
            Self.snapshot("c1", project: "c"),
        ], usage: [
            SessionID(rawValue: "a1"): Self.usage(cpu: 0, megabytes: 10),
            SessionID(rawValue: "a2"): Self.usage(cpu: 0, megabytes: 20),
            SessionID(rawValue: "a3"): Self.usage(cpu: 0, megabytes: 900),
            SessionID(rawValue: "b1"): Self.usage(cpu: 0, megabytes: 2_000),
            SessionID(rawValue: "c1"): Self.usage(cpu: 0, megabytes: 5_000),
        ])
        let held = ResourceGroup.arranged(after, like: before)
        #expect(held.map(\.projectID.rawValue) == ["a", "b", "c"])
        #expect(held[0].sessions.map(\.id.rawValue) == ["a1", "a2", "a3"])
        // The figures are the new ones; only the order is held.
        #expect(held[1].usage?.footprint == 2_000 * 1_048_576)
    }

    // MARK: - Closing

    @Test("Closing stops services, closes the rest, and counts what is still running")
    func closingPlan() {
        let plan = ResourceClosingPlan.of([
            Self.snapshot("agent"),
            Self.snapshot("done", exited: true),
            Self.snapshot("dev", role: .service(id: "dev")),
        ])
        #expect(plan.closing.map(\.rawValue) == ["agent", "done"])
        #expect(plan.stopping.map(\.rawValue) == ["dev"])
        #expect(plan.running == 1)
        #expect(ResourceClosingPlan.of([]).isEmpty)
    }

    @Test("CPU is written with a decimal only where it tells two figures apart")
    @MainActor
    func cpuFigures() {
        #expect(ResourceFormatting.cpu(nil) == "–")
        #expect(ResourceFormatting.cpu(0.01) == "0%")
        #expect(ResourceFormatting.cpu(3.14) == "3.1%")
        #expect(ResourceFormatting.cpu(42.4) == "42%")
        #expect(ResourceFormatting.cpu(212) == "212%")
    }

    @Test("Memory is written in the binary units Activity Monitor uses")
    @MainActor
    func memoryFigures() {
        // The unit is whatever language the window is in; the number is not.
        #expect(ResourceFormatting.memory(512 * 1_048_576).hasPrefix("512 "))
        #expect(ResourceFormatting.memory(1_536 * 1_048_576).hasPrefix("1.5 "))
    }

    private static func snapshot(
        _ id: String,
        project: String = "p",
        exited: Bool = false,
        role: SessionRole = .interactive
    ) -> SessionSnapshot {
        SessionSnapshot(
            id: SessionID(rawValue: id),
            projectID: ProjectID(rawValue: project),
            kind: .shell,
            name: id,
            workingDirectory: "/",
            command: [],
            status: .idle,
            pid: 1,
            exitCode: exited ? 0 : nil,
            startedAt: Date(timeIntervalSince1970: 0),
            lastActivityAt: Date(timeIntervalSince1970: 0),
            columns: 80,
            rows: 24,
            role: role
        )
    }

    private static func usage(cpu: Double, megabytes: UInt64) -> ResourceUsage {
        ResourceUsage(cpu: cpu, footprint: megabytes * 1_048_576, processes: 1)
    }

    // MARK: - The real table

    @Test("A busy grandchild is found under the shell that started it")
    func realBusyChild() async throws {
        let shell = try Self.start("/usr/bin/yes > /dev/null")
        defer { Self.end(shell) }

        let table = KernelProcessTable()
        var cost = GroupCost.zero
        try await Self.waitUntil {
            cost = ProcessTree.cost(of: ProcessTree.members(under: [shell.processIdentifier], in: table), in: table)
            return cost.processes == 2 && cost.cpu >= 200_000_000
        }
        #expect(cost.footprint > 0)
    }

    @Test("Work done by children that have already exited still counts")
    func realReapedChildren() async throws {
        // Three short busy processes one after another, then a pause: the
        // shape of a build, where every compiler has exited by the time the
        // next reading comes round. The `exit` keeps the shell from `exec`ing
        // its last command, which would start its count of reaped time again.
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-resources-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let shell = try Self.start(
            """
            for n in 1 2 3; do /bin/sh -c 'i=0; while [ $i -lt 150000 ]; do i=$((i+1)); done'; done
            : > "$1"
            /bin/sleep 60
            exit 0
            """,
            arguments: [marker.path]
        )
        defer { Self.end(shell) }

        try await Self.waitUntil { FileManager.default.fileExists(atPath: marker.path) }

        let table = KernelProcessTable()
        let cost = ProcessTree.cost(of: ProcessTree.members(under: [shell.processIdentifier], in: table), in: table)
        // CPU time rather than wall time, so a busy machine takes longer to get
        // here without changing the answer.
        #expect(cost.cpu >= 100_000_000, "the finished children's time is missing: \(cost.cpu) ns")
    }

    private static func start(_ script: String, arguments: [String] = []) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }

    /// Everything under the shell first: `yes` outlives a shell that is
    /// killed on its own, and would go on burning a core after the suite.
    private static func end(_ process: Process) {
        let table = KernelProcessTable()
        for pid in ProcessTree.members(under: [process.processIdentifier], in: table).reversed() {
            kill(pid, SIGKILL)
        }
        process.waitUntilExit()
    }

    /// Waits for a thing to have happened rather than for a time to have
    /// passed, with a deadline generous enough for a machine that is busy.
    private static func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition())
    }
}
