import Foundation
import RelayProtocol

/// Discovers which TCP ports a set of processes — and their descendants — are
/// listening on.
///
/// A dev server is almost never the process Relay spawned: `npm run dev` forks
/// a package manager, which forks node, which is what actually binds the port.
/// Walking the tree is therefore not an optimisation but a requirement.
public enum PortScanner {
    /// Parses `ps -axo pid=,ppid=` into a child lookup table.
    public static func parseProcessTree(_ output: String) -> [Int32: [Int32]] {
        var children: [Int32: [Int32]] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2,
                  let pid = Int32(fields[0]),
                  let parent = Int32(fields[1])
            else { continue }
            children[parent, default: []].append(pid)
        }
        return children
    }

    /// Parses `ps -axo pid=,ppid=` into a child-to-parent lookup.
    ///
    /// Walking upward is what attributes a port to a session: the listener is a
    /// descendant, so the only way to name its owner is to climb to an ancestor
    /// Relay recognises.
    public static func parseParents(_ output: String) -> [Int32: Int32] {
        var parents: [Int32: Int32] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2,
                  let pid = Int32(fields[0]),
                  let parent = Int32(fields[1])
            else { continue }
            parents[pid] = parent
        }
        return parents
    }

    /// Climbs the ancestry of `pid` until it reaches one of `candidates`.
    public static func nearestAncestor(
        of pid: Int32,
        among candidates: Set<Int32>,
        parents: [Int32: Int32]
    ) -> Int32? {
        var current = pid
        var guardCounter = 0
        while guardCounter < 64 {
            if candidates.contains(current) { return current }
            guard let parent = parents[current], parent > 1, parent != current else { return nil }
            current = parent
            guardCounter += 1
        }
        return nil
    }

    /// Every descendant of `roots`, including the roots themselves.
    public static func descendants(of roots: [Int32], in children: [Int32: [Int32]]) -> [Int32] {
        var result: [Int32] = []
        var seen = Set<Int32>()
        var queue = roots

        while let pid = queue.popLast() {
            guard seen.insert(pid).inserted else { continue }
            result.append(pid)
            if let next = children[pid] {
                queue.append(contentsOf: next)
            }
        }
        return result.sorted()
    }

    /// Parses `lsof -nP -iTCP -sTCP:LISTEN -F pcn` field output.
    ///
    /// The machine-readable `-F` form is used rather than the default table
    /// because process names and addresses can both contain spaces.
    public static func parseListeningPorts(_ output: String) -> [ListeningPort] {
        var ports: [ListeningPort] = []
        var currentPID: Int32?
        var currentCommand = ""
        var seen = Set<String>()

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())

            switch marker {
            case "p":
                currentPID = Int32(value)
                currentCommand = ""
            case "c":
                currentCommand = value
            case "n":
                guard let pid = currentPID,
                      let (address, port) = splitEndpoint(value)
                else { continue }
                let entry = ListeningPort(
                    port: port,
                    address: address,
                    pid: pid,
                    processName: currentCommand
                )
                // A dual-stack listener appears once per address family.
                if seen.insert(entry.id).inserted {
                    ports.append(entry)
                }
            default:
                continue
            }
        }

        return ports.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// Splits `*:3000`, `127.0.0.1:8080` and `[::1]:5173` into address and port.
    static func splitEndpoint(_ text: String) -> (address: String, port: Int)? {
        // An lsof name can carry a connection arrow; listeners never do, but be
        // defensive rather than produce a nonsense port.
        guard !text.contains("->") else { return nil }
        guard let separator = text.lastIndex(of: ":") else { return nil }
        let address = String(text[text.startIndex ..< separator])
        guard let port = Int(text[text.index(after: separator)...]), port > 0, port <= 65535 else { return nil }
        return (address.isEmpty ? "*" : address, port)
    }

    /// Lists every TCP port the machine is listening on.
    ///
    /// Showing only Relay's own processes turned out to be the wrong product
    /// call: the question a developer actually has is "what is on 3000", and the
    /// answer is just as often a server they started elsewhere. Ports Relay owns
    /// are attributed to their session; the rest are listed and left alone.
    public static func scanAll(runner: some CommandRunning = SystemCommandRunner()) -> [ListeningPort] {
        // `lsof` exits 1 when it matched nothing, so the status is ignored here
        // and the parser decides what the output means.
        guard let lsof = runner.run(
            "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"],
            timeout: 8
        ), !lsof.timedOut else {
            return []
        }
        return parseListeningPorts(lsof.standardOutput)
    }

    /// The directory a process was started from.
    ///
    /// Read straight from the kernel rather than by shelling out: it is one
    /// syscall per process, and the ports window asks about all of them at
    /// once. Fails quietly for processes owned by another user, which is
    /// correct — their working directory is none of our business.
    public static func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, pointer, Int32(size))
        }
        guard result == Int32(size) else { return nil }

        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// Reads the process ancestry once, for attributing ports to sessions.
    public static func processParents(runner: some CommandRunning = SystemCommandRunner()) -> [Int32: Int32] {
        guard let ps = runner.run("/bin/ps", arguments: ["-axo", "pid=,ppid="], timeout: 4), ps.succeeded else {
            return [:]
        }
        return parseParents(ps.standardOutput)
    }
}
