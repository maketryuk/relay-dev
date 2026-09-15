import Foundation
import Testing

@testable import RelayDaemonCore
@testable import RelayProtocol

/// Command runner that replays captured fixtures.
struct FakeCommandRunner: CommandRunning {
    var responses: [String: CommandResult]
    /// When true, every call reports that the binary could not be launched.
    var isUnavailable = false

    init(responses: [String: String], isUnavailable: Bool = false) {
        self.responses = responses.mapValues {
            CommandResult(status: 0, standardOutput: $0, standardError: "")
        }
        self.isUnavailable = isUnavailable
    }

    init(results: [String: CommandResult]) {
        responses = results
    }

    func run(_ executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult? {
        guard !isUnavailable else { return nil }
        if executable.hasSuffix("/ps") { return responses["ps"] }
        if executable.hasSuffix("lsof") { return responses["lsof"] }
        if executable.hasSuffix("docker") {
            // `docker ps` and `docker compose ps` fail in completely different
            // ways, so the fake has to tell them apart to be worth anything.
            let key = arguments.first == "compose" ? "docker compose" : "docker ps"
            return responses[key] ?? responses["docker"]
        }
        return nil
    }
}

@Suite("Process tree")
struct ProcessTreeTests {
    private let psOutput = """
      1     0
    500     1
    501   500
    502   501
    503   501
    600     1
    601   600
    """

    @Test("`ps` output becomes a parent-to-children map")
    func parsesProcessTree() {
        let tree = PortScanner.parseProcessTree(psOutput)
        #expect(tree[500] == [501])
        #expect(tree[501]?.sorted() == [502, 503])
        #expect(tree[1]?.sorted() == [500, 600])
    }

    @Test("Malformed lines are skipped")
    func skipsMalformedLines() {
        let tree = PortScanner.parseProcessTree("""
        not a number here
        500 1
        onlyonefield
        """)
        #expect(tree[1] == [500])
        #expect(tree.count == 1)
    }

    @Test("Descendants include the root and the whole subtree")
    func collectsDescendants() {
        // `npm run dev` forks a package manager which forks the real server, so
        // the port is bound several levels below the process Relay spawned.
        let tree = PortScanner.parseProcessTree(psOutput)
        #expect(PortScanner.descendants(of: [500], in: tree) == [500, 501, 502, 503])
        #expect(PortScanner.descendants(of: [501], in: tree) == [501, 502, 503])
        #expect(PortScanner.descendants(of: [502], in: tree) == [502])
    }

    @Test("Several roots are merged without duplicates")
    func mergesRoots() {
        let tree = PortScanner.parseProcessTree(psOutput)
        #expect(PortScanner.descendants(of: [500, 600], in: tree) == [500, 501, 502, 503, 600, 601])
        #expect(PortScanner.descendants(of: [500, 501], in: tree) == [500, 501, 502, 503])
    }

    @Test("A cyclic tree terminates instead of looping forever")
    func handlesCycles() {
        // Should never happen, but a corrupted read must not hang the daemon.
        let tree: [Int32: [Int32]] = [1: [2], 2: [3], 3: [1]]
        #expect(PortScanner.descendants(of: [1], in: tree) == [1, 2, 3])
    }

    @Test("An unknown pid yields only itself")
    func unknownPID() {
        #expect(PortScanner.descendants(of: [9999], in: [:]) == [9999])
    }
}

@Suite("Listening port parsing")
struct ListeningPortParsingTests {
    @Test("lsof field output becomes structured ports")
    func parsesLsofOutput() {
        let output = """
        p501
        cnode
        n*:3000
        p502
        cnode
        n127.0.0.1:5173
        p503
        cpostgres
        n[::1]:5432
        """
        let ports = PortScanner.parseListeningPorts(output)
        #expect(ports.count == 3)
        #expect(ports[0].port == 3000)
        #expect(ports[0].address == "*")
        #expect(ports[0].pid == 501)
        #expect(ports[0].processName == "node")
        #expect(ports[1].port == 5173)
        #expect(ports[1].address == "127.0.0.1")
        #expect(ports[2].port == 5432)
        #expect(ports[2].address == "[::1]")
    }

    @Test("One process listening on several ports yields several entries")
    func multiplePortsPerProcess() {
        let output = """
        p700
        cnode
        n*:3000
        n*:3001
        """
        let ports = PortScanner.parseListeningPorts(output)
        #expect(ports.map(\.port) == [3000, 3001])
        #expect(ports.allSatisfy { $0.pid == 700 && $0.processName == "node" })
    }

