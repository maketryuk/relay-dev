import Foundation

struct GitStatus: Equatable, Sendable {
    var branch: String
    var isDirty: Bool
    var changedFiles: Int
    var ahead: Int
    var behind: Int
    var upstream: String?
    /// Lines added and removed in the working tree, as `git diff --shortstat`
    /// reports them. Shown next to the branch the way a pull request does.
    var insertions: Int = 0
    var deletions: Int = 0

    var hasDiff: Bool { insertions > 0 || deletions > 0 }
}

/// Reads repository state through the system `git`.
///
/// One `status --porcelain=v2 --branch` call yields branch, dirtiness and
/// ahead/behind together, so refreshing a project costs a single process spawn
/// rather than three.
enum GitProbe {
    static func isRepository(at path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let gitPath = (path as NSString).appendingPathComponent(".git")
        return FileManager.default.fileExists(atPath: gitPath, isDirectory: &isDirectory)
    }

    static func status(at path: String) -> GitStatus? {
        guard isRepository(at: path) else { return nil }
        guard let output = Shell.run(
            "/usr/bin/git",
            arguments: ["-C", path, "status", "--porcelain=v2", "--branch"],
            timeout: 4
        ) else { return nil }
        var status = parse(porcelainV2: output)
        // Nothing changed has nothing to measure, and this runs for every
        // worktree of the project on screen every twelve seconds.
        guard status.isDirty else { return status }

        // A second call, because porcelain v2 reports which files changed but
        // not by how much.
        if let shortstat = Shell.run(
            "/usr/bin/git",
            arguments: ["-C", path, "diff", "--shortstat", "HEAD"],
            timeout: 4
        ) {
            let counts = parse(shortstat: shortstat)
            status.insertions = counts.insertions
            status.deletions = counts.deletions
        }
        return status
    }

    /// Parses `3 files changed, 44 insertions(+), 19 deletions(-)`.
    ///
    /// Any of the three clauses can be absent: a change that only adds lines
    /// reports no deletions at all.
    static func parse(shortstat output: String) -> (insertions: Int, deletions: Int) {
        var insertions = 0
        var deletions = 0
        for clause in output.split(separator: ",") {
            let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
            let parts = trimmed.split(separator: " ")
            guard let value = Int(parts.first ?? "") else { continue }
            if trimmed.contains("insertion") { insertions = value }
            if trimmed.contains("deletion") { deletions = value }
        }
        return (insertions, deletions)
    }

    /// Pure parser for `git status --porcelain=v2 --branch`, kept separate from
    /// process invocation so it can be tested against captured fixtures.
    static func parse(porcelainV2 output: String) -> GitStatus {
        var branch = "HEAD"
        var upstream: String?
        var ahead = 0
        var behind = 0
        var changed = 0

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# branch.head ") {
                branch = String(line.dropFirst("# branch.head ".count))
            } else if line.hasPrefix("# branch.upstream ") {
                upstream = String(line.dropFirst("# branch.upstream ".count))
            } else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst("# branch.ab ".count).split(separator: " ")
                if parts.count == 2 {
                    ahead = Int(parts[0].dropFirst()) ?? 0
                    behind = Int(parts[1].dropFirst()) ?? 0
                }
            } else if !line.hasPrefix("#") {
                changed += 1
            }
        }

        return GitStatus(
            branch: branch,
            isDirty: changed > 0,
            changedFiles: changed,
            ahead: ahead,
            behind: behind,
            upstream: upstream
        )
    }
}

/// Blocking helper for short-lived CLI calls. Never call from the main thread.
enum Shell {
    /// What a command left behind, whatever it thought of itself.
    ///
    /// `run` treats a non-zero exit as no answer at all, which is right for a
    /// probe. Some commands answer *with* a non-zero status — `git diff
    /// --no-index` exits 1 precisely when it found a difference — and some fail
    /// with a message worth showing the user.
    struct Result: Sendable {
        var status: Int32
        var output: String
        var error: String

        var succeeded: Bool { status == 0 }
    }

    static func capture(_ executable: String, arguments: [String], timeout: TimeInterval = 5) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return nil
        }

        // Both pipes are drained before waiting: a child that fills one while
        // nobody reads the other deadlocks, and git is happy to write megabytes
        // to either.
        let outputData = out.fileHandleForReading.readDataToEndOfFile()
        let errorData = err.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }

        return Result(
            status: process.terminationStatus,
            output: String(decoding: outputData, as: UTF8.self),
            error: String(decoding: errorData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    @discardableResult
    static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // Read before waiting: a full pipe buffer would otherwise deadlock a
        // child that produces more than 64 KB.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
