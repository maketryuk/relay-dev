import Darwin
import Foundation
import RelayProtocol

/// Turns a `SessionSpec` into an executable launch plan.
///
/// Everything is routed through the user's login shell on purpose: agents like
/// `claude` and `codex` are usually installed by nvm, mise or Homebrew, and a
/// GUI-launched process does not inherit the PATH those tools rely on.
public enum LaunchPlanBuilder {
    public static func makePlan(for spec: SessionSpec) -> PTYProcess.LaunchPlan {
        let shell = loginShell()
        let directory = resolveDirectory(spec.workingDirectory)

        let arguments: [String]
        if spec.command.isEmpty {
            arguments = ["-l"]
        } else {
            // `-i` forces zsh/bash to read the interactive rc file, which is
            // where most developers actually export PATH.
            arguments = ["-lic", "exec " + spec.command.map(shellQuoted).joined(separator: " ")]
        }

        return PTYProcess.LaunchPlan(
            executable: shell,
            arguments: arguments,
            workingDirectory: directory,
            environment: makeEnvironment(extra: spec.environment),
            columns: spec.columns,
            rows: spec.rows
        )
    }

    public static func loginShell() -> String {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty,
           FileManager.default.isExecutableFile(atPath: shell) {
            return shell
        }
        if let entry = getpwuid(getuid())?.pointee.pw_shell {
            let shell = String(cString: entry)
            if FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        return "/bin/zsh"
    }

    private static func resolveDirectory(_ path: String) -> String {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            return path
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }

    /// Variables that describe *the agent session Relay was launched from*.
    ///
    /// A session Relay starts must look like one started from a fresh login
    /// shell, not like a child of whatever happened to launch Relay. Left in
    /// place, a Claude session spawned here inherits another one's markers,
    /// decides it is that session's child and turns its own transcript saving
    /// off — which is exactly what happened, with the warning to prove it.
    static let inheritedSessionMarkers: [String] = [
        "CLAUDECODE",
        "CLAUDE_PID",
        "CLAUDE_EFFORT",
        "CODEX_SANDBOX",
        "CODEX_SANDBOX_NETWORK_DISABLED",
    ]

    /// Whole families of them, for the same reason.
    static let inheritedSessionPrefixes: [String] = [
        "CLAUDE_CODE_",
        "CODEX_SESSION",
        "CODEX_THREAD",
    ]

    /// Inherited from the GUI process and meaningless in a child.
    static let launcherNoise: [String] = ["XPC_SERVICE_NAME", "XPC_FLAGS"]

    static func isInherited(_ key: String) -> Bool {
        inheritedSessionMarkers.contains(key)
            || launcherNoise.contains(key)
            || inheritedSessionPrefixes.contains { key.hasPrefix($0) }
    }

    static func makeEnvironment(
        extra: [String: String],
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base.filter { !isInherited($0.key) }
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["TERM_PROGRAM"] = "Relay"
        environment["RELAY_SESSION"] = "1"
        if environment["LANG"] == nil {
            environment["LANG"] = "en_US.UTF-8"
        }
        for (key, value) in extra {
            environment[key] = value
        }
        return environment
    }

    /// A terminal's environment with what reaches the daemon's hooks and the
    /// app's `relay` command added, the session's own id, and the command's
    /// directory first on `PATH`.
    static func environment(
        _ environment: [String: String],
        telling relay: [String: String],
        session: SessionID
    ) -> [String: String] {
        guard !relay.isEmpty else { return environment }
        var environment = environment.merging(relay) { _, relay in relay }
        environment[AgentHookEnvironment.sessionKey] = session.rawValue
        if let tool = relay[ControlEnvironment.executableKey] {
            environment["PATH"] = searchPath(
                environment["PATH"],
                prepending: URL(fileURLWithPath: tool).deletingLastPathComponent().path
            )
        }
        return environment
    }

    /// `PATH` with `directory` first, and in it once.
    ///
    /// First, so `relay` is Relay's own. A login shell's `path_helper` puts the
    /// system's directories back in front of it, which matters only if one of
    /// them has a `relay` of its own; `RELAY_CLI` names this one whatever
    /// `PATH` has become.
    static func searchPath(_ path: String?, prepending directory: String) -> String {
        let rest = (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty && $0 != directory }
        return ([directory] + rest).joined(separator: ":")
    }

    private static func shellQuoted(_ argument: String) -> String {
        guard !argument.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_./=:@%+,"))
        if argument.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