    @Test("A dual-stack listener is reported once")
    func deduplicatesIdenticalEntries() {
        let output = """
        p800
        cnode
        n*:8080
        n*:8080
        """
        #expect(PortScanner.parseListeningPorts(output).count == 1)
    }

    @Test("Results are ordered by port so the popover is stable")
    func sortsByPort() {
        let output = """
        p1
        ca
        n*:9000
        p2
        cb
        n*:3000
        p3
        cc
        n*:5000
        """
        #expect(PortScanner.parseListeningPorts(output).map(\.port) == [3000, 5000, 9000])
    }

    @Test("Empty and malformed output produce no ports rather than bad ones")
    func toleratesGarbage() {
        #expect(PortScanner.parseListeningPorts("").isEmpty)
        #expect(PortScanner.parseListeningPorts("garbage\nlines\n").isEmpty)
        // A name with no port at all.
        #expect(PortScanner.parseListeningPorts("p1\ncnode\nnlocalhost\n").isEmpty)
    }

    @Test("An established connection is not mistaken for a listener")
    func ignoresConnections() {
        let output = """
        p1
        cnode
        n127.0.0.1:52341->93.184.216.34:443
        """
        #expect(PortScanner.parseListeningPorts(output).isEmpty)
    }

    @Test(
        "Endpoints of every shape are split correctly",
        arguments: [
            ("*:3000", "*", 3000),
            ("127.0.0.1:8080", "127.0.0.1", 8080),
            ("[::1]:5432", "[::1]", 5432),
            ("[::]:443", "[::]", 443),
            ("192.168.1.10:9229", "192.168.1.10", 9229),
        ]
    )
    func splitsEndpoints(text: String, address: String, port: Int) {
        let result = PortScanner.splitEndpoint(text)
        #expect(result?.address == address)
        #expect(result?.port == port)
    }

    @Test("Out-of-range ports are rejected")
    func rejectsInvalidPorts() {
        #expect(PortScanner.splitEndpoint("*:0") == nil)
        #expect(PortScanner.splitEndpoint("*:70000") == nil)
        #expect(PortScanner.splitEndpoint("*:abc") == nil)
    }
}

@Suite("Port reachability")
struct PortReachabilityTests {
    @Test(
        "Wildcard and loopback binds are reachable at localhost",
        arguments: ["*", "127.0.0.1", "::1", "0.0.0.0", "[::]"]
    )
    func locallyReachable(address: String) {
        let port = ListeningPort(port: 3000, address: address, pid: 1, processName: "node")
        #expect(port.isLocallyReachable)
        #expect(port.url?.absoluteString == "http://localhost:3000")
    }

    @Test("A bind to a specific external interface offers no localhost URL")
    func externalBindHasNoLocalURL() {
        let port = ListeningPort(port: 3000, address: "192.168.1.5", pid: 1, processName: "node")
        #expect(!port.isLocallyReachable)
        #expect(port.url == nil)
    }
}

@Suite("Process ancestry")
struct ProcessAncestryTests {
    private let parents = PortScanner.parseParents("""
      1     0
    500     1
    501   500
    502   501
    900     1
    """)

    @Test("`ps` output becomes a child-to-parent lookup")
    func parsesParents() {
        #expect(parents[501] == 500)
        #expect(parents[502] == 501)
        #expect(parents[900] == 1)
    }

    @Test("A listener several forks deep resolves to the session that started it")
    func findsAncestor() {
        // `pnpm dev` → node → the process that actually binds the port.
        #expect(PortScanner.nearestAncestor(of: 502, among: [500], parents: parents) == 500)
        #expect(PortScanner.nearestAncestor(of: 500, among: [500], parents: parents) == 500)
    }

    @Test("A process Relay did not start has no owner")
    func unrelatedProcessHasNoOwner() {
        #expect(PortScanner.nearestAncestor(of: 900, among: [500], parents: parents) == nil)
    }

    @Test("The nearest matching ancestor wins when sessions are nested")
    func nearestWins() {
        #expect(PortScanner.nearestAncestor(of: 502, among: [500, 501], parents: parents) == 501)
    }

    @Test("A cyclic ancestry terminates instead of looping forever")
    func cyclesTerminate() {
        let cyclic: [Int32: Int32] = [10: 11, 11: 12, 12: 10]
        #expect(PortScanner.nearestAncestor(of: 10, among: [99], parents: cyclic) == nil)
    }

    @Test("Climbing stops at init rather than claiming everything")
    func stopsAtInit() {
        #expect(PortScanner.nearestAncestor(of: 500, among: [1], parents: parents) == nil)
    }
}

@Suite("Port scan orchestration")
struct PortScanOrchestrationTests {
    @Test("Every listener on the machine is reported, not just Relay's own")
    func scansWholeMachine() {
        // Answering "what is on 3000" is the point; a server started in another
        // terminal must show up too.
        let runner = FakeCommandRunner(responses: [
            "lsof": "p900\ncPostgres\nn*:5432\np1200\ncnode\nn*:3000\n",
        ])
        let ports = PortScanner.scanAll(runner: runner)
        #expect(ports.map(\.port) == [3000, 5432])
        #expect(ports.allSatisfy { !$0.isManagedByRelay })
    }

    @Test("A failing helper degrades to an empty list")
    func toleratesHelperFailure() {
        #expect(PortScanner.scanAll(runner: FakeCommandRunner(responses: [:])).isEmpty)
        #expect(PortScanner.scanAll(runner: FakeCommandRunner(responses: [:], isUnavailable: true)).isEmpty)
    }

    @Test("lsof exiting non-zero because it matched nothing is not an error")
    func nonZeroLsofStatusIsTolerated() {
        // `lsof` returns 1 whenever its filters select no files.
        let runner = FakeCommandRunner(results: [
            "lsof": CommandResult(status: 1, standardOutput: "p500\ncnode\nn*:3000\n", standardError: ""),
        ])
        #expect(PortScanner.scanAll(runner: runner).map(\.port) == [3000])
    }

    @Test("A timed-out scan yields nothing rather than a partial answer")
    func timeoutYieldsNothing() {
        let runner = FakeCommandRunner(results: [
            "lsof": CommandResult(status: -1, standardOutput: "", standardError: "", timedOut: true),
        ])
        #expect(PortScanner.scanAll(runner: runner).isEmpty)
    }

    @Test("Process ancestry is read from ps")
    func readsAncestry() {
        let runner = FakeCommandRunner(responses: ["ps": "501 500\n"])
        #expect(PortScanner.processParents(runner: runner)[501] == 500)
        #expect(PortScanner.processParents(runner: FakeCommandRunner(responses: [:])).isEmpty)
    }
}

@Suite("Port ownership")
struct PortOwnershipTests {
    @Test("Only a port Relay started counts as managed")
    func managedFlag() {
        let external = ListeningPort(port: 5432, address: "*", pid: 900, processName: "postgres")
        #expect(!external.isManagedByRelay)

        let owned = ListeningPort(
            port: 3000,
            address: "*",
            pid: 1200,
            processName: "node",
            ownerSessionID: .generate(),
            ownerName: "Dev",
            ownerProjectID: .generate()
        )
        #expect(owned.isManagedByRelay)
    }
}

@Suite("Port survey")
struct PortSurveyTests {
    private let lsof = """
    p900
    cnode
    n*:3000
    p901
    cnginx
    n127.0.0.1:8080
    """

    private let ps = """
      900   880
      880   700
      901     1
      700     1
    """

    @Test("A listener several forks below a session is attributed to it")
    func attributesDescendantToItsSession() {
        let owner = PortScanner.PortOwner(
            pid: 700,
            sessionID: SessionID(rawValue: "session"),
            name: "Dev server",
            projectID: ProjectID(rawValue: "project")
        )
        let ports = PortScanner.survey(
            runner: FakeCommandRunner(responses: ["lsof": lsof, "ps": ps]),
            owners: [owner]
        )

        let node = ports.first { $0.port == 3_000 }
        #expect(node?.ownerSessionID == owner.sessionID)
        #expect(node?.ownerName == "Dev server")
        #expect(node?.ownerProjectID == owner.projectID)

        // Someone else's nginx is reported, never claimed.
        let nginx = ports.first { $0.port == 8_080 }
        #expect(nginx?.ownerSessionID == nil)
    }

    @Test("With nothing of Relay's running, the process table is not read")
    func skipsTheProcessTableWithoutOwners() {
        // Walking ancestry with no candidates can only ever fail, and `ps` costs
        // a fork on a path the ports window takes every few seconds.
        let runner = FakeCommandRunner(responses: ["lsof": lsof])
        let ports = PortScanner.survey(runner: runner, owners: [])

        #expect(ports.count == 2)
        #expect(ports.allSatisfy { $0.ownerSessionID == nil })
    }

    @Test("Nothing listening means no further work")
    func emptyScanReturnsEmpty() {
        let ports = PortScanner.survey(runner: FakeCommandRunner(responses: ["lsof": ""]), owners: [])
        #expect(ports.isEmpty)
    }
}
